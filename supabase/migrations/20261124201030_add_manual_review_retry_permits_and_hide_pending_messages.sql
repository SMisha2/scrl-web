-- Let a user retry a pre-write action only after an administrator explicitly approves it.
-- A short-lived one-use ticket is consumed by the existing moderation trigger on the next write.
-- Pending messages are visible to the author and moderators, but not to the recipient.

BEGIN;

DROP POLICY IF EXISTS messages_read_participants ON public.deal_messages;
CREATE POLICY messages_read_participants ON public.deal_messages
  FOR SELECT TO authenticated
  USING (
    user_id = (SELECT auth.uid())
    OR public.scrl_is_admin()
    OR (
      status = 'active'
      AND EXISTS (
        SELECT 1
        FROM public.deals AS d
        WHERE d.id = deal_id
          AND (d.buyer_id = (SELECT auth.uid()) OR d.seller_id = (SELECT auth.uid()))
      )
    )
  );

CREATE OR REPLACE FUNCTION public.scrl_moderation_admin_resolve_prewrite_case(
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
  v_payload jsonb;
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
  WHERE id = p_admin
    AND role = 'admin'
    AND blocked = false
    AND deleted_at IS NULL
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
  IF v_case.source_id IS NOT NULL
     OR v_case.source_table <> 'prewrite' THEN
    RAISE EXCEPTION 'Дело уже связано с материалом. Используй обычное рассмотрение.';
  END IF;

  IF p_decision = 'restore' THEN
    IF v_case.decision = 'ban' THEN
      SELECT * INTO v_ban
      FROM public.scrl_moderation_bans
      WHERE case_id = v_case.id
        AND user_id = v_case.user_id
        AND active = true
      ORDER BY created_at DESC
      LIMIT 1
      FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Активная блокировка для дела не найдена.';
      END IF;

      UPDATE public.scrl_moderation_bans
      SET active = false, lifted_at = v_now, lifted_by = p_admin
      WHERE case_id = v_case.id
        AND user_id = v_case.user_id
        AND active = true;

      UPDATE public.scrl_moderation_appeals
      SET status = 'accepted',
          decision_note = 'Дело восстановлено администратором.',
          reviewed_at = v_now,
          reviewed_by = p_admin
      WHERE ban_id = v_ban.id
        AND user_id = v_case.user_id
        AND status = 'pending';

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

    v_payload := v_case.evidence -> 'original';
    IF jsonb_typeof(v_payload) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'Не удалось восстановить исходные данные для повторной отправки.';
    END IF;

    INSERT INTO public.scrl_moderation_tickets(
      user_id, kind, payload, decision, severity, confidence,
      categories, reason, case_id, expires_at
    )
    VALUES (
      v_case.user_id,
      v_case.kind,
      v_payload,
      'allow',
      'none',
      1,
      ARRAY['manual_approved']::text[],
      'Материал одобрен администратором; разрешена одна повторная отправка.',
      v_case.id,
      v_now + interval '30 minutes'
    );

    UPDATE public.scrl_moderation_cases
    SET status = 'resolved',
        resolution = 'manual_approved_retry',
        reviewed_at = v_now,
        reviewed_by = p_admin
    WHERE id = v_case.id;

    INSERT INTO public.notifications(user_id, message)
    VALUES (
      v_case.user_id,
      'Администратор одобрил материал. Повтори действие в ScRl в течение 30 минут: разрешение действует для одной отправки.'
    );
  ELSE
    UPDATE public.scrl_moderation_cases
    SET status = 'resolved',
        resolution = 'kept_hidden',
        reviewed_at = v_now,
        reviewed_by = p_admin
    WHERE id = v_case.id;

    INSERT INTO public.notifications(user_id, message)
    VALUES (
      v_case.user_id,
      'Администратор рассмотрел материал. Решение о запрете публикации оставлено в силе.'
    );
  END IF;

  INSERT INTO public.audit(actor_id, message)
  VALUES (
    p_admin,
    'Рассмотрено предварительное дело модерации ' || v_case.id::text || ': ' || p_decision || '.'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.scrl_moderation_admin_resolve_prewrite_case(uuid, uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.scrl_moderation_admin_resolve_prewrite_case(uuid, uuid, text)
  TO service_role;

COMMIT;
