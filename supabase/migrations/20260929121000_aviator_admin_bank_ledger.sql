-- Aviator: historico administrativo enxuto dos movimentos da banca.
-- Carregado sob demanda pelo admin; nao entra no polling publico nem no estado admin frequente.

create or replace function public.jl_aviator_admin_bank_ledger(
  p_token text,
  p_limit integer default 30
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_limit integer:=least(50,greatest(1,coalesce(p_limit,30)));
  v_rows jsonb;
begin
  perform public.jl_require_admin(p_token);

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',q.id,
        'type',q.entry_type,
        'delta',q.delta,
        'balance_after',q.balance_after,
        'reason',q.reason,
        'created_at',q.created_at
      )
      order by q.id desc
    ),
    '[]'::jsonb
  )
  into v_rows
  from (
    select
      l.id,
      case
        when l.request_key like 'cashout:%' then 'cashout'
        when l.request_key like 'lost-round:%' then 'lost_stake'
        else 'admin_adjustment'
      end as entry_type,
      l.delta,
      l.balance_after,
      l.reason,
      l.created_at
    from public.jl_aviator_bank_ledger l
    order by l.id desc
    limit v_limit
  ) q;

  return v_rows;
end
$$;

revoke all on function public.jl_aviator_admin_bank_ledger(text,integer)
from public;

grant execute on function public.jl_aviator_admin_bank_ledger(text,integer)
to anon,authenticated,service_role;
