BEGIN;

-- Board posts and escrowed deal amounts have no artificial 500 ScRl ceiling.
ALTER TABLE public.posts DROP CONSTRAINT IF EXISTS posts_price_check;
ALTER TABLE public.posts ADD CONSTRAINT posts_price_check CHECK (price IS NOT NULL AND price >= 0);
ALTER TABLE public.deals DROP CONSTRAINT IF EXISTS deals_amount_check;
ALTER TABLE public.deals ADD CONSTRAINT deals_amount_check CHECK (amount IS NOT NULL AND amount >= 0);

-- AI moderation ticket trigger changes the inserted active status to review/hidden when required.
CREATE OR REPLACE FUNCTION public.scrl_create_post(p_type text, p_title text, p_description text, p_category text, p_price numeric)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_id uuid;
  v_status text;
begin
  if auth.uid() is null then
    raise exception 'Требуется вход.';
  end if;
  if p_type not in ('need','offer')
    or length(trim(coalesce(p_title,''))) not between 1 and 100
    or length(trim(coalesce(p_description,''))) not between 1 and 1500
    or p_price is null or p_price < 0 then
    raise exception 'Проверь заголовок, описание и цену.';
  end if;
  if exists(select 1 from public.profiles where id=auth.uid() and blocked) then
    raise exception 'Аккаунт заблокирован.';
  end if;

  -- The moderation guard consumes the AI ticket and sets review/hidden when needed.
  v_status := 'active';
  insert into public.posts(type,title,description,category,price,owner_id,status)
    values(p_type,trim(p_title),trim(p_description),coalesce(nullif(trim(p_category),''),'Другое'),p_price,auth.uid(),v_status)
    returning id into v_id;

  perform public.scrl_log(auth.uid(),'Создана публикация «'||left(p_title,100)||'».');
  return v_id;
end;
$function$;

-- An unrestricted board price remains valid when a buyer responds to a publication.
CREATE OR REPLACE FUNCTION public.scrl_create_deal(p_title text, p_buyer uuid, p_seller uuid, p_amount numeric, p_source text DEFAULT ''::text, p_source_id text DEFAULT ''::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_id uuid;
  v_buyer public.wallets%rowtype;
  v_post public.posts%rowtype;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Требуется вход.'; END IF;
  IF p_source <> 'board' THEN RAISE EXCEPTION 'Маркет услуг отключён. Сделки создаются только по публикациям доски.'; END IF;
  IF length(trim(coalesce(p_title,''))) = 0 OR length(p_title) > 120 THEN RAISE EXCEPTION 'Некорректное название сделки.'; END IF;
  IF p_amount IS NULL OR p_amount < 0 THEN RAISE EXCEPTION 'Некорректная сумма.'; END IF;
  IF p_buyer = p_seller THEN RAISE EXCEPTION 'Нельзя создать сделку с самим собой.'; END IF;
  IF EXISTS(SELECT 1 FROM public.profiles WHERE id IN (p_buyer,p_seller) AND blocked) THEN RAISE EXCEPTION 'Аккаунт заблокирован.'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=p_buyer) OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=p_seller) THEN RAISE EXCEPTION 'Участник не найден.'; END IF;

  SELECT * INTO v_post
  FROM public.posts
  WHERE id::text = p_source_id AND status = 'active'
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Публикация больше недоступна.'; END IF;
  IF p_amount <> v_post.price THEN RAISE EXCEPTION 'Цена публикации изменилась. Обнови страницу.'; END IF;
  IF v_post.type = 'need' AND NOT (p_buyer = v_post.owner_id AND p_seller = auth.uid()) THEN
    RAISE EXCEPTION 'Неверные участники отклика.';
  END IF;
  IF v_post.type = 'offer' AND NOT (p_seller = v_post.owner_id AND p_buyer = auth.uid()) THEN
    RAISE EXCEPTION 'Неверные участники отклика.';
  END IF;

  SELECT * INTO v_buyer FROM public.wallets WHERE user_id = p_buyer FOR UPDATE;
  IF NOT FOUND OR v_buyer.scrl < p_amount THEN RAISE EXCEPTION 'Недостаточно ScRl для резерва.'; END IF;

  UPDATE public.wallets
  SET scrl = scrl - p_amount, hold_scrl = hold_scrl + p_amount, updated_at = now()
  WHERE user_id = p_buyer;

  INSERT INTO public.ledger(user_id,currency,delta,note,actor_id)
    VALUES(p_buyer,'ScRl',-p_amount,'Резерв по сделке: '||left(p_title,100),auth.uid());

  INSERT INTO public.deals(title,buyer_id,seller_id,amount,escrow,source,source_id)
    VALUES(left(trim(p_title),120),p_buyer,p_seller,p_amount,p_amount,'board',p_source_id)
    RETURNING id INTO v_id;

  PERFORM public.scrl_notify(p_buyer,'Создана сделка: '||left(p_title,100));
  PERFORM public.scrl_notify(p_seller,'Тебе поступил заказ: '||left(p_title,100));
  PERFORM public.scrl_log(auth.uid(),'Создана сделка «'||left(p_title,100)||'».');
  RETURN v_id;
END;
$function$;

-- An authenticated active administrator can call this cleanup RPC; service_role is retained for self-deletion.
-- The last active administrator and financial holds/active operations remain protected.
CREATE OR REPLACE FUNCTION public.scrl_delete_account(p_user uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_profile public.profiles%rowtype;
  v_wallet public.wallets%rowtype;
BEGIN
  IF coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' AND NOT public.scrl_is_admin() THEN
    RAISE EXCEPTION 'Недостаточно прав для удаления аккаунта.';
  END IF;
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'Не удалось определить аккаунт.';
  END IF;

  SELECT * INTO v_profile
  FROM public.profiles
  WHERE id = p_user
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Профиль не найден.';
  END IF;
  IF v_profile.deleted_at IS NOT NULL THEN
    RETURN;
  END IF;

  IF v_profile.role = 'admin' AND NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE role = 'admin'
      AND blocked = false
      AND deleted_at IS NULL
      AND id <> p_user
  ) THEN
    RAISE EXCEPTION 'Сначала назначь другого администратора, затем можно удалить этот аккаунт.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.deals
    WHERE (buyer_id = p_user OR seller_id = p_user)
      AND status IN ('work', 'ready', 'dispute')
  ) THEN
    RAISE EXCEPTION 'Перед удалением заверши или урегулируй активные сделки.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.exchange_orders
    WHERE owner_id = p_user AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'Перед удалением отмени активные заявки на бирже.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.auctions
    WHERE status IN ('active', 'settlementError')
      AND (owner_id = p_user OR leader_id = p_user)
  ) THEN
    RAISE EXCEPTION 'Перед удалением дождись завершения активных аукционов.';
  END IF;

  SELECT * INTO v_wallet
  FROM public.wallets
  WHERE user_id = p_user
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Кошелёк аккаунта не найден. Обратись к администратору.';
  END IF;

  IF v_wallet.hold_scrl > 0 OR v_wallet.hold_vrub > 0 THEN
    RAISE EXCEPTION 'Сначала освободи все резервы ScRl и V-RUB.';
  END IF;

  -- Explicitly remove the unavailable balance from active supply.
  -- The following ledger anonymization preserves the accounting trail without PII.
  IF v_wallet.scrl > 0 THEN
    INSERT INTO public.ledger(user_id, currency, delta, note, actor_id)
    VALUES (p_user, 'ScRl', -v_wallet.scrl, 'Остаток ScRl списан при удалении аккаунта', p_user);

    UPDATE public.platform_settings
    SET burned_scrl = burned_scrl + v_wallet.scrl,
        updated_at = now()
    WHERE singleton = true;
  END IF;

  IF v_wallet.vrub > 0 THEN
    INSERT INTO public.ledger(user_id, currency, delta, note, actor_id)
    VALUES (p_user, 'V-RUB', -v_wallet.vrub, 'Остаток V-RUB списан при удалении аккаунта', p_user);
  END IF;

  UPDATE public.wallets
  SET scrl = 0,
      vrub = 0,
      hold_scrl = 0,
      hold_vrub = 0,
      updated_at = now()
  WHERE user_id = p_user;

  -- Remove user-authored personal content while preserving financial records.
  UPDATE public.posts
  SET title = 'Удалённая публикация',
      description = 'Содержимое удалено автором',
      category = 'Другое',
      status = 'hidden'
  WHERE owner_id = p_user;

  UPDATE public.listings
  SET title = 'Удалённая услуга',
      description = 'Содержимое удалено автором',
      category = 'Другое',
      status = 'hidden'
  WHERE owner_id = p_user;

  UPDATE public.deals
  SET title = 'Сделка удалённого участника'
  WHERE buyer_id = p_user OR seller_id = p_user;

  UPDATE public.auctions
  SET title = 'Аукцион удалённого участника',
      prize = 'Информация удалена'
  WHERE owner_id = p_user
    AND status NOT IN ('active', 'settlementError');

  DELETE FROM public.deal_messages WHERE user_id = p_user;
  DELETE FROM public.reviews WHERE user_id = p_user;
  DELETE FROM public.reports WHERE reporter_id = p_user;
  DELETE FROM public.favorites WHERE user_id = p_user;
  DELETE FROM public.notifications WHERE user_id = p_user;
  DELETE FROM public.activity WHERE user_id = p_user;
  DELETE FROM public.teacher_issuance WHERE teacher_id = p_user;
  DELETE FROM public.scrl_moderation_appeals WHERE user_id = p_user;
  DELETE FROM public.scrl_moderation_bans WHERE user_id = p_user;
  DELETE FROM public.scrl_moderation_cases WHERE user_id = p_user;
  DELETE FROM public.scrl_moderation_tickets WHERE user_id = p_user;

  -- Preserve the ledger but remove free-text notes that could contain PII.
  UPDATE public.ledger
  SET note = 'Операция удалённого участника'
  WHERE user_id = p_user
     OR actor_id = p_user;

  -- Retain a pseudonymous profile as the stable FK target for historical records.
  UPDATE public.profiles
  SET full_name = 'Удалённый участник',
      room = '',
      role = 'student',
      blocked = true,
      block_reason = 'Аккаунт удалён пользователем',
      deleted_at = now(),
      updated_at = now()
  WHERE id = p_user;
END;
$function$;
REVOKE ALL ON FUNCTION public.scrl_delete_account(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.scrl_delete_account(uuid) TO authenticated, service_role;

COMMIT;
