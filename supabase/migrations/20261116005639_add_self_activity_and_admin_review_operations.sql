create or replace function public.scrl_log_self(p_message text)
returns void
language plpgsql security definer
set search_path=public,auth,pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'Требуется вход.'; end if;
  if length(trim(coalesce(p_message,'')))=0 or length(p_message)>300 then return; end if;
  insert into public.activity(user_id,message) values(auth.uid(),trim(p_message));
end;
$$;

create or replace function public.scrl_admin_resolve_dispute(p_deal uuid,p_action text,p_share numeric default 0.5)
returns void
language plpgsql security definer
set search_path=public,auth,pg_temp
as $$
begin
  if not public.scrl_is_admin() then raise exception 'Нет доступа.'; end if;
  if p_action not in ('refund','pay','split') then raise exception 'Некорректное решение.'; end if;
  perform public.scrl_deal_action(p_deal,p_action,p_share);
  update public.reports set status='resolved' where kind='deal' and target_id=p_deal::text and status='open';
  insert into public.audit(actor_id,message) values(auth.uid(),'Решён спор по сделке '||p_deal::text||' · '||p_action);
end;
$$;

create or replace function public.scrl_scan_publications()
returns integer
language plpgsql security definer
set search_path=public,auth,pg_temp
as $$
declare v_count integer:=0; v_row record;
begin
  if not public.scrl_is_admin() then raise exception 'Нет доступа.'; end if;
  for v_row in
    select id::text as target_id,'post'::text as kind,owner_id,title||' '||description as body
      from public.posts where status='active'
    union all
    select id::text,'listing'::text,owner_id,title||' '||description
      from public.listings where status='active'
  loop
    if v_row.body ~* '(https?://|www\.|[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}|\+?[0-9][0-9 ()-]{8,})' then
      if v_row.kind='post' then update public.posts set status='review' where id::text=v_row.target_id;
      else update public.listings set status='review' where id::text=v_row.target_id; end if;
      insert into public.reports(kind,target_id,reporter_id,reason,reason_code)
        values(v_row.kind,v_row.target_id,v_row.owner_id,'Повторная проверка: ссылка или контактные данные','auto');
      v_count:=v_count+1;
    end if;
  end loop;
  insert into public.audit(actor_id,message) values(auth.uid(),'Повторно проверено публикаций: '||v_count);
  return v_count;
end;
$$;

create index if not exists reports_reporter_idx on public.reports(reporter_id);
create index if not exists reviews_target_idx on public.reviews(target_id);
create index if not exists reviews_user_idx on public.reviews(user_id);
create index if not exists trades_buyer_idx on public.trades(buyer_id);
create index if not exists trades_seller_idx on public.trades(seller_id);

revoke all on function public.scrl_log_self(text) from public,anon;
revoke all on function public.scrl_admin_resolve_dispute(uuid,text,numeric) from public,anon;
revoke all on function public.scrl_scan_publications() from public,anon;
revoke all on function public.scrl_notify(uuid,text) from authenticated;
revoke all on function public.scrl_log(uuid,text) from authenticated;
revoke all on function public.scrl_handle_new_user() from authenticated;
revoke all on function public.scrl_current_fee() from authenticated;
grant execute on function public.scrl_log_self(text) to authenticated;
grant execute on function public.scrl_admin_resolve_dispute(uuid,text,numeric) to authenticated;
grant execute on function public.scrl_scan_publications() to authenticated;
