-- Match exchange settlement rounding to the two-decimal wallet ledger.
-- Existing rows were checked before applying: no order rounds below 0.01.

do $migration$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'exchange_orders_min_settlement_check'
      and conrelid = 'public.exchange_orders'::regclass
  ) then
    alter table public.exchange_orders
      add constraint exchange_orders_min_settlement_check
      check (round(amount * price, 2) >= 0.01);
  end if;
end
$migration$;

CREATE OR REPLACE FUNCTION public.scrl_buy_exchange_order(p_order uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
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
  if auth.uid() is null then
    raise exception 'Требуется вход.';
  end if;

  select * into v_order
  from public.exchange_orders
  where id = p_order and status = 'active'
  for update;

  if not found then
    raise exception 'Предложение уже недоступно.';
  end if;

  if v_order.owner_id = auth.uid() then
    raise exception 'Нельзя купить собственное предложение.';
  end if;

  if exists (
    select 1 from public.profiles
    where id in (auth.uid(), v_order.owner_id) and blocked
  ) then
    raise exception 'Один из участников заблокирован.';
  end if;

  v_qty := v_order.amount;
  v_cost := round(v_qty * v_order.price, 2);

  if v_order.side not in ('scrlSell', 'vrubSell')
     or v_qty is null or v_qty < 1 or trunc(v_qty) <> v_qty
     or v_cost is null or v_cost < 0.01 then
    raise exception 'Заявка содержит некорректную сумму обмена.';
  end if;

  -- Always lock both wallets in ascending UUID order to avoid reciprocal-buy deadlocks.
  if auth.uid() < v_order.owner_id then
    select * into v_buyer_wallet
    from public.wallets
    where user_id = auth.uid()
    for update;

    if not found then
      raise exception 'Кошелёк покупателя не найден.';
    end if;

    select * into v_seller_wallet
    from public.wallets
    where user_id = v_order.owner_id
    for update;

    if not found then
      raise exception 'Кошелёк продавца не найден.';
    end if;
  else
    select * into v_seller_wallet
    from public.wallets
    where user_id = v_order.owner_id
    for update;

    if not found then
      raise exception 'Кошелёк продавца не найден.';
    end if;

    select * into v_buyer_wallet
    from public.wallets
    where user_id = auth.uid()
    for update;

    if not found then
      raise exception 'Кошелёк покупателя не найден.';
    end if;
  end if;

  v_fee_rate := public.scrl_current_fee();

  if v_order.side = 'scrlSell' then
    if v_seller_wallet.hold_scrl < v_qty then
      raise exception 'Резерв ScRl не найден.';
    end if;
    if v_buyer_wallet.vrub < v_cost then
      raise exception 'Не хватает V-RUB для покупки ScRl.';
    end if;

    v_fee := round(v_qty * coalesce(v_fee_rate, 0.01), 2);
    v_scrl := round(greatest(0, v_qty - v_fee), 2);
    v_vrub := v_cost;

    update public.wallets
    set vrub = vrub - v_cost,
        scrl = scrl + v_scrl,
        updated_at = now()
    where user_id = auth.uid();

    update public.wallets
    set hold_scrl = hold_scrl - v_qty,
        vrub = vrub + v_cost,
        updated_at = now()
    where user_id = v_order.owner_id;

    insert into public.ledger(user_id, currency, delta, note, actor_id)
    values
      (auth.uid(), 'V-RUB', -v_cost, 'Покупка ScRl на бирже', auth.uid()),
      (auth.uid(), 'ScRl', v_scrl, 'Получено ScRl на бирже', auth.uid()),
      (v_order.owner_id, 'V-RUB', v_cost, 'Продажа ScRl на бирже', auth.uid());
  else
    if v_seller_wallet.hold_vrub < v_qty then
      raise exception 'Резерв V-RUB не найден.';
    end if;
    if v_buyer_wallet.scrl < v_cost then
      raise exception 'Не хватает ScRl для покупки V-RUB.';
    end if;

    v_fee := round(v_cost * coalesce(v_fee_rate, 0.01), 2);
    v_scrl := v_cost;
    v_vrub := v_qty;

    update public.wallets
    set scrl = scrl - v_cost,
        vrub = vrub + v_qty,
        updated_at = now()
    where user_id = auth.uid();

    update public.wallets
    set hold_vrub = hold_vrub - v_qty,
        scrl = scrl + round(greatest(0, v_cost - v_fee), 2),
        updated_at = now()
    where user_id = v_order.owner_id;

    insert into public.ledger(user_id, currency, delta, note, actor_id)
    values
      (auth.uid(), 'ScRl', -v_cost, 'Покупка V-RUB на бирже', auth.uid()),
      (auth.uid(), 'V-RUB', v_qty, 'Получено V-RUB на бирже', auth.uid()),
      (v_order.owner_id, 'ScRl', round(greatest(0, v_cost - v_fee), 2), 'Продажа V-RUB на бирже', auth.uid());
  end if;

  update public.platform_settings
  set fees_scrl = fees_scrl + v_fee,
      burned_scrl = burned_scrl + v_fee,
      updated_at = now()
  where singleton = true;

  update public.exchange_orders
  set status = 'filled',
      buyer_id = auth.uid(),
      filled_at = now()
  where id = p_order;

  insert into public.trades(buyer_id, seller_id, qty, price, amount_scrl, amount_vrub, fee)
  values(
    auth.uid(),
    v_order.owner_id,
    v_scrl,
    case when v_scrl > 0 then round(v_vrub / v_scrl, 6) else 0 end,
    v_scrl,
    v_vrub,
    v_fee
  );

  perform public.scrl_notify(v_order.owner_id, 'Твоё предложение на бирже купили.');
  perform public.scrl_notify(auth.uid(), 'Обмен завершён.');
  perform public.scrl_log(auth.uid(), 'Обмен на бирже завершён.');
end;
$function$;

CREATE OR REPLACE FUNCTION public.scrl_cancel_exchange_order(p_order uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_order public.exchange_orders%rowtype;
  v_wallet public.wallets%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Требуется вход.';
  end if;

  select * into v_order
  from public.exchange_orders
  where id = p_order and status = 'active' and owner_id = auth.uid()
  for update;

  if not found then
    raise exception 'Активная заявка не найдена.';
  end if;

  select * into v_wallet
  from public.wallets
  where user_id = auth.uid()
  for update;

  if not found then
    raise exception 'Кошелёк не найден. Резерв не был изменён.';
  end if;

  if v_order.side = 'scrlSell' then
    if v_wallet.hold_scrl < v_order.amount then
      raise exception 'Резерв ScRl не соответствует заявке. Обратись к администратору.';
    end if;

    update public.wallets
    set hold_scrl = hold_scrl - v_order.amount,
        scrl = scrl + v_order.amount,
        updated_at = now()
    where user_id = auth.uid();

    insert into public.ledger(user_id, currency, delta, note, actor_id)
    values(auth.uid(), 'ScRl', v_order.amount, 'Возврат резерва заявки биржи', auth.uid());
  elsif v_order.side = 'vrubSell' then
    if v_wallet.hold_vrub < v_order.amount then
      raise exception 'Резерв V-RUB не соответствует заявке. Обратись к администратору.';
    end if;

    update public.wallets
    set hold_vrub = hold_vrub - v_order.amount,
        vrub = vrub + v_order.amount,
        updated_at = now()
    where user_id = auth.uid();

    insert into public.ledger(user_id, currency, delta, note, actor_id)
    values(auth.uid(), 'V-RUB', v_order.amount, 'Возврат резерва заявки биржи', auth.uid());
  else
    raise exception 'У заявки неизвестное направление обмена.';
  end if;

  update public.exchange_orders
  set status = 'cancelled', cancelled_at = now()
  where id = p_order;
end;
$function$;

CREATE OR REPLACE FUNCTION public.scrl_place_exchange_order(p_side text, p_amount numeric, p_price numeric)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_wallet public.wallets%rowtype;
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Требуется вход.';
  end if;

  if p_side is null
     or p_side not in ('scrlSell', 'vrubSell')
     or p_amount is null
     or p_amount < 1
     or p_amount > 1000000
     or trunc(p_amount) <> p_amount
     or p_price is null
     or p_price < 0.0001
     or p_price > 10000
     or round(p_amount * p_price, 2) < 0.01 then
    raise exception 'Проверь направление, количество и цену. Сумма сделки после округления должна быть не меньше 0,01.';
  end if;

  if exists (
    select 1 from public.profiles
    where id = auth.uid() and blocked
  ) then
    raise exception 'Аккаунт заблокирован.';
  end if;

  select * into v_wallet
  from public.wallets
  where user_id = auth.uid()
  for update;

  if not found then
    raise exception 'Кошелёк не найден. Обратись к администратору.';
  end if;

  if p_side = 'scrlSell' then
    if v_wallet.scrl < p_amount then
      raise exception 'Не хватает ScRl для резерва.';
    end if;

    update public.wallets
    set scrl = scrl - p_amount,
        hold_scrl = hold_scrl + p_amount,
        updated_at = now()
    where user_id = auth.uid();

    insert into public.ledger(user_id, currency, delta, note, actor_id)
    values(auth.uid(), 'ScRl', -p_amount, 'Резерв заявки: продажа ScRl', auth.uid());
  else
    if v_wallet.vrub < p_amount then
      raise exception 'Не хватает V-RUB для резерва.';
    end if;

    update public.wallets
    set vrub = vrub - p_amount,
        hold_vrub = hold_vrub + p_amount,
        updated_at = now()
    where user_id = auth.uid();

    insert into public.ledger(user_id, currency, delta, note, actor_id)
    values(auth.uid(), 'V-RUB', -p_amount, 'Резерв заявки: продажа V-RUB', auth.uid());
  end if;

  insert into public.exchange_orders(side, owner_id, amount, price)
  values(p_side, auth.uid(), p_amount, p_price)
  returning id into v_id;

  perform public.scrl_log(auth.uid(), 'Выставлена заявка на продажу ' ||
    p_amount::text || case when p_side = 'scrlSell' then ' ScRl.' else ' V-RUB.' end);

  return v_id;
end;
$function$;
