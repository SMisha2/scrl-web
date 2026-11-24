-- Validate aggregate liabilities before consuming any part of the shared hold balances.
-- ScRl holds are shared by escrow deals, sell orders and auction bids; V-RUB holds
-- are reserved by V-RUB sell orders. Every release/settlement must preserve all
-- other outstanding commitments.
BEGIN;

CREATE OR REPLACE FUNCTION private.scrl_required_scrl_holds(p_user uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  SELECT
    coalesce((
      SELECT sum(d.escrow)
      FROM public.deals AS d
      WHERE d.buyer_id = p_user
        AND d.status IN ('work', 'ready', 'dispute')
        AND d.escrow > 0
    ), 0)
    + coalesce((
      SELECT sum(o.amount)
      FROM public.exchange_orders AS o
      WHERE o.owner_id = p_user
        AND o.side = 'scrlSell'
        AND o.status = 'active'
    ), 0)
    + coalesce((
      SELECT sum(a.current_bid)
      FROM public.auctions AS a
      WHERE a.leader_id = p_user
        AND a.status IN ('active', 'settlementError')
        AND a.current_bid > 0
    ), 0);
$function$;

CREATE OR REPLACE FUNCTION private.scrl_required_vrub_holds(p_user uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  SELECT coalesce((
    SELECT sum(o.amount)
    FROM public.exchange_orders AS o
    WHERE o.owner_id = p_user
      AND o.side = 'vrubSell'
      AND o.status = 'active'
  ), 0);
$function$;

REVOKE ALL ON FUNCTION private.scrl_required_scrl_holds(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.scrl_required_vrub_holds(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.scrl_deal_action(
  p_deal uuid,
  p_action text,
  p_share numeric DEFAULT 1
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $function$
DECLARE
  v_deal public.deals%rowtype;
  v_buyer_wallet public.wallets%rowtype;
  v_required_hold numeric;
  v_seller_wallet public.wallets%rowtype;
  v_fee_rate numeric;
  v_fee numeric;
  v_gross numeric;
  v_seller numeric;
  v_buyer numeric;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Требуется вход.';
  END IF;

  SELECT * INTO v_deal
  FROM public.deals
  WHERE id = p_deal
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Сделка не найдена.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND blocked
  ) AND NOT public.scrl_is_admin() THEN
    RAISE EXCEPTION 'Аккаунт заблокирован. Решение по активной сделке принимает администратор.';
  END IF;

  IF p_action = 'delivered' THEN
    IF auth.uid() <> v_deal.seller_id OR v_deal.status <> 'work' THEN
      RAISE EXCEPTION 'Нельзя отметить выполнение этой сделки.';
    END IF;

    UPDATE public.deals SET status = 'ready' WHERE id = p_deal;
    PERFORM public.scrl_notify(v_deal.buyer_id, 'Исполнитель отметил заказ как выполненный.');
    PERFORM public.scrl_log(v_deal.seller_id, 'Отмечено выполнение заказа «' || left(v_deal.title, 100) || '».');
    RETURN;
  ELSIF p_action = 'dispute' THEN
    IF auth.uid() NOT IN (v_deal.buyer_id, v_deal.seller_id)
       OR v_deal.status NOT IN ('work', 'ready') THEN
      RAISE EXCEPTION 'Нельзя открыть спор по этой сделке.';
    END IF;

    UPDATE public.deals SET status = 'dispute' WHERE id = p_deal;
    INSERT INTO public.reports(kind, target_id, reporter_id, reason, reason_code)
    VALUES (
      'deal', p_deal::text, auth.uid(),
      'Спор по сделке «' || left(v_deal.title, 100) || '»', 'deal'
    );
    PERFORM public.scrl_notify(v_deal.buyer_id, 'Открыт спор по сделке.');
    PERFORM public.scrl_notify(v_deal.seller_id, 'Открыт спор по сделке.');
    PERFORM public.scrl_log(auth.uid(), 'Открыт спор по сделке «' || left(v_deal.title, 100) || '».');
    RETURN;
  END IF;

  IF p_action NOT IN ('confirm', 'refund', 'pay', 'split') THEN
    RAISE EXCEPTION 'Неизвестное действие.';
  END IF;

  IF p_action = 'confirm' THEN
    IF auth.uid() <> v_deal.buyer_id OR v_deal.status <> 'ready' THEN
      RAISE EXCEPTION 'Сначала исполнитель должен отметить выполнение.';
    END IF;
    p_action := 'pay';
  ELSIF NOT public.scrl_is_admin() THEN
    RAISE EXCEPTION 'Нет доступа.';
  END IF;

  IF v_deal.status NOT IN ('ready', 'dispute', 'work') THEN
    RAISE EXCEPTION 'Сделка уже завершена.';
  END IF;

  IF v_deal.escrow IS NULL OR v_deal.escrow < 0 THEN
    RAISE EXCEPTION 'У сделки некорректный резерв. Обратись к администратору.';
  END IF;

  IF v_deal.escrow = 0 THEN
    UPDATE public.deals
    SET status = CASE WHEN p_action = 'refund' THEN 'refund' ELSE 'done' END,
        closed_at = now()
    WHERE id = p_deal;
    RETURN;
  END IF;

  IF p_action = 'refund' THEN
    v_gross := 0;
    v_fee := 0;
    v_seller := 0;
    v_buyer := v_deal.escrow;
  ELSE
    v_fee_rate := public.scrl_current_fee();
    v_gross := CASE
      WHEN p_action = 'split'
        THEN round(v_deal.escrow * least(1, greatest(0, coalesce(p_share, 0.5))), 2)
      ELSE v_deal.escrow
    END;
    v_fee := round(v_gross * coalesce(v_fee_rate, 0.01), 2);
    v_seller := v_gross - v_fee;
    v_buyer := v_deal.escrow - v_gross;
  END IF;

  -- A fixed lock order prevents opposite-direction settlements from deadlocking.
  PERFORM w.user_id
  FROM public.wallets AS w
  WHERE w.user_id IN (v_deal.buyer_id, v_deal.seller_id)
  ORDER BY w.user_id
  FOR UPDATE;

  SELECT * INTO v_buyer_wallet
  FROM public.wallets
  WHERE user_id = v_deal.buyer_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Кошелёк покупателя не найден. Выплата остановлена.';
  END IF;

  SELECT * INTO v_seller_wallet
  FROM public.wallets
  WHERE user_id = v_deal.seller_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Кошелёк исполнителя не найден. Выплата остановлена.';
  END IF;

  v_required_hold := private.scrl_required_scrl_holds(v_deal.buyer_id);
  IF v_buyer_wallet.hold_scrl < v_required_hold THEN
    RAISE EXCEPTION 'Общий резерв ScRl покупателя не покрывает все сделки, заявки и ставки. Выплата остановлена.';
  END IF;
  IF v_buyer_wallet.hold_scrl < v_deal.escrow THEN
    RAISE EXCEPTION 'Резерв конкретной сделки не найден. Выплата остановлена.';
  END IF;

  UPDATE public.wallets
  SET hold_scrl = hold_scrl - v_deal.escrow,
      updated_at = now()
  WHERE user_id = v_deal.buyer_id
    AND hold_scrl >= v_deal.escrow;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Не удалось безопасно освободить резерв сделки.';
  END IF;

  IF v_seller > 0 THEN
    UPDATE public.wallets
    SET scrl = scrl + v_seller,
        updated_at = now()
    WHERE user_id = v_deal.seller_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Кошелёк исполнителя недоступен. Выплата отменена.';
    END IF;

    INSERT INTO public.ledger(user_id, currency, delta, note, actor_id)
    VALUES (
      v_deal.seller_id, 'ScRl', v_seller,
      'Оплата по сделке: ' || left(v_deal.title, 100), auth.uid()
    );
  END IF;

  IF v_buyer > 0 THEN
    UPDATE public.wallets
    SET scrl = scrl + v_buyer,
        updated_at = now()
    WHERE user_id = v_deal.buyer_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Кошелёк покупателя недоступен. Возврат отменён.';
    END IF;

    INSERT INTO public.ledger(user_id, currency, delta, note, actor_id)
    VALUES (
      v_deal.buyer_id, 'ScRl', v_buyer,
      'Возврат по сделке: ' || left(v_deal.title, 100), auth.uid()
    );
  END IF;

  UPDATE public.platform_settings
  SET fees_scrl = fees_scrl + v_fee,
      burned_scrl = burned_scrl + v_fee,
      updated_at = now()
  WHERE singleton = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Настройки экономики не найдены. Расчёт сделки отменён.';
  END IF;

  UPDATE public.deals
  SET escrow = 0,
      status = CASE WHEN p_action = 'refund' THEN 'refund' ELSE 'done' END,
      closed_at = now()
  WHERE id = p_deal;

  PERFORM public.scrl_notify(v_deal.buyer_id, 'Сделка «' || left(v_deal.title, 100) || '» завершена.');
  PERFORM public.scrl_notify(v_deal.seller_id, 'Сделка «' || left(v_deal.title, 100) || '» завершена.');
  PERFORM public.scrl_log(auth.uid(), 'Сделка «' || left(v_deal.title, 100) || '» завершена.');
END;
$function$;

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
  v_required_hold numeric;
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

  IF v_order.side = 'scrlSell' THEN
    v_required_hold := private.scrl_required_scrl_holds(v_order.owner_id);
    IF v_seller_wallet.hold_scrl < v_required_hold THEN
      RAISE EXCEPTION 'Общий резерв ScRl продавца не покрывает все сделки, заявки и ставки.';
    END IF;
  ELSE
    v_required_hold := private.scrl_required_vrub_holds(v_order.owner_id);
    IF v_seller_wallet.hold_vrub < v_required_hold THEN
      RAISE EXCEPTION 'Общий резерв V-RUB продавца не покрывает все активные заявки.';
    END IF;
  END IF;

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
  v_required_hold numeric;
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
    v_required_hold := private.scrl_required_scrl_holds(auth.uid());
    if v_wallet.hold_scrl < v_required_hold then
      raise exception 'Общий резерв ScRl не покрывает все сделки, заявки и ставки. Возврат остановлен.';
    end if;
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
    v_required_hold := private.scrl_required_vrub_holds(auth.uid());
    if v_wallet.hold_vrub < v_required_hold then
      raise exception 'Общий резерв V-RUB не покрывает все активные заявки. Возврат остановлен.';
    end if;
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

CREATE OR REPLACE FUNCTION public.scrl_place_bid(p_auction uuid, p_amount numeric)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_auction public.auctions%rowtype;
  v_wallet public.wallets%rowtype;
  v_old public.wallets%rowtype;
  v_role text;
  v_min numeric;
  v_required_hold numeric;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Требуется вход.';
  END IF;

  -- Serialise a user's bids with administrative blocking.
  SELECT role INTO v_role
  FROM public.profiles
  WHERE id = auth.uid() AND NOT blocked AND deleted_at IS NULL
  FOR UPDATE;

  IF v_role IS NULL OR v_role <> 'student' THEN
    RAISE EXCEPTION 'Ставки доступны только активным ученикам.';
  END IF;

  SELECT * INTO v_auction
  FROM public.auctions
  WHERE id = p_auction AND status = 'active' AND ends_at > now()
  FOR UPDATE;

  IF NOT FOUND OR v_auction.owner_id = auth.uid() THEN
    RAISE EXCEPTION 'Этот аукцион уже закрыт или принадлежит тебе.';
  END IF;

  v_min := CASE
    WHEN v_auction.current_bid > 0 THEN v_auction.current_bid + v_auction.step
    ELSE v_auction.start_price
  END;

  IF p_amount IS NULL
     OR p_amount::text = 'NaN'
     OR p_amount < v_min
     OR p_amount > 1000000
     OR trunc(p_amount) <> p_amount THEN
    RAISE EXCEPTION 'Минимальная ставка — % ScRl.', v_min;
  END IF;

  IF v_auction.leader_id IS NOT NULL AND v_auction.current_bid > 0 THEN
    IF v_auction.leader_id = auth.uid() THEN
      SELECT * INTO v_wallet
      FROM public.wallets
      WHERE user_id = auth.uid()
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Кошелёк участника не найден.';
      END IF;
      v_required_hold := private.scrl_required_scrl_holds(auth.uid());
      IF v_wallet.hold_scrl < v_required_hold
         OR v_wallet.hold_scrl < v_auction.current_bid THEN
        RAISE EXCEPTION 'Общий резерв ScRl не покрывает все обязательства участника.';
      END IF;

      UPDATE public.wallets
      SET hold_scrl = hold_scrl - v_auction.current_bid,
          scrl = scrl + v_auction.current_bid,
          updated_at = now()
      WHERE user_id = auth.uid();

      UPDATE public.bids
      SET status = 'raised'
      WHERE auction_id = p_auction
        AND user_id = auth.uid()
        AND amount = v_auction.current_bid
        AND status = 'active';

      INSERT INTO public.ledger(user_id, currency, delta, note, actor_id)
      VALUES (auth.uid(), 'ScRl', v_auction.current_bid, 'Возврат предыдущей ставки перед повышением', auth.uid());

      SELECT * INTO v_wallet
      FROM public.wallets
      WHERE user_id = auth.uid()
      FOR UPDATE;

    ELSE
      -- Always lock the bidder and previous leader wallets in UUID order.
      IF auth.uid() < v_auction.leader_id THEN
        SELECT * INTO v_wallet
        FROM public.wallets
        WHERE user_id = auth.uid()
        FOR UPDATE;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Кошелёк участника не найден.';
        END IF;

        SELECT * INTO v_old
        FROM public.wallets
        WHERE user_id = v_auction.leader_id
        FOR UPDATE;
      ELSE
        SELECT * INTO v_old
        FROM public.wallets
        WHERE user_id = v_auction.leader_id
        FOR UPDATE;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Кошелёк предыдущего лидера не найден.';
        END IF;

        SELECT * INTO v_wallet
        FROM public.wallets
        WHERE user_id = auth.uid()
        FOR UPDATE;
      END IF;

      IF v_wallet.user_id IS NULL THEN
        RAISE EXCEPTION 'Кошелёк участника не найден.';
      END IF;
      IF v_old.user_id IS NULL THEN
        RAISE EXCEPTION 'Кошелёк предыдущего лидера не найден.';
      END IF;
      v_required_hold := private.scrl_required_scrl_holds(auth.uid());
      IF v_wallet.hold_scrl < v_required_hold THEN
        RAISE EXCEPTION 'Общий резерв ScRl участника не покрывает все обязательства.';
      END IF;
      v_required_hold := private.scrl_required_scrl_holds(v_auction.leader_id);
      IF v_old.hold_scrl < v_required_hold
         OR v_old.hold_scrl < v_auction.current_bid THEN
        RAISE EXCEPTION 'Общий резерв ScRl предыдущего лидера не покрывает все обязательства.';
      END IF;

      UPDATE public.wallets
      SET hold_scrl = hold_scrl - v_auction.current_bid,
          scrl = scrl + v_auction.current_bid,
          updated_at = now()
      WHERE user_id = v_auction.leader_id;

      UPDATE public.bids
      SET status = 'outbid'
      WHERE auction_id = p_auction
        AND user_id = v_auction.leader_id
        AND amount = v_auction.current_bid
        AND status = 'active';

      INSERT INTO public.ledger(user_id, currency, delta, note, actor_id)
      VALUES (v_auction.leader_id, 'ScRl', v_auction.current_bid, 'Возврат перебитой ставки', auth.uid());

      PERFORM public.scrl_notify(
        v_auction.leader_id,
        'Твою ставку в аукционе «' || left(v_auction.title, 80) || '» перебили.'
      );
    END IF;

  ELSE
    SELECT * INTO v_wallet
    FROM public.wallets
    WHERE user_id = auth.uid()
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Кошелёк участника не найден.';
    END IF;
    v_required_hold := private.scrl_required_scrl_holds(auth.uid());
    IF v_wallet.hold_scrl < v_required_hold THEN
      RAISE EXCEPTION 'Общий резерв ScRl участника не покрывает все обязательства.';
    END IF;
  END IF;

  IF v_wallet.user_id IS NULL OR v_wallet.scrl < p_amount THEN
    RAISE EXCEPTION 'Недостаточно ScRl для такой ставки.';
  END IF;

  UPDATE public.wallets
  SET scrl = scrl - p_amount,
      hold_scrl = hold_scrl + p_amount,
      updated_at = now()
  WHERE user_id = auth.uid();

  INSERT INTO public.ledger(user_id, currency, delta, note, actor_id)
  VALUES (auth.uid(), 'ScRl', -p_amount, 'Ставка в аукционе: ' || left(v_auction.title, 100), auth.uid());

  INSERT INTO public.bids(auction_id, user_id, amount)
  VALUES (p_auction, auth.uid(), p_amount);

  UPDATE public.auctions
  SET current_bid = p_amount,
      leader_id = auth.uid(),
      bids_count = bids_count + 1
  WHERE id = p_auction;

  PERFORM public.scrl_notify(v_auction.owner_id, 'Новая ставка в аукционе «' || left(v_auction.title, 80) || '».');
  PERFORM public.scrl_log(auth.uid(), 'Сделана ставка ' || p_amount || ' ScRl в аукционе.');
END;
$function$;

create or replace function public.scrl_finish_auction(p_auction uuid)
returns void
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_a public.auctions%rowtype;
  v_wallet public.wallets%rowtype;
  v_required_hold numeric;
begin
  select * into v_a from public.auctions where id=p_auction and status in ('active','settlementError') for update;
  if not found then return; end if;
  if not public.scrl_is_admin() and auth.uid()<>v_a.owner_id and v_a.ends_at>now() then raise exception 'Завершить аукцион можно только после окончания или владельцу.'; end if;
  if v_a.leader_id is not null and v_a.current_bid>0 then
    select * into v_wallet
    from public.wallets
    where user_id=v_a.leader_id
    for update;
    if not found then
      update public.auctions set status='settlementError' where id=p_auction;
      perform public.scrl_notify(v_a.owner_id, 'Аукцион «'||left(v_a.title,80)||'» остановлен: кошелёк победителя не найден.');
      perform public.scrl_notify(v_a.leader_id, 'Выплата по аукциону остановлена: кошелёк требует проверки администратором.');
      return;
    end if;
    v_required_hold := private.scrl_required_scrl_holds(v_a.leader_id);
    if v_wallet.hold_scrl < v_required_hold
       or v_wallet.hold_scrl < v_a.current_bid then
      update public.auctions set status='settlementError' where id=p_auction;
      perform public.scrl_notify(v_a.owner_id, 'Аукцион «'||left(v_a.title,80)||'» остановлен: резерв победителя требует проверки.');
      perform public.scrl_notify(v_a.leader_id, 'Выплата по аукциону остановлена: общий резерв ScRl требует проверки администратора.');
      return;
    end if;
    update public.wallets
    set hold_scrl=hold_scrl-v_a.current_bid,updated_at=now()
    where user_id=v_a.leader_id
      and hold_scrl>=v_a.current_bid;
    if not found then
      raise exception 'Не удалось безопасно освободить резерв победителя.';
    end if;
    update public.bids set status='won' where auction_id=p_auction and user_id=v_a.leader_id and amount=v_a.current_bid and status='active';
    insert into public.ledger(user_id,currency,delta,note,actor_id) values(v_a.leader_id,'ScRl',0,'Победная ставка списана',auth.uid());
    update public.platform_settings set burned_scrl=burned_scrl+v_a.current_bid,updated_at=now() where singleton=true;
    if not found then
      raise exception 'Настройки экономики не найдены. Выплата по аукциону отменена.';
    end if;
    perform public.scrl_notify(v_a.leader_id,'Ты выиграл аукцион «'||left(v_a.title,80)||'».');
  end if;
  update public.auctions set status='done',closed_at=now() where id=p_auction;
  perform public.scrl_notify(v_a.owner_id,'Аукцион «'||left(v_a.title,80)||'» завершён.');
end;
$$;

COMMIT;
