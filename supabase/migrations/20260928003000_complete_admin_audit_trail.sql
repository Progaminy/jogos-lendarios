-- Ponto 8 — auditoria administrativa completa e identificável.
-- Não altera regras de jogo nem valores. Apenas melhora a rastreabilidade
-- de ações administrativas e preserva o livro financeiro em transactions.

alter table public.audit_log
  add column if not exists actor_admin_id uuid,
  add column if not exists actor_session_id uuid,
  add column if not exists actor_name text,
  add column if not exists actor_role text,
  add column if not exists target_type text,
  add column if not exists target_id text,
  add column if not exists before_state jsonb,
  add column if not exists after_state jsonb;

create index if not exists audit_log_actor_admin_idx
  on public.audit_log(actor_admin_id, created_at desc);

create index if not exists audit_log_target_idx
  on public.audit_log(target_type, target_id, created_at desc);

create or replace function public.jl_admin_account_id(p_token text)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_admin uuid;
  v_session uuid;
  v_name text;
  v_role text;
begin
  delete from public.admin_sessions where expires_at<=now();

  select s.id,s.admin_id,a.display_name,a.role
  into v_session,v_admin,v_name,v_role
  from public.admin_sessions s
  join public.admin_accounts a on a.id=s.admin_id and a.active
  where s.token_hash=public.jl_token_hash(p_token)
    and s.expires_at>now()
  limit 1;

  if v_admin is not null then
    perform set_config('jl.admin_id',v_admin::text,true);
    perform set_config('jl.admin_session_id',v_session::text,true);
    perform set_config('jl.admin_name',coalesce(v_name,''),true);
    perform set_config('jl.admin_role',coalesce(v_role,''),true);
  end if;

  return v_admin;
end;
$function$;

revoke all on function public.jl_admin_account_id(text)
from public, anon, authenticated;

create or replace function public.jl_require_admin_elevated(p_token text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_admin uuid:=public.jl_admin_account_id(p_token);
  v_ok boolean;
begin
  if v_admin is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  select exists(
    select 1
    from public.admin_sessions s
    where s.token_hash=public.jl_token_hash(p_token)
      and s.admin_id=v_admin
      and s.expires_at>now()
      and s.elevated_until>now()
  ) into v_ok;

  if not v_ok then
    raise exception 'REAUTH_REQUIRED: Confirme novamente o código administrativo para continuar.';
  end if;
end;
$function$;

revoke all on function public.jl_require_admin_elevated(text)
from public, anon, authenticated;

create or replace function public.jl_enrich_admin_audit()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_admin text:=nullif(current_setting('jl.admin_id',true),'');
  v_session text:=nullif(current_setting('jl.admin_session_id',true),'');
  v_name text:=nullif(current_setting('jl.admin_name',true),'');
  v_role text:=nullif(current_setting('jl.admin_role',true),'');
begin
  if new.actor_admin_id is null and v_admin is not null then
    new.actor_admin_id:=v_admin::uuid;
  end if;
  if new.actor_session_id is null and v_session is not null then
    new.actor_session_id:=v_session::uuid;
  end if;
  new.actor_name:=coalesce(new.actor_name,v_name);
  new.actor_role:=coalesce(new.actor_role,v_role);

  if v_admin is not null then
    new.details:=coalesce(new.details,'{}'::jsonb)
      || jsonb_build_object(
        'admin_id',v_admin,
        'admin_session_id',v_session,
        'admin_name',v_name,
        'admin_role',v_role
      );
  end if;

  return new;
end;
$function$;

revoke all on function public.jl_enrich_admin_audit()
from public, anon, authenticated;

drop trigger if exists trg_jl_enrich_admin_audit on public.audit_log;
create trigger trg_jl_enrich_admin_audit
before insert on public.audit_log
for each row execute function public.jl_enrich_admin_audit();

create or replace function public.jl_audit_admin_row_change()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_admin text:=nullif(current_setting('jl.admin_id',true),'');
  v_session text:=nullif(current_setting('jl.admin_session_id',true),'');
  v_name text:=nullif(current_setting('jl.admin_name',true),'');
  v_role text:=nullif(current_setting('jl.admin_role',true),'');
  v_before jsonb;
  v_after jsonb;
  v_action text;
  v_target_id text;
begin
  if v_admin is null then
    return case when tg_op='DELETE' then old else new end;
  end if;

  v_before:=case when tg_op='INSERT' then null else to_jsonb(old) end;
  v_after:=case when tg_op='DELETE' then null else to_jsonb(new) end;

  if v_before is not null then
    v_before:=v_before - array['pin_hash','secret_hash','otp_hash','code_hash','legacy_sha256_hash','token_hash'];
  end if;
  if v_after is not null then
    v_after:=v_after - array['pin_hash','secret_hash','otp_hash','code_hash','legacy_sha256_hash','token_hash'];
  end if;

  v_target_id:=coalesce(v_after->>'id',v_before->>'id');

  if tg_table_name='players' then
    if tg_op='UPDATE' and old.blocked is distinct from new.blocked then
      v_action:='admin_set_blocked';
    elsif tg_op='UPDATE' and old.balance is distinct from new.balance then
      v_action:='admin_player_balance_change';
    else
      return new;
    end if;
  elsif tg_table_name='deposit_requests' then
    v_action:='admin_review_deposit';
  elsif tg_table_name='withdrawal_requests' then
    v_action:='admin_review_withdrawal';
  elsif tg_table_name='game_settings' then
    v_action:='admin_update_game_settings';
    v_target_id:=coalesce(v_after->>'game_type',v_before->>'game_type');
  elsif tg_table_name='influencers' then
    if tg_op='INSERT' then v_action:='admin_create_influencer';
    elsif old.active is distinct from new.active then v_action:='admin_set_influencer_active';
    else v_action:='admin_update_influencer';
    end if;
  elsif tg_table_name='draw_schedule' then
    if tg_op='INSERT' then v_action:='admin_add_draw_time';
    elsif new.status='cancelled' and old.status is distinct from new.status then v_action:='admin_cancel_draw_time';
    else v_action:='admin_update_draw_schedule';
    end if;
  elsif tg_table_name='game_rounds' then
    if tg_op='INSERT' then v_action:='admin_open_game_round';
    else v_action:='admin_update_game_round';
    end if;
  elsif tg_table_name='pin_recovery_requests' then
    v_action:='admin_pin_recovery_change';
  elsif tg_table_name='admin_accounts' then
    if tg_op='INSERT' then v_action:='admin_create_account';
    elsif old.active is distinct from new.active then v_action:='admin_set_account_active';
    elsif old.role is distinct from new.role or old.display_name is distinct from new.display_name then v_action:='admin_update_account';
    elsif old.code_scheme is distinct from new.code_scheme or old.code_hash is distinct from new.code_hash then v_action:='admin_change_admin_code';
    else return new;
    end if;
  else
    v_action:='admin_'||lower(tg_op)||'_'||tg_table_name;
  end if;

  insert into public.audit_log(
    action,details,actor_admin_id,actor_session_id,actor_name,actor_role,
    target_type,target_id,before_state,after_state
  ) values(
    v_action,
    jsonb_build_object(
      'operation',tg_op,
      'table',tg_table_name,
      'target_id',v_target_id,
      'at',now()
    ),
    v_admin::uuid,
    case when v_session is null then null else v_session::uuid end,
    v_name,
    v_role,
    tg_table_name,
    v_target_id,
    v_before,
    v_after
  );

  return case when tg_op='DELETE' then old else new end;
end;
$function$;

revoke all on function public.jl_audit_admin_row_change()
from public, anon, authenticated;

drop trigger if exists trg_jl_audit_players_admin on public.players;
create trigger trg_jl_audit_players_admin
after update of balance,blocked on public.players
for each row execute function public.jl_audit_admin_row_change();

drop trigger if exists trg_jl_audit_deposits_admin on public.deposit_requests;
create trigger trg_jl_audit_deposits_admin
after update on public.deposit_requests
for each row execute function public.jl_audit_admin_row_change();

drop trigger if exists trg_jl_audit_withdrawals_admin on public.withdrawal_requests;
create trigger trg_jl_audit_withdrawals_admin
after update on public.withdrawal_requests
for each row execute function public.jl_audit_admin_row_change();

drop trigger if exists trg_jl_audit_game_settings_admin on public.game_settings;
create trigger trg_jl_audit_game_settings_admin
after update on public.game_settings
for each row execute function public.jl_audit_admin_row_change();

drop trigger if exists trg_jl_audit_influencers_admin on public.influencers;
create trigger trg_jl_audit_influencers_admin
after insert or update on public.influencers
for each row execute function public.jl_audit_admin_row_change();

drop trigger if exists trg_jl_audit_draw_schedule_admin on public.draw_schedule;
create trigger trg_jl_audit_draw_schedule_admin
after insert or update on public.draw_schedule
for each row execute function public.jl_audit_admin_row_change();

drop trigger if exists trg_jl_audit_game_rounds_admin on public.game_rounds;
create trigger trg_jl_audit_game_rounds_admin
after insert or update on public.game_rounds
for each row execute function public.jl_audit_admin_row_change();

drop trigger if exists trg_jl_audit_pin_recovery_admin on public.pin_recovery_requests;
create trigger trg_jl_audit_pin_recovery_admin
after update on public.pin_recovery_requests
for each row execute function public.jl_audit_admin_row_change();

drop trigger if exists trg_jl_audit_admin_accounts on public.admin_accounts;
create trigger trg_jl_audit_admin_accounts
after insert or update on public.admin_accounts
for each row execute function public.jl_audit_admin_row_change();

create or replace function public.jl_admin_recent_audit(p_token text, p_limit integer default 80)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_limit integer:=least(200,greatest(1,coalesce(p_limit,80)));
  v_rows jsonb;
begin
  perform public.jl_require_admin(p_token);

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb)
  into v_rows
  from (
    select
      id,action,details,created_at,
      actor_admin_id,actor_session_id,actor_name,actor_role,
      target_type,target_id,before_state,after_state
    from public.audit_log
    order by created_at desc
    limit v_limit
  ) x;

  return v_rows;
end;
$function$;
