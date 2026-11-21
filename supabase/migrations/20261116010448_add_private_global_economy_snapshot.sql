create or replace function public.scrl_economy_snapshot()
returns jsonb
language plpgsql stable security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_tokens numeric;
  v_vrub numeric;
  v_rate numeric;
  v_fee numeric;
  v_fees numeric;
  v_burned numeric;
  v_ratio numeric;
  v_limit numeric;
begin
  if auth.uid() is null then raise exception 'Требуется вход.'; end if;
  select target_rate,fees_scrl,burned_scrl into v_rate,v_fees,v_burned
    from public.platform_settings where singleton=true;
  select coalesce(sum(scrl+hold_scrl),0),coalesce(sum(vrub+hold_vrub),0)
    into v_tokens,v_vrub from public.wallets;
  v_ratio := case when v_tokens>0 and v_rate>0 then v_vrub/(v_tokens*v_rate) else 0 end;
  v_limit := case when v_rate>0 then v_vrub/v_rate else 0 end;
  if v_tokens<=0 or v_rate<=0 then v_fee:=0.01;
  elsif v_ratio<1 then v_fee:=least(0.2,greatest(0,0.005+(1-v_ratio)*0.2));
  elsif v_ratio<2 then v_fee:=greatest(0,0.005*(2-v_ratio));
  else v_fee:=0;
  end if;
  return jsonb_build_object(
    'tokens',round(v_tokens,2),
    'vrub',round(v_vrub,2),
    'rate',round(v_rate,4),
    'fee',round(v_fee,6),
    'fees',round(coalesce(v_fees,0),2),
    'burned',round(coalesce(v_burned,0),2),
    'ratio',round(coalesce(v_ratio,0),4),
    'limit',round(coalesce(v_limit,0),2)
  );
end;
$$;
revoke all on function public.scrl_economy_snapshot() from public,anon;
grant execute on function public.scrl_economy_snapshot() to authenticated;
