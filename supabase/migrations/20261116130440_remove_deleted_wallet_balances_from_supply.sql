-- A deleted user's remaining balance must leave active supply and fee calculations.
-- Preserve an anonymized ledger record and count removed ScRl as burned.
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
  IF coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' THEN
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
