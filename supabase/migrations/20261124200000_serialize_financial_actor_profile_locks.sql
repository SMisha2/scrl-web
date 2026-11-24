-- Lock participant profiles before wallet/order operations so a concurrent
-- admin block or automatic ban cannot race with new financial activity.
-- All participant profile locks use ascending UUID order.
BEGIN;

create or replace function public.scrl_create_deal(
  p_title text, p_buyer uuid, p_seller uuid, p_amount numeric, p_source text default '', p_source_id text default ''
)
returns uuid
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_id uuid;
  v_buyer public.wallets%rowtype;
  v_post public.posts%rowtype;
  v_listing public.listings%rowtype;
  v_locked_profiles integer;
begin
  if auth.uid() is null then raise exception 'Требуется вход.'; end if;
  if length(trim(coalesce(p_title,''))) = 0 or length(p_title) > 120 then raise exception 'Некорректное название сделки.'; end if;
  if p_amount < 0 or p_amount > 500 then raise exception 'Некорректная сумма.'; end if;
  if p_buyer is null or p_seller is null or p_buyer = p_seller then
    raise exception 'Некорректные участники сделки.';
  end if;
  if p_amount is null or p_amount::text = 'NaN' or p_amount < 0 or p_amount > 500 then
    raise exception 'Некорректная сумма.';
  end if;

  -- Match admin blocking and automatic moderation: profile rows are locked
  -- in stable UUID order before publications, wallets or financial rows.
  PERFORM p.id
  FROM public.profiles AS p
  WHERE p.id IN (p_buyer, p_seller)
  ORDER BY p.id
  FOR UPDATE;
  GET DIAGNOSTICS v_locked_profiles = ROW_COUNT;
  IF v_locked_profiles <> 2 THEN
    RAISE EXCEPTION 'Один из участников не найден.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id IN (p_buyer, p_seller)
      AND (blocked = true OR deleted_at IS NOT NULL)
  ) THEN
    RAISE EXCEPTION 'Один из участников заблокирован или удалён.';
  END IF;

  if p_source = 'market' then
    select * into v_listing from public.listings where id::text = p_source_id and status='active' for update;
    if not found or v_listing.owner_id <> p_seller or p_buyer <> auth.uid() then raise exception 'Услуга больше недоступна.'; end if;
    if v_listing.slots < 1 then raise exception 'Свободные места закончились.'; end if;
    update public.listings set slots=slots-1, status=case when slots-1 <= 0 then 'sold' else status end where id=v_listing.id;
  elsif p_source = 'board' then
    select * into v_post from public.posts where id::text = p_source_id and status='active' for update;
    if not found then raise exception 'Публикация больше недоступна.'; end if;
    if v_post.type='need' and not (p_buyer=v_post.owner_id and p_seller=auth.uid()) then raise exception 'Неверные участники отклика.'; end if;
    if v_post.type='offer' and not (p_seller=v_post.owner_id and p_buyer=auth.uid()) then raise exception 'Неверные участники отклика.'; end if;
  else
    raise exception 'Неизвестный источник сделки.';
  end if;

  select * into v_buyer from public.wallets where user_id=p_buyer for update;
  if not found or v_buyer.scrl < p_amount then raise exception 'Недостаточно ScRl для резерва.'; end if;
  update public.wallets set scrl=scrl-p_amount, hold_scrl=hold_scrl+p_amount, updated_at=now() where user_id=p_buyer;
  insert into public.ledger(user_id,currency,delta,note,actor_id)
    values(p_buyer,'ScRl',-p_amount,'Резерв по сделке: '||left(p_title,100),auth.uid());
  insert into public.deals(title,buyer_id,seller_id,amount,escrow,source,source_id)
    values(left(trim(p_title),120),p_buyer,p_seller,p_amount,p_amount,p_source,p_source_id)
    returning id into v_id;
  perform public.scrl_notify(p_buyer,'Создана сделка: '||left(p_title,100));
  perform public.scrl_notify(p_seller,'Тебе поступил заказ: '||left(p_title,100));
  perform public.scrl_log(auth.uid(),'Создана сделка «'||left(p_title,100)||'».');
  return v_id;
end;
$$;

create or replace function public.scrl_teacher_issue(p_student uuid,p_amount integer,p_reason text)
returns void
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare v_teacher public.profiles%rowtype; v_student public.profiles%rowtype; v_week date; v_used integer; v_locked_profiles integer; v_rows integer;
begin
  if auth.uid() is null or p_student is null or p_student = auth.uid() then
    raise exception 'Некорректный ученик.';
  end if;

  PERFORM p.id
  FROM public.profiles AS p
  WHERE p.id IN (auth.uid(), p_student)
  ORDER BY p.id
  FOR UPDATE;
  GET DIAGNOSTICS v_locked_profiles = ROW_COUNT;
  IF v_locked_profiles <> 2 THEN
    RAISE EXCEPTION 'Учитель или ученик не найден.';
  END IF;

  SELECT * INTO v_teacher FROM public.profiles WHERE id = auth.uid();
  SELECT * INTO v_student FROM public.profiles WHERE id = p_student;

  IF v_teacher.blocked OR v_teacher.deleted_at IS NOT NULL
     OR v_teacher.role NOT IN ('teacher', 'admin') THEN
    RAISE EXCEPTION 'Нет доступа.';
  END IF;
  IF v_student.blocked OR v_student.deleted_at IS NOT NULL
     OR v_student.role <> 'student' THEN
    RAISE EXCEPTION 'Выбери активного ученика.';
  END IF;
  if v_teacher.role='teacher' and v_student.room<>v_teacher.room then raise exception 'Можно начислять только ученикам своего класса.'; end if;
  if p_amount not between 1 and 500 then raise exception 'Сумма должна быть от 1 до 500 ScRl.'; end if;
  v_week := date_trunc('week',now())::date;
  insert into public.teacher_issuance(teacher_id,week_start,amount) values(auth.uid(),v_week,0) on conflict do nothing;
  select amount into v_used from public.teacher_issuance where teacher_id=auth.uid() and week_start=v_week for update;
  if v_used+p_amount>500 then raise exception 'Превышен недельный лимит 500 ScRl.'; end if;
  update public.teacher_issuance set amount=amount+p_amount where teacher_id=auth.uid() and week_start=v_week;
  update public.wallets set scrl=scrl+p_amount,updated_at=now() where user_id=p_student;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN RAISE EXCEPTION 'Кошелёк ученика не найден. Начисление отменено.'; END IF;
  insert into public.ledger(user_id,currency,delta,note,actor_id) values(p_student,'ScRl',p_amount,'Начисление: '||left(coalesce(p_reason,'Без комментария'),120),auth.uid());
  perform public.scrl_notify(p_student,'Тебе начислено '||p_amount||' ScRl.');
  insert into public.audit(actor_id,message) values(auth.uid(),'Начислено '||p_amount||' ScRl участнику '||p_student::text);
end;
$$;

create or replace function public.scrl_create_auction(p_title text,p_prize text,p_start numeric,p_step numeric,p_minutes integer)
returns uuid
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare v_id uuid; v_role text;
begin
  if auth.uid() is null then raise exception 'Требуется вход.'; end if;
  select role into v_role from public.profiles where id=auth.uid() and not blocked and deleted_at is null for update;
  if v_role not in ('teacher','admin') then raise exception 'Создавать аукционы могут учителя и администраторы.'; end if;
  if length(trim(p_title)) not between 1 and 100 or length(trim(p_prize)) not between 1 and 250 or p_start not between 1 and 1000000 or p_step not between 1 and 1000000 or p_minutes not between 1 and 10080 then
    raise exception 'Проверь данные аукциона.';
  end if;
  if p_prize ~* '(руб|рубл|деньг|денеж|налич|перевод|оплат|usd|eur|cash|dollar|банковск|[₽€$])' then raise exception 'Приз должен быть неденежным.'; end if;
  insert into public.auctions(title,prize,start_price,step,owner_id,ends_at)
    values(trim(p_title),trim(p_prize),p_start,p_step,auth.uid(),now()+make_interval(mins=>p_minutes)) returning id into v_id;
  perform public.scrl_log(auth.uid(),'Создан аукцион «'||left(p_title,100)||'».');
  return v_id;
end;
$$;

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

  -- Serialize order creation with administrative/automatic account blocking.
  PERFORM id
  FROM public.profiles
  WHERE id = auth.uid()
    AND blocked = false
    AND deleted_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Аккаунт заблокирован, удалён или не найден.';
  END IF;

  select * into v_wallet
  from public.wallets
  where user_id = auth.uid()
  for update;
  if not found then
    raise exception 'Кошелёк не найден. Обратись к администратору.';
  end if;

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
  v_seller_id uuid;
  v_locked_profiles integer;
begin
  if auth.uid() is null then
    raise exception 'Требуется вход.';
  end if;

  -- Read the seller ID without a lock, then lock both profiles before the
  -- order and wallets. This is the same lock order used by user blocking.
  select * into v_order
  from public.exchange_orders
  where id = p_order and status = 'active';

  if not found then
    raise exception 'Предложение уже недоступно.';
  end if;
  if v_order.owner_id = auth.uid() then
    raise exception 'Нельзя купить собственное предложение.';
  end if;
  v_seller_id := v_order.owner_id;

  PERFORM p.id
  FROM public.profiles AS p
  WHERE p.id IN (auth.uid(), v_seller_id)
  ORDER BY p.id
  FOR UPDATE;
  GET DIAGNOSTICS v_locked_profiles = ROW_COUNT;
  IF v_locked_profiles <> 2 THEN
    RAISE EXCEPTION 'Один из участников обмена не найден.';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.profiles
    WHERE id IN (auth.uid(), v_seller_id)
      AND (blocked = true OR deleted_at IS NOT NULL)
  ) THEN
    RAISE EXCEPTION 'Один из участников заблокирован или удалён.';
  END IF;

  select * into v_order
  from public.exchange_orders
  where id = p_order
    and owner_id = v_seller_id
    and status = 'active'
  for update;
  if not found then
    raise exception 'Предложение больше недоступно.';
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

COMMIT;
