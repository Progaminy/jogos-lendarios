-- Melhoria 12: Linha de Cliente jogador <-> admin.

create table if not exists public.customer_support_messages (
  id uuid primary key default extensions.gen_random_uuid(),
  player_id uuid not null references public.players(id) on delete cascade,
  sender text not null check (sender in ('player','admin')),
  message text not null check (char_length(trim(message)) between 1 and 1000),
  read_by_admin boolean not null default false,
  read_by_player boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.customer_support_messages enable row level security;

create index if not exists customer_support_messages_player_created_idx
on public.customer_support_messages(player_id, created_at desc);

create index if not exists customer_support_messages_admin_unread_idx
on public.customer_support_messages(read_by_admin, created_at desc)
where sender='player';

create or replace function public.jl_support_send(p_token text, p_message text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare me uuid:=public.jl_player_id(p_token); msg text:=trim(coalesce(p_message,'')); mid uuid;
begin
  if char_length(msg)<1 or char_length(msg)>1000 then raise exception 'A mensagem deve ter entre 1 e 1000 caracteres.'; end if;
  insert into public.customer_support_messages(player_id,sender,message,read_by_admin,read_by_player)
  values(me,'player',msg,false,true) returning id into mid;
  return jsonb_build_object('ok',true,'id',mid,'message','Mensagem enviada para a Linha de Cliente.');
end;
$$;

create or replace function public.jl_support_thread(p_token text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare me uuid:=public.jl_player_id(p_token); msgs jsonb;
begin
  update public.customer_support_messages set read_by_player=true
  where player_id=me and sender='admin' and not read_by_player;
  select coalesce(jsonb_agg(x order by x.created_at),'[]'::jsonb) into msgs
  from (select id,sender,message,created_at,read_by_player from public.customer_support_messages
        where player_id=me order by created_at desc limit 100) x;
  return jsonb_build_object('messages',msgs,'unread_admin_replies',0);
end;
$$;

create or replace function public.jl_support_unread_count(p_token text)
returns integer language plpgsql security definer set search_path=public
as $$
declare me uuid:=public.jl_player_id(p_token); c int;
begin
  select count(*) into c from public.customer_support_messages
  where player_id=me and sender='admin' and not read_by_player;
  return c;
end;
$$;

create or replace function public.jl_admin_support_threads(p_token text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare rows jsonb;
begin
  perform public.jl_require_admin(p_token);
  select coalesce(jsonb_agg(x order by x.last_message_at desc),'[]'::jsonb) into rows
  from (
    select p.id player_id,p.name,p.phone,max(m.created_at) last_message_at,
      count(*) filter(where m.sender='player' and not m.read_by_admin) unread_count,
      (array_agg(m.message order by m.created_at desc))[1] last_message,
      (array_agg(m.sender order by m.created_at desc))[1] last_sender
    from public.customer_support_messages m join public.players p on p.id=m.player_id
    group by p.id,p.name,p.phone
  ) x;
  return rows;
end;
$$;

create or replace function public.jl_admin_support_thread(p_token text,p_player_id uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare msgs jsonb; pname text; pphone text;
begin
  perform public.jl_require_admin(p_token);
  select name,phone into pname,pphone from public.players where id=p_player_id;
  if pname is null then raise exception 'Jogador não encontrado.'; end if;
  update public.customer_support_messages set read_by_admin=true
  where player_id=p_player_id and sender='player' and not read_by_admin;
  select coalesce(jsonb_agg(x order by x.created_at),'[]'::jsonb) into msgs
  from (select id,sender,message,created_at from public.customer_support_messages
        where player_id=p_player_id order by created_at desc limit 150) x;
  return jsonb_build_object('player',jsonb_build_object('id',p_player_id,'name',pname,'phone',pphone),'messages',msgs);
end;
$$;

create or replace function public.jl_admin_support_reply(p_token text,p_player_id uuid,p_message text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare msg text:=trim(coalesce(p_message,'')); mid uuid;
begin
  perform public.jl_require_admin(p_token);
  if not exists(select 1 from public.players where id=p_player_id) then raise exception 'Jogador não encontrado.'; end if;
  if char_length(msg)<1 or char_length(msg)>1000 then raise exception 'A mensagem deve ter entre 1 e 1000 caracteres.'; end if;
  insert into public.customer_support_messages(player_id,sender,message,read_by_admin,read_by_player)
  values(p_player_id,'admin',msg,true,false) returning id into mid;
  return jsonb_build_object('ok',true,'id',mid,'message','Resposta enviada ao jogador.');
end;
$$;
