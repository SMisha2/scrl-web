create or replace function public.scrl_handle_new_user()
returns trigger
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_name text;
  v_role text := 'student';
begin
  perform pg_advisory_xact_lock(hashtext('scrl_initial_admin'));
  if not exists(select 1 from public.profiles) then
    v_role := 'admin';
  end if;
  v_name := coalesce(nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''), split_part(coalesce(new.email,''),'@',1), 'Участник');
  insert into public.profiles(id, full_name, role) values (new.id, left(v_name,100), v_role) on conflict (id) do nothing;
  insert into public.wallets(user_id, scrl, vrub) values (new.id, 100, 50) on conflict (user_id) do nothing;
  insert into public.ledger(user_id, currency, delta, note) values
    (new.id, 'ScRl', 100, 'Стартовый баланс'),
    (new.id, 'V-RUB', 50, 'Стартовый виртуальный баланс');
  return new;
end;
$$;

create or replace function public.scrl_deal_action(p_deal uuid, p_action text, p_share numeric default 1)
returns void
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_deal public.deals%rowtype;
  v_fee_rate numeric;
  v_fee numeric;
  v_gross numeric;
  v_seller numeric;
  v_buyer numeric;
begin
  if auth.uid() is null then raise exception 'Требуется вход.'; end if;
  select * into v_deal from public.deals where id=p_deal for update;
  if not found then raise exception 'Сделка не найдена.'; end if;

  if p_action='delivered' then
    if auth.uid() <> v_deal.seller_id or v_deal.status <> 'work' then raise exception 'Нельзя отметить выполнение этой сделки.'; end if;
    update public.deals set status='ready' where id=p_deal;
    perform public.scrl_notify(v_deal.buyer_id,'Исполнитель отметил заказ как выполненный.');
    perform public.scrl_log(v_deal.seller_id,'Отмечено выполнение заказа «'||left(v_deal.title,100)||'».');
    return;
  elsif p_action='dispute' then
    if auth.uid() not in (v_deal.buyer_id,v_deal.seller_id) or v_deal.status not in ('work','ready') then raise exception 'Нельзя открыть спор по этой сделке.'; end if;
    update public.deals set status='dispute' where id=p_deal;
    insert into public.reports(kind,target_id,reporter_id,reason,reason_code)
      values('deal',p_deal::text,auth.uid(),'Спор по сделке «'||left(v_deal.title,100)||'»','deal');
    perform public.scrl_notify(v_deal.buyer_id,'Открыт спор по сделке.');
    perform public.scrl_notify(v_deal.seller_id,'Открыт спор по сделке.');
    perform public.scrl_log(auth.uid(),'Открыт спор по сделке «'||left(v_deal.title,100)||'».');
    return;
  end if;

  if p_action not in ('confirm','refund','pay','split') then raise exception 'Неизвестное действие.'; end if;
  if p_action='confirm' then
    if auth.uid() <> v_deal.buyer_id or v_deal.status <> 'ready' then raise exception 'Сначала исполнитель должен отметить выполнение.'; end if;
    p_action := 'pay';
  elsif not public.scrl_is_admin() then
    raise exception 'Нет доступа.';
  end if;
  if v_deal.status not in ('ready','dispute','work') then raise exception 'Сделка уже завершена.'; end if;
  if v_deal.escrow <= 0 then
    update public.deals set status=case when p_action='refund' then 'refund' else 'done' end, closed_at=now() where id=p_deal;
    return;
  end if;

  if p_action='refund' then
    v_gross := 0; v_fee := 0; v_seller := 0; v_buyer := v_deal.escrow;
  else
    v_fee_rate := public.scrl_current_fee();
    v_gross := case when p_action='split' then round(v_deal.escrow * least(1,greatest(0,coalesce(p_share,0.5))),2) else v_deal.escrow end;
    v_fee := round(v_gross * coalesce(v_fee_rate,0.01),2);
    v_seller := v_gross - v_fee;
    v_buyer := v_deal.escrow - v_gross;
  end if;
  update public.wallets set hold_scrl=greatest(0,hold_scrl-v_deal.escrow), updated_at=now() where user_id=v_deal.buyer_id;
  if v_seller > 0 then
    update public.wallets set scrl=scrl+v_seller, updated_at=now() where user_id=v_deal.seller_id;
    insert into public.ledger(user_id,currency,delta,note,actor_id) values(v_deal.seller_id,'ScRl',v_seller,'Оплата по сделке: '||left(v_deal.title,100),auth.uid());
  end if;
  if v_buyer > 0 then
    update public.wallets set scrl=scrl+v_buyer, updated_at=now() where user_id=v_deal.buyer_id;
    insert into public.ledger(user_id,currency,delta,note,actor_id) values(v_deal.buyer_id,'ScRl',v_buyer,'Возврат по сделке: '||left(v_deal.title,100),auth.uid());
  end if;
  update public.platform_settings set fees_scrl=fees_scrl+v_fee, burned_scrl=burned_scrl+v_fee, updated_at=now() where singleton=true;
  update public.deals set escrow=0, status=case when p_action='refund' then 'refund' else 'done' end, closed_at=now() where id=p_deal;
  perform public.scrl_notify(v_deal.buyer_id,'Сделка «'||left(v_deal.title,100)||'» завершена.');
  perform public.scrl_notify(v_deal.seller_id,'Сделка «'||left(v_deal.title,100)||'» завершена.');
  perform public.scrl_log(auth.uid(),'Сделка «'||left(v_deal.title,100)||'» завершена.');
end;
$$;

create or replace function public.scrl_buy_exchange_order(p_order uuid)
returns void
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_order public.exchange_orders%rowtype;
  v_seller_wallet public.wallets%rowtype;
  v_buyer_wallet public.wallets%rowtype;
  v_qty numeric;
  v_cost numeric;
  v_fee_rate numeric;
  v_fee numeric;
  v_scrl numeric;
  v_vrub numeric;
begin
  if auth.uid() is null then raise exception 'Требуется вход.'; end if;
  select * into v_order from public.exchange_orders where id=p_order and status='active' for update;
  if not found then raise exception 'Предложение уже недоступно.'; end if;
  if v_order.owner_id=auth.uid() then raise exception 'Нельзя купить собственное предложение.'; end if;
  if exists(select 1 from public.profiles where id in (auth.uid(),v_order.owner_id) and blocked) then raise exception 'Один из участников заблокирован.'; end if;
  select * into v_seller_wallet from public.wallets where user_id=v_order.owner_id for update;
  select * into v_buyer_wallet from public.wallets where user_id=auth.uid() for update;
  v_qty := v_order.amount;
  v_cost := round(v_qty*v_order.price,2);
  v_fee_rate := public.scrl_current_fee();
  if v_order.side='scrlSell' then
    if v_seller_wallet.hold_scrl < v_qty then raise exception 'Резерв ScRl не найден.'; end if;
    if v_buyer_wallet.vrub < v_cost then raise exception 'Не хватает V-RUB для покупки ScRl.'; end if;
    v_fee := round(v_qty*coalesce(v_fee_rate,0.01),2);
    update public.wallets set vrub=vrub-v_cost, scrl=scrl+round(greatest(0,v_qty-v_fee),2), updated_at=now() where user_id=auth.uid();
    update public.wallets set hold_scrl=hold_scrl-v_qty, vrub=vrub+v_cost, updated_at=now() where user_id=v_order.owner_id;
    v_scrl := round(greatest(0,v_qty-v_fee),2); v_vrub := v_cost;
    insert into public.ledger(user_id,currency,delta,note,actor_id) values
      (auth.uid(),'V-RUB',-v_cost,'Покупка ScRl на бирже',auth.uid()),
      (auth.uid(),'ScRl',v_scrl,'Получено ScRl на бирже',auth.uid()),
      (v_order.owner_id,'V-RUB',v_cost,'Продажа ScRl на бирже',auth.uid());
  else
    if v_seller_wallet.hold_vrub < v_qty then raise exception 'Резерв V-RUB не найден.'; end if;
    if v_buyer_wallet.scrl < v_cost then raise exception 'Не хватает ScRl для покупки V-RUB.'; end if;
    v_fee := round(v_cost*coalesce(v_fee_rate,0.01),2);
    update public.wallets set scrl=scrl-v_cost, vrub=vrub+v_qty, updated_at=now() where user_id=auth.uid();
    update public.wallets set hold_vrub=hold_vrub-v_qty, scrl=scrl+round(greatest(0,v_cost-v_fee),2), updated_at=now() where user_id=v_order.owner_id;
    v_scrl := v_cost; v_vrub := v_qty;
    insert into public.ledger(user_id,currency,delta,note,actor_id) values
      (auth.uid(),'ScRl',-v_cost,'Покупка V-RUB на бирже',auth.uid()),
      (auth.uid(),'V-RUB',v_qty,'Получено V-RUB на бирже',auth.uid()),
      (v_order.owner_id,'ScRl',round(greatest(0,v_cost-v_fee),2),'Продажа V-RUB на бирже',auth.uid());
  end if;
  update public.platform_settings set fees_scrl=fees_scrl+v_fee,burned_scrl=burned_scrl+v_fee,updated_at=now() where singleton=true;
  update public.exchange_orders set status='filled',buyer_id=auth.uid(),filled_at=now() where id=p_order;
  insert into public.trades(buyer_id,seller_id,qty,price,amount_scrl,amount_vrub,fee)
    values(auth.uid(),v_order.owner_id,v_scrl,case when v_scrl>0 then round(v_vrub/v_scrl,6) else 0 end,v_scrl,v_vrub,v_fee);
  perform public.scrl_notify(v_order.owner_id,'Твоё предложение на бирже купили.');
  perform public.scrl_notify(auth.uid(),'Обмен завершён.');
  perform public.scrl_log(auth.uid(),'Обмен на бирже завершён.');
end;
$$;

create or replace function public.scrl_teacher_issue(p_student uuid,p_amount integer,p_reason text)
returns void
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare v_teacher public.profiles%rowtype; v_student public.profiles%rowtype; v_week date; v_used integer;
begin
  select * into v_teacher from public.profiles where id=auth.uid() and not blocked;
  if not found or v_teacher.role not in ('teacher','admin') then raise exception 'Нет доступа.'; end if;
  select * into v_student from public.profiles where id=p_student and not blocked;
  if not found or v_student.role<>'student' then raise exception 'Выбери активного ученика.'; end if;
  if v_teacher.role='teacher' and v_student.room<>v_teacher.room then raise exception 'Можно начислять только ученикам своего класса.'; end if;
  if p_amount not between 1 and 500 then raise exception 'Сумма должна быть от 1 до 500 ScRl.'; end if;
  v_week := date_trunc('week', now() at time zone 'Europe/Warsaw')::date;
  insert into public.teacher_issuance(teacher_id,week_start,amount) values(auth.uid(),v_week,0) on conflict do nothing;
  select amount into v_used from public.teacher_issuance where teacher_id=auth.uid() and week_start=v_week for update;
  if v_used+p_amount>500 then raise exception 'Превышен недельный лимит 500 ScRl.'; end if;
  update public.teacher_issuance set amount=amount+p_amount where teacher_id=auth.uid() and week_start=v_week;
  update public.wallets set scrl=scrl+p_amount,updated_at=now() where user_id=p_student;
  insert into public.ledger(user_id,currency,delta,note,actor_id) values(p_student,'ScRl',p_amount,'Начисление: '||left(coalesce(p_reason,'Без комментария'),120),auth.uid());
  perform public.scrl_notify(p_student,'Тебе начислено '||p_amount||' ScRl.');
  insert into public.audit(actor_id,message) values(auth.uid(),'Начислено '||p_amount||' ScRl участнику '||p_student::text);
end;
$$;

drop policy if exists wallets_read_self_or_admin on public.wallets;
create policy wallets_read_self_or_admin on public.wallets for select to authenticated using (
  user_id=auth.uid() or public.scrl_is_admin() or exists(
    select 1 from public.profiles teacher
    join public.profiles student on student.id=user_id
    where teacher.id=auth.uid() and teacher.role='teacher' and not teacher.blocked
      and student.role='student' and not student.blocked and student.room=teacher.room
  )
);
drop policy if exists ledger_read_self_or_admin on public.ledger;
create policy ledger_read_self_or_admin on public.ledger for select to authenticated using (
  user_id=auth.uid() or public.scrl_is_admin() or exists(
    select 1 from public.profiles teacher
    join public.profiles student on student.id=ledger.user_id
    where teacher.id=auth.uid() and teacher.role='teacher' and not teacher.blocked
      and student.role='student' and not student.blocked and student.room=teacher.room
  )
);
drop policy if exists deals_read_participants on public.deals;
create policy deals_read_participants on public.deals for select to authenticated using (
  buyer_id=auth.uid() or seller_id=auth.uid() or public.scrl_is_admin()
  or exists(
    select 1 from public.profiles teacher
    join public.profiles buyer on buyer.id=buyer_id
    join public.profiles seller on seller.id=seller_id
    where teacher.id=auth.uid() and teacher.role='teacher' and not teacher.blocked
      and buyer.room=teacher.room and seller.room=teacher.room
  )
);
revoke execute on function public.scrl_handle_new_user() from authenticated, anon;
