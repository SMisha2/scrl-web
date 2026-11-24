-- Make moderator decisions atomic. Lock queue records so two administrators
-- cannot apply conflicting outcomes to the same case or appeal.
BEGIN;

CREATE OR REPLACE FUNCTION public.scrl_moderation_admin_resolve_case(
  p_admin uuid,
  p_case_id uuid,
  p_decision text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $function$
DECLARE
  v_case public.scrl_moderation_cases%rowtype;
  v_ban public.scrl_moderation_bans%rowtype;
  v_rows integer;
  v_other uuid;
  v_title text;
  v_now timestamptz := now();
BEGIN
  IF coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' THEN
    RAISE EXCEPTION 'Недостаточно прав для решения модерации.';
  END IF;
  IF p_decision NOT IN ('restore', 'keep_hidden') THEN
    RAISE EXCEPTION 'Неизвестное решение модерации.';
  END IF;

  PERFORM 1
  FROM public.profiles
  WHERE id = p_admin AND role = 'admin' AND blocked = false AND deleted_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Доступ только для действующего администратора.';
  END IF;

  SELECT * INTO v_case
  FROM public.scrl_moderation_cases
  WHERE id = p_case_id
  FOR UPDATE;
  IF NOT FOUND OR v_case.status <> 'pending' THEN
    RAISE EXCEPTION 'Дело уже рассмотрено или не найдено.';
  END IF;

  IF v_case.source_id IS NOT NULL THEN
    IF v_case.source_table IN ('posts', 'listings', 'auctions', 'deal_messages', 'reviews') THEN
      IF v_case.source_table = 'posts' THEN
        UPDATE public.posts
        SET status = CASE WHEN p_decision = 'restore' THEN 'active' ELSE 'hidden' END
        WHERE id::text = v_case.source_id;
      ELSIF v_case.source_table = 'listings' THEN
        UPDATE public.listings
        SET status = CASE WHEN p_decision = 'restore' THEN 'active' ELSE 'hidden' END
        WHERE id::text = v_case.source_id;
      ELSIF v_case.source_table = 'auctions' THEN
        UPDATE public.auctions
        SET status = CASE WHEN p_decision = 'restore' THEN 'active' ELSE 'hidden' END
        WHERE id::text = v_case.source_id;
      ELSIF v_case.source_table = 'deal_messages' THEN
        UPDATE public.deal_messages
        SET status = CASE WHEN p_decision = 'restore' THEN 'active' ELSE 'hidden' END
        WHERE id::text = v_case.source_id;
      ELSE
        UPDATE public.reviews
        SET status = CASE WHEN p_decision = 'restore' THEN 'active' ELSE 'hidden' END
        WHERE id::text = v_case.source_id;
      END IF;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      IF v_rows = 0 THEN
        RAISE EXCEPTION 'Материал не найден. Дело не было закрыто.';
      END IF;
      IF v_case.source_table = 'deal_messages' AND p_decision = 'restore' THEN
        SELECT
          CASE WHEN m.user_id = d.buyer_id THEN d.seller_id ELSE d.buyer_id END,
          d.title
        INTO v_other, v_title
        FROM public.deal_messages AS m
        JOIN public.deals AS d ON d.id = m.deal_id
        WHERE m.id::text = v_case.source_id;
        IF v_other IS NOT NULL THEN
          INSERT INTO public.notifications(user_id, message)
          VALUES (v_other, 'Новое сообщение по сделке «' || left(coalesce(v_title, 'заказ'), 80) || '».');
        END IF;
      END IF;
    ELSIF v_case.source_table = 'reports' THEN
      UPDATE public.reports
      SET status = CASE WHEN p_decision = 'restore' THEN 'resolved' ELSE 'hidden' END
      WHERE id::text = v_case.source_id;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      IF v_rows = 0 THEN
        RAISE EXCEPTION 'Жалоба не найдена. Дело не было закрыто.';
      END IF;
    ELSIF v_case.source_table = 'profiles' AND p_decision = 'restore' THEN
      UPDATE public.profiles
      SET full_name = coalesce(
            v_case.evidence #>> '{original,full_name}',
            v_case.evidence ->> 'full_name',
            full_name
          ),
          updated_at = v_now
      WHERE id::text = v_case.source_id;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      IF v_rows = 0 THEN
        RAISE EXCEPTION 'Профиль не найден. Дело не было закрыто.';
      END IF;
    ELSIF v_case.source_table NOT IN ('profiles', 'ledger', 'prewrite') THEN
      RAISE EXCEPTION 'Для этого типа материала нет безопасного обработчика.';
    END IF;
  END IF;

  IF v_case.decision = 'ban' AND p_decision = 'restore' THEN
    SELECT * INTO v_ban
    FROM public.scrl_moderation_bans
    WHERE case_id = p_case_id AND active = true
    ORDER BY created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND OR v_ban.user_id IS NULL THEN
      RAISE EXCEPTION 'Активная блокировка для дела не найдена. Дело не было закрыто.';
    END IF;

    UPDATE public.scrl_moderation_bans
    SET active = false, lifted_at = v_now, lifted_by = p_admin
    WHERE case_id = p_case_id AND active = true;

    IF FOUND AND v_ban.user_id IS NOT NULL THEN
      UPDATE public.profiles AS p
      SET blocked = false, block_reason = '', updated_at = v_now
      WHERE p.id = v_case.user_id
        AND p.blocked = true
        AND p.block_reason = v_ban.reason
        AND NOT EXISTS (
          SELECT 1
          FROM public.scrl_moderation_bans AS other_ban
          WHERE other_ban.user_id = p.id AND other_ban.active = true
        );
    END IF;
  END IF;

  UPDATE public.scrl_moderation_cases
  SET status = 'resolved',
      resolution = CASE WHEN p_decision = 'restore' THEN 'restored' ELSE 'kept_hidden' END,
      reviewed_at = v_now,
      reviewed_by = p_admin
  WHERE id = p_case_id;

  INSERT INTO public.notifications(user_id, message)
  VALUES (
    v_case.user_id,
    CASE WHEN p_decision = 'restore'
      THEN 'Администратор проверил дело модерации и восстановил материал.'
      ELSE 'Администратор рассмотрел материал. Скрытие оставлено в силе.'
    END
  );

  INSERT INTO public.audit(actor_id, message)
  VALUES (p_admin, 'Рассмотрено дело модерации ' || p_case_id::text || ': ' || p_decision || '.');
END;
$function$;

CREATE OR REPLACE FUNCTION public.scrl_moderation_admin_resolve_appeal(
  p_admin uuid,
  p_appeal_id uuid,
  p_decision text,
  p_note text DEFAULT ''
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $function$
DECLARE
  v_appeal public.scrl_moderation_appeals%rowtype;
  v_ban public.scrl_moderation_bans%rowtype;
  v_now timestamptz := now();
BEGIN
  IF coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' THEN
    RAISE EXCEPTION 'Недостаточно прав для решения апелляции.';
  END IF;
  IF p_decision NOT IN ('accept', 'reject') THEN
    RAISE EXCEPTION 'Неизвестное решение по апелляции.';
  END IF;

  PERFORM 1
  FROM public.profiles
  WHERE id = p_admin AND role = 'admin' AND blocked = false AND deleted_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Доступ только для действующего администратора.';
  END IF;

  SELECT * INTO v_appeal
  FROM public.scrl_moderation_appeals
  WHERE id = p_appeal_id
  FOR UPDATE;
  IF NOT FOUND OR v_appeal.status <> 'pending' THEN
    RAISE EXCEPTION 'Апелляция уже рассмотрена или не найдена.';
  END IF;

  SELECT * INTO v_ban
  FROM public.scrl_moderation_bans
  WHERE id = v_appeal.ban_id
    AND user_id = v_appeal.user_id
  FOR UPDATE;
  IF NOT FOUND OR v_ban.active = false THEN
    RAISE EXCEPTION 'Активная блокировка для этой апелляции не найдена.';
  END IF;

  IF p_decision = 'accept' THEN
    UPDATE public.scrl_moderation_bans
    SET active = false, lifted_at = v_now, lifted_by = p_admin
    WHERE id = v_appeal.ban_id AND active = true;

    UPDATE public.profiles AS p
    SET blocked = false, block_reason = '', updated_at = v_now
    WHERE p.id = v_appeal.user_id
      AND p.blocked = true
      AND p.block_reason = v_ban.reason
      AND NOT EXISTS (
        SELECT 1
        FROM public.scrl_moderation_bans AS other_ban
        WHERE other_ban.user_id = p.id AND other_ban.active = true
      );
  END IF;

  UPDATE public.scrl_moderation_appeals
  SET status = CASE WHEN p_decision = 'accept' THEN 'accepted' ELSE 'rejected' END,
      decision_note = left(btrim(coalesce(p_note, '')), 500),
      reviewed_at = v_now,
      reviewed_by = p_admin
  WHERE id = p_appeal_id;

  INSERT INTO public.notifications(user_id, message)
  VALUES (
    v_appeal.user_id,
    CASE WHEN p_decision = 'accept'
      THEN 'Апелляция удовлетворена. Блокировка снята, если нет других действующих ограничений.'
      ELSE 'Апелляция отклонена. Блокировка остаётся активной.'
    END
  );

  INSERT INTO public.audit(actor_id, message)
  VALUES (p_admin, 'Рассмотрена апелляция ' || p_appeal_id::text || ': ' || p_decision || '.');
END;
$function$;

REVOKE ALL ON FUNCTION public.scrl_moderation_admin_resolve_case(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.scrl_moderation_admin_resolve_appeal(uuid, uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.scrl_moderation_admin_resolve_case(uuid, uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.scrl_moderation_admin_resolve_appeal(uuid, uuid, text, text) TO service_role;

COMMIT;
