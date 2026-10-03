-- Convites globais dos jogos de tabuleiro.
-- O convite é entre jogadores; Ludo/Dama é escolhido depois.

create table if not exists public.board_invitations (
  id uuid primary key default extensions.gen_random_uuid(),
  sender_id uuid not null references public.players(id) on delete cascade,
  target_id uuid not null references public.players(id) on delete cascade,
  status text not null default 'pending',
  sender_choice text,
  target_choice text,
  selected_game text,
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  expires_at timestamptz not null default now()+interval '24 hours',
  consumed_at timestamptz,
  constraint board_invites_not_self check(sender_id<>target_id),
  constraint board_invites_status_check check(status in ('pending','accepted','declined','cancelled','consumed')),
  constraint board_invites_sender_choice_check check(sender_choice is null or sender_choice in ('ludo','dama')),
  constraint board_invites_target_choice_check check(target_choice is null or target_choice in ('ludo','dama')),
  constraint board_invites_selected_game_check check(selected_game is null or selected_game in ('ludo','dama'))
);

create index if not exists board_invitations_participants_idx
  on public.board_invitations(sender_id,target_id,created_at desc);
create unique index if not exists board_invitations_pending_pair_uidx
  on public.board_invitations(
    least(sender_id::text,target_id::text),
    greatest(sender_id::text,target_id::text)
  )
  where status='pending';

alter table public.board_invitations enable row level security;
revoke all on table public.board_invitations from anon,authenticated;

create or replace function public.jl_board_invite_send(
  p_token text,p_target_player uuid
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  inv public.board_invitations%rowtype;
  my_name text;
begin
  if p_target_player is null or p_target_player=me then
    raise exception 'Jogador inválido.';
  end if;
  if not exists(
    select 1 from public.players
    where id=p_target_player and not blocked and deleted_at is null
  ) then
    raise exception 'Jogador não encontrado.';
  end if;

  select * into inv
  from public.board_invitations
  where status='pending'
    and ((sender_id=me and target_id=p_target_player)
      or (sender_id=p_target_player and target_id=me))
    and expires_at>now()
  order by created_at desc
  limit 1;

  if inv.id is null then
    insert into public.board_invitations(sender_id,target_id)
    values(me,p_target_player)
    returning * into inv;

    select name into my_name from public.players where id=me;
    perform public.jl_notification_create(
      p_target_player,
      'board-invite',
      'Convite para jogar',
      coalesce(my_name,'Jogador')||' convidou você para jogar. Escolham o jogo no Tabuleiro.',
      './tabuleiro.html#boardInvites',
      'board-invite:'||inv.id::text
    );
  end if;

  return jsonb_build_object(
    'ok',true,'id',inv.id,'status',inv.status,
    'sender_id',inv.sender_id,'target_id',inv.target_id
  );
end;
$$;

create or replace function public.jl_board_invites_feed(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare me uuid:=public.jl_player_id(p_token);
begin
  update public.board_invitations
  set status='cancelled'
  where status='pending' and expires_at<=now();

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',i.id,
      'status',i.status,
      'role',case when i.sender_id=me then 'sender' else 'target' end,
      'sender_id',i.sender_id,
      'target_id',i.target_id,
      'other_id',case when i.sender_id=me then i.target_id else i.sender_id end,
      'other_name',p.name,
      'other_code',public.jl_ludo_display_code(p.id),
      'sender_choice',i.sender_choice,
      'target_choice',i.target_choice,
      'my_choice',case when i.sender_id=me then i.sender_choice else i.target_choice end,
      'other_choice',case when i.sender_id=me then i.target_choice else i.sender_choice end,
      'selected_game',i.selected_game,
      'created_at',i.created_at,
      'expires_at',i.expires_at
    ) order by i.created_at desc)
    from public.board_invitations i
    join public.players p
      on p.id=case when i.sender_id=me then i.target_id else i.sender_id end
    where (i.sender_id=me or i.target_id=me)
      and i.status in ('pending','accepted')
      and i.expires_at>now()
  ),'[]'::jsonb);
end;
$$;

create or replace function public.jl_board_invite_respond(
  p_token text,p_invite uuid,p_accept boolean
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  inv public.board_invitations%rowtype;
  my_name text;
begin
  select * into inv
  from public.board_invitations
  where id=p_invite
  for update;

  if inv.id is null or inv.target_id<>me or inv.status<>'pending' or inv.expires_at<=now() then
    raise exception 'Convite indisponível.';
  end if;

  update public.board_invitations
  set status=case when coalesce(p_accept,false) then 'accepted' else 'declined' end,
      responded_at=now()
  where id=p_invite
  returning * into inv;

  select name into my_name from public.players where id=me;
  if inv.status='accepted' then
    perform public.jl_notification_create(
      inv.sender_id,
      'board-invite',
      'Convite aceite',
      coalesce(my_name,'Jogador')||' aceitou. Escolham Ludo ou Dama no Tabuleiro.',
      './tabuleiro.html#boardInvites',
      'board-invite-accepted:'||inv.id::text
    );
  end if;

  return jsonb_build_object('ok',true,'status',inv.status,'id',inv.id);
end;
$$;

create or replace function public.jl_board_invite_choose_game(
  p_token text,p_invite uuid,p_game text
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  inv public.board_invitations%rowtype;
  game text:=lower(trim(coalesce(p_game,'')));
  selected text;
begin
  if game not in ('ludo','dama') then raise exception 'Jogo inválido.'; end if;

  select * into inv from public.board_invitations where id=p_invite for update;
  if inv.id is null or inv.status<>'accepted'
     or (inv.sender_id<>me and inv.target_id<>me) then
    raise exception 'Convite não está disponível para escolher jogo.';
  end if;

  if inv.sender_id=me then
    update public.board_invitations set sender_choice=game where id=p_invite;
  else
    update public.board_invitations set target_choice=game where id=p_invite;
  end if;

  select * into inv from public.board_invitations where id=p_invite;
  selected:=case
    when inv.sender_choice is not null and inv.sender_choice=inv.target_choice
    then inv.sender_choice else null end;

  update public.board_invitations
  set selected_game=selected
  where id=p_invite
  returning * into inv;

  if selected is not null then
    perform public.jl_notification_create(
      case when me=inv.sender_id then inv.target_id else inv.sender_id end,
      'board-game-selected',
      case selected when 'ludo' then 'Ludo escolhido' else 'Dama escolhida' end,
      'Os dois escolheram o mesmo jogo. Configure a partida no Tabuleiro.',
      './tabuleiro.html#boardInvites',
      'board-game-selected:'||inv.id::text||':'||selected
    );
  end if;

  return jsonb_build_object(
    'ok',true,'id',inv.id,'selected_game',inv.selected_game,
    'sender_choice',inv.sender_choice,'target_choice',inv.target_choice
  );
end;
$$;

revoke all on function public.jl_board_invite_send(text,uuid) from public,anon,authenticated;
revoke all on function public.jl_board_invites_feed(text) from public,anon,authenticated;
revoke all on function public.jl_board_invite_respond(text,uuid,boolean) from public,anon,authenticated;
revoke all on function public.jl_board_invite_choose_game(text,uuid,text) from public,anon,authenticated;

grant execute on function public.jl_board_invite_send(text,uuid) to anon,authenticated;
grant execute on function public.jl_board_invites_feed(text) to anon,authenticated;
grant execute on function public.jl_board_invite_respond(text,uuid,boolean) to anon,authenticated;
grant execute on function public.jl_board_invite_choose_game(text,uuid,text) to anon,authenticated;
