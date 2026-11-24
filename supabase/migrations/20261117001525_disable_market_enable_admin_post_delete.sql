-- Retire the student service marketplace without deleting its old records.
-- Preserve rows for historical reference, but remove the public API surface.
UPDATE public.listings
SET status = 'closed'
WHERE status IN ('active', 'review');

REVOKE ALL ON TABLE public.listings FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.scrl_create_listing(text, text, text, numeric, integer)
  FROM PUBLIC, anon, authenticated;

-- The shared publication closing RPC remains available only for board posts.
CREATE OR REPLACE FUNCTION public.scrl_close_publication(p_kind text, p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
BEGIN
  IF p_kind <> 'post' THEN
    RAISE EXCEPTION 'Этот тип публикации больше не поддерживается.';
  END IF;

  UPDATE public.posts
  SET status = 'closed'
  WHERE id = p_id AND owner_id = auth.uid() AND status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Публикация не найдена или уже закрыта.';
  END IF;
END;
$function$;

-- Prevent callers from creating new marketplace orders through the SECURITY DEFINER RPC.
CREATE OR REPLACE FUNCTION public.scrl_create_deal(
  p_title text,
  p_buyer uuid,
  p_seller uuid,
  p_amount numeric,
  p_source text DEFAULT ''::text,
  p_source_id text DEFAULT ''::text
)
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
  IF p_amount < 0 OR p_amount > 500 THEN RAISE EXCEPTION 'Некорректная сумма.'; END IF;
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

-- Admin deletion is server-only. The Edge Function verifies the user's JWT
-- and admin role, and this RPC independently re-checks the active admin profile.
CREATE OR REPLACE FUNCTION public.scrl_admin_delete_post(p_actor uuid, p_post uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_post public.posts%rowtype;
BEGIN
  IF coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' THEN
    RAISE EXCEPTION 'Недостаточно прав для удаления публикации.';
  END IF;
  IF p_actor IS NULL OR p_post IS NULL THEN
    RAISE EXCEPTION 'Не удалось определить администратора или публикацию.';
  END IF;

  PERFORM 1
  FROM public.profiles
  WHERE id = p_actor AND role = 'admin' AND blocked = false AND deleted_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Действующий администратор не найден.'; END IF;

  SELECT * INTO v_post
  FROM public.posts
  WHERE id = p_post
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Публикация не найдена.'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.deals
    WHERE source = 'board'
      AND source_id = p_post::text
      AND status IN ('work', 'ready', 'dispute')
  ) THEN
    RAISE EXCEPTION 'Нельзя удалить публикацию, пока по ней есть активная сделка.';
  END IF;

  DELETE FROM public.favorites WHERE kind = 'post' AND target_id = p_post::text;
  DELETE FROM public.reports WHERE kind = 'post' AND target_id = p_post::text;
  DELETE FROM public.posts WHERE id = p_post;
  IF NOT FOUND THEN RAISE EXCEPTION 'Не удалось удалить публикацию.'; END IF;

  INSERT INTO public.audit(actor_id, message)
  VALUES(p_actor, 'Администратор удалил публикацию «' || left(v_post.title, 100) || '».');
END;
$function$;

REVOKE ALL ON FUNCTION public.scrl_admin_delete_post(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.scrl_admin_delete_post(uuid, uuid) TO service_role;
