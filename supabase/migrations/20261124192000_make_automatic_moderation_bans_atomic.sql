-- Create the moderation ban, block the user, notify them and write audit in one transaction.
-- Serialize attempts for the same moderation case so retries cannot issue duplicate bans.
BEGIN;

CREATE OR REPLACE FUNCTION public.scrl_moderation_issue_automatic_ban(
  p_user uuid,
  p_case_id uuid,
  p_reason text,
  p_appeal_until timestamptz
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $function$
DECLARE
  v_case public.scrl_moderation_cases%rowtype;
  v_ban_id uuid;
  v_reason text := left(btrim(coalesce(p_reason, 'Критическое нарушение правил')), 240);
  v_now timestamptz := now();
BEGIN
  IF coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' THEN
    RAISE EXCEPTION 'Недостаточно прав для автоматической блокировки.';
  END IF;
  IF p_user IS NULL OR p_case_id IS NULL OR p_appeal_until IS NULL OR p_appeal_until <= v_now THEN
    RAISE EXCEPTION 'Некорректные параметры автоматической блокировки.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('scrl_moderation_ban:' || p_case_id::text));

  SELECT * INTO v_case
  FROM public.scrl_moderation_cases
  WHERE id = p_case_id
  FOR UPDATE;

  IF NOT FOUND
     OR v_case.user_id <> p_user
     OR v_case.status <> 'pending'
     OR v_case.decision <> 'ban'
     OR v_case.severity <> 'critical'
     OR v_case.confidence < 0.98
     OR NOT (v_case.categories && ARRAY[
       'credible_violent_threat',
       'sexual_exploitation_or_grooming',
       'doxxing_or_stalking',
       'serious_real_world_violence'
     ]::text[]) THEN
    RAISE EXCEPTION 'Дело не соответствует условиям автоматической блокировки.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.scrl_moderation_bans
    WHERE case_id = p_case_id
  ) THEN
    RAISE EXCEPTION 'Для этого дела блокировка уже создана.';
  END IF;

  PERFORM 1
  FROM public.profiles
  WHERE id = p_user
    AND blocked = false
    AND deleted_at IS NULL
    AND role <> 'admin'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Профиль не найден, уже заблокирован или имеет административную роль.';
  END IF;

  INSERT INTO public.scrl_moderation_bans(
    user_id, case_id, reason, active, appeal_until
  )
  VALUES (
    p_user, p_case_id, v_reason, true, p_appeal_until
  )
  RETURNING id INTO v_ban_id;

  UPDATE public.profiles
  SET blocked = true,
      block_reason = left(v_reason, 180),
      updated_at = v_now
  WHERE id = p_user
    AND blocked = false
    AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Профиль изменился во время блокировки. Транзакция отменена.';
  END IF;

  INSERT INTO public.notifications(user_id, message)
  VALUES (
    p_user,
    'Аккаунт заблокирован ИИ-модерацией. Причина: ' || left(v_reason, 140) ||
    '. Апелляцию можно подать в течение 24 часов.'
  );

  INSERT INTO public.audit(actor_id, message)
  VALUES (
    p_user,
    'Система создала временную блокировку по критическому делу модерации ' || p_case_id::text || '.'
  );

  RETURN v_ban_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.scrl_moderation_issue_automatic_ban(uuid, uuid, text, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.scrl_moderation_issue_automatic_ban(uuid, uuid, text, timestamptz) TO service_role;

COMMIT;
