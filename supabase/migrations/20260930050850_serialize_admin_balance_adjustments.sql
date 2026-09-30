CREATE OR REPLACE FUNCTION public.jl_admin_adjust_balance(p_token text, p_player_id uuid, p_delta numeric, p_note text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_balance numeric;
begin
  perform public.jl_require_admin_elevated(p_token);
  if p_delta is null or p_delta=0 or abs(p_delta)>1000000 then raise exception 'Ajuste inválido.'; end if;
  perform public.jl_lock_player_wallet(p_player_id);
  select balance into v_balance from public.players where id=p_player_id for update;
  if v_balance is null then raise exception 'Jogador não encontrado.'; end if;
  if v_balance+p_delta<0 then raise exception 'O ajuste deixaria o saldo negativo.'; end if;
  update public.players set balance=round(balance+p_delta,2),updated_at=now() where id=p_player_id returning balance into v_balance;
  insert into public.transactions(player_id,kind,amount,status,note) values(p_player_id,'adjustment',round(p_delta,2),'completed',left(trim(coalesce(p_note,'')),160));
  return jsonb_build_object('ok',true,'balance',v_balance);
end;
$function$;