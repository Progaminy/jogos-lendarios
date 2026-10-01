-- Aviator ponto 67: abertura exige certificação completa e repetida.
begin;

update public.jl_aviator_rounds
set status='CANCELLED',
    settled_at=coalesce(settled_at,clock_timestamp())
where status in ('OPEN','LOCKED','FLYING','CRASHED');

update public.jl_aviator_settings
set enabled=false,
    one_round_test=false,
    updated_at=clock_timestamp()
where id=true;

do $point67$
declare
  v_admin uuid;
  v_token text:='release-admin-'||gen_random_uuid()::text;
  v_probe jsonb;
  v_gate jsonb;
  v_open jsonb;
  v_state jsonb;
  v_bad_player uuid;
  v_blocked boolean:=false;
  v_enabled boolean;
begin
  insert into public.admin_accounts(display_name,role,code_hash,code_scheme,active)
  values('AVIATOR RELEASE GATE TEST','admin','test-hash','bcrypt',true)
  returning id into v_admin;

  insert into public.admin_sessions(admin_id,token_hash,expires_at)
  values(v_admin,public.jl_token_hash(v_token),clock_timestamp()+interval '1 hour');

  v_probe:=public.jl_aviator_release_flow_probe(3);

  if coalesce((v_probe->>'ok')::boolean,false) is distinct from true
     or (v_probe->>'passed')::integer<>3 then
    raise exception 'Ponto 67: fluxo repetido 3x falhou: %',v_probe;
  end if;

  v_gate:=public.jl_aviator_admin_release_gate(v_token);

  if coalesce((v_gate->>'ok')::boolean,false) is distinct from true then
    raise exception 'Ponto 67: gate limpo deveria passar: %',v_gate;
  end if;

  if coalesce((v_gate->'financial_consistency'->>'ok')::boolean,false) is distinct from true then
    raise exception 'Ponto 67: gate não incluiu reconciliação financeira: %',v_gate;
  end if;

  if (v_gate->'repeated_flow'->>'passed')::integer<>3 then
    raise exception 'Ponto 67: gate não exigiu 3 fluxos completos: %',v_gate;
  end if;

  v_state:=public.jl_aviator_admin_release_gate_state(v_token);

  if coalesce((v_state->>'passed')::boolean,false) is distinct from true then
    raise exception 'Ponto 67: estado da certificação não ficou aprovado: %',v_state;
  end if;

  -- Abertura limpa deve ser permitida pelo wrapper que aplica o gate.
  v_open:=public.jl_aviator_admin_set_enabled(v_token,true);

  if coalesce((v_open->>'enabled')::boolean,false) is distinct from true
     or coalesce((v_open->'release_gate'->>'ok')::boolean,false) is distinct from true then
    raise exception 'Ponto 67: abertura certificada falhou: %',v_open;
  end if;

  perform public.jl_aviator_admin_set_enabled(v_token,false);

  -- Introduz divergência: saldo sem contrapartida no ledger.
  insert into public.players(name,phone,pin_hash,balance)
  values(
    'AVIATOR RELEASE BAD PLAYER',
    'release-bad-'||gen_random_uuid()::text,
    'test-only',
    1
  )
  returning id into v_bad_player;

  -- A criação com saldo gera o lançamento inicial automaticamente.
  -- Para simular corrupção real, altera apenas o cache depois.
  update public.players
     set balance=balance+1
   where id=v_bad_player;

  begin
    perform public.jl_aviator_admin_set_enabled(v_token,true);
  exception
    when others then
      if position('Certificação completa do Aviator falhou' in sqlerrm)>0 then
        v_blocked:=true;
      else
        raise;
      end if;
  end;

  if not v_blocked then
    raise exception 'Ponto 67: jogo abriu com divergência financeira';
  end if;

  select enabled into v_enabled
  from public.jl_aviator_settings
  where id=true;

  if v_enabled is distinct from false then
    raise exception 'Ponto 67: enabled ficou true apesar da certificação falhar';
  end if;
end
$point67$;

rollback;
