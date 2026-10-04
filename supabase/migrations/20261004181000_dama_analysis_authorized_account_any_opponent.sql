-- Dama Lendária — contas autorizadas podem receber análise contra qualquer adversário.
-- Mantém o motor restrito às duas contas configuradas em dama_analysis_testers,
-- mas deixa de exigir que ambas estejam jogando uma contra a outra.

create or replace function public.jl_dama_analysis_access(p_token text,p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  v_self boolean:=false;
  v_members integer:=0;
begin
  if me is null or not public.jl_dama_is_member(p_room,me) then
    return jsonb_build_object(
      'enabled',false,
      'self_authorized',false,
      'room_ready',false,
      'reason','NOT_MEMBER'
    );
  end if;

  select exists(
    select 1
    from public.dama_analysis_testers
    where player_id=me
  ) into v_self;

  select count(*) into v_members
  from public.dama_room_players
  where room_id=p_room and status<>'left';

  return jsonb_build_object(
    'enabled', v_self and v_members=2,
    'self_authorized',v_self,
    'room_ready',v_members=2,
    'reason',case
      when not v_self then 'ACCOUNT_NOT_AUTHORIZED'
      when v_members<>2 then 'TWO_PLAYERS_REQUIRED'
      else 'OK'
    end
  );
end;
$$;

revoke all on function public.jl_dama_analysis_access(text,uuid) from public,anon,authenticated;
grant execute on function public.jl_dama_analysis_access(text,uuid) to anon,authenticated;
