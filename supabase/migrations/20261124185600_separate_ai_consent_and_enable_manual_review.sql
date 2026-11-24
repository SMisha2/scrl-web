-- Separate necessary account/data processing from optional external AI processing.
-- When AI consent is absent or the provider is disabled, eligible text submissions
-- are stored in the existing manual-review workflow instead of failing open.
BEGIN;

ALTER TABLE private.scrl_user_safety
  ALTER COLUMN ai_moderation_consent_at DROP NOT NULL,
  ALTER COLUMN ai_moderation_consent_version DROP NOT NULL;

ALTER TABLE private.scrl_user_consents
  ADD COLUMN IF NOT EXISTS revoked_at timestamptz;

CREATE OR REPLACE FUNCTION public.scrl_save_my_safety_data(
  p_birth_date date,
  p_personal_consent boolean,
  p_ai_consent boolean,
  p_personal_version text,
  p_ai_version text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, private, pg_temp
AS $function$
DECLARE
  v_existing private.scrl_user_safety%rowtype;
  v_exists boolean;
  v_age integer;
  v_now timestamptz := now();
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Требуется вход.';
  END IF;
  IF p_birth_date IS NULL
     OR p_birth_date > current_date
     OR p_birth_date < current_date - interval '120 years' THEN
    RAISE EXCEPTION 'Укажи корректную дату рождения.';
  END IF;
  IF p_personal_consent IS NOT TRUE THEN
    RAISE EXCEPTION 'Для использования ScRl необходимо принять политику обработки данных.';
  END IF;
  IF p_personal_version IS DISTINCT FROM '2026-11-17-v1' THEN
    RAISE EXCEPTION 'Текст политики данных обновился. Обнови страницу и проверь его ещё раз.';
  END IF;
  IF p_ai_consent IS TRUE AND p_ai_version IS DISTINCT FROM '2026-11-17-v2' THEN
    RAISE EXCEPTION 'Текст согласия на ИИ-обработку обновился. Обнови страницу и проверь его ещё раз.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Профиль не найден.';
  END IF;

  SELECT * INTO v_existing
  FROM private.scrl_user_safety
  WHERE user_id = auth.uid()
  FOR UPDATE;
  v_exists := FOUND;

  IF v_exists AND v_existing.birth_date IS DISTINCT FROM p_birth_date THEN
    RAISE EXCEPTION 'Дата рождения уже сохранена. Для её исправления обратись к администратору.';
  END IF;

  v_age := extract(year FROM age(current_date, p_birth_date))::integer;

  IF NOT v_exists THEN
    INSERT INTO private.scrl_user_safety (
      user_id, birth_date,
      personal_data_consent_at, personal_data_consent_version,
      ai_moderation_consent_at, ai_moderation_consent_version,
      parent_exchange_status
    ) VALUES (
      auth.uid(), p_birth_date,
      v_now, p_personal_version,
      CASE WHEN p_ai_consent IS TRUE THEN v_now ELSE NULL END,
      CASE WHEN p_ai_consent IS TRUE THEN p_ai_version ELSE NULL END,
      CASE WHEN v_age >= 18 THEN 'not_required' ELSE 'not_requested' END
    );
  ELSE
    UPDATE private.scrl_user_safety
    SET personal_data_consent_at = CASE
          WHEN personal_data_consent_version IS DISTINCT FROM p_personal_version THEN v_now
          ELSE personal_data_consent_at
        END,
        personal_data_consent_version = p_personal_version,
        ai_moderation_consent_at = CASE
          WHEN p_ai_consent IS TRUE THEN
            CASE
              WHEN ai_moderation_consent_version IS DISTINCT FROM p_ai_version
                   OR ai_moderation_consent_at IS NULL THEN v_now
              ELSE ai_moderation_consent_at
            END
          ELSE NULL
        END,
        ai_moderation_consent_version = CASE
          WHEN p_ai_consent IS TRUE THEN p_ai_version
          ELSE NULL
        END,
        parent_exchange_status = CASE
          WHEN v_age >= 18 THEN 'not_required'
          ELSE parent_exchange_status
        END,
        updated_at = v_now
    WHERE user_id = auth.uid();
  END IF;

  INSERT INTO private.scrl_user_consents(user_id, consent_type, policy_version, accepted_at, revoked_at)
  VALUES (auth.uid(), 'personal_data', p_personal_version, v_now, NULL)
  ON CONFLICT (user_id, consent_type, policy_version)
  DO UPDATE SET accepted_at = EXCLUDED.accepted_at, revoked_at = NULL;

  IF p_ai_consent IS TRUE THEN
    INSERT INTO private.scrl_user_consents(user_id, consent_type, policy_version, accepted_at, revoked_at)
    VALUES (auth.uid(), 'ai_moderation', p_ai_version, v_now, NULL)
    ON CONFLICT (user_id, consent_type, policy_version)
    DO UPDATE SET accepted_at = EXCLUDED.accepted_at, revoked_at = NULL;
  ELSE
    UPDATE private.scrl_user_consents
    SET revoked_at = coalesce(revoked_at, v_now)
    WHERE user_id = auth.uid()
      AND consent_type = 'ai_moderation'
      AND revoked_at IS NULL;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.scrl_get_my_safety_status()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, private, pg_temp
AS $function$
DECLARE
  v_row private.scrl_user_safety%rowtype;
  v_age integer;
  v_personal_ok boolean;
  v_ai_ok boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Требуется вход.';
  END IF;

  SELECT * INTO v_row
  FROM private.scrl_user_safety
  WHERE user_id = auth.uid();

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'birthDate', NULL,
      'ageYears', NULL,
      'hasPersonalDataConsent', false,
      'hasAiConsent', false,
      'personalDataConsentVersion', NULL,
      'aiConsentVersion', NULL,
      'parentExchangeStatus', 'not_requested',
      'canUseExchange', false,
      'needsOnboarding', true
    );
  END IF;

  v_age := extract(year FROM age(current_date, v_row.birth_date))::integer;
  v_personal_ok := v_row.personal_data_consent_at IS NOT NULL
    AND v_row.personal_data_consent_version = '2026-11-17-v1';
  v_ai_ok := v_row.ai_moderation_consent_at IS NOT NULL
    AND v_row.ai_moderation_consent_version = '2026-11-17-v2';

  RETURN jsonb_build_object(
    'birthDate', v_row.birth_date,
    'ageYears', v_age,
    'hasPersonalDataConsent', v_personal_ok,
    'hasAiConsent', v_ai_ok,
    'personalDataConsentVersion', v_row.personal_data_consent_version,
    'aiConsentVersion', v_row.ai_moderation_consent_version,
    'parentExchangeStatus', CASE
      WHEN v_age >= 18 THEN 'not_required'
      WHEN v_age < 14 THEN 'not_eligible'
      ELSE v_row.parent_exchange_status
    END,
    'canUseExchange', private.scrl_user_can_exchange(auth.uid()),
    'needsOnboarding', (v_row.birth_date IS NULL OR NOT v_personal_ok)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION private.scrl_user_can_exchange(p_user uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth, private, pg_temp
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles AS p
    LEFT JOIN private.scrl_user_safety AS s ON s.user_id = p.id
    WHERE p.id = p_user
      AND p.deleted_at IS NULL
      AND p.blocked = false
      AND (
        p.role = 'admin'
        OR (
          s.birth_date <= current_date
          AND s.personal_data_consent_at IS NOT NULL
          AND s.personal_data_consent_version = '2026-11-17-v1'
          AND (
            extract(year FROM age(current_date, s.birth_date)) >= 18
            OR (
              extract(year FROM age(current_date, s.birth_date)) >= 14
              AND s.parent_exchange_status = 'approved'
              AND s.parent_exchange_verified_at IS NOT NULL
              AND s.parent_exchange_verified_by IS NOT NULL
            )
          )
        )
      )
  );
$function$;

CREATE OR REPLACE FUNCTION public.scrl_request_exchange_parent_consent(p_parent_confirmed boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, private, pg_temp
AS $function$
DECLARE
  v_row private.scrl_user_safety%rowtype;
  v_age integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Требуется вход.';
  END IF;
  IF p_parent_confirmed IS NOT TRUE THEN
    RAISE EXCEPTION 'Подтверди, что законный представитель действительно дал согласие.';
  END IF;

  SELECT * INTO v_row
  FROM private.scrl_user_safety
  WHERE user_id = auth.uid()
  FOR UPDATE;

  IF NOT FOUND
     OR v_row.personal_data_consent_at IS NULL
     OR v_row.personal_data_consent_version <> '2026-11-17-v1' THEN
    RAISE EXCEPTION 'Сначала прими актуальную политику обработки данных.';
  END IF;

  v_age := extract(year FROM age(current_date, v_row.birth_date))::integer;
  IF v_age < 14 THEN
    RAISE EXCEPTION 'Биржа доступна только с 14 лет.';
  END IF;
  IF v_age >= 18 THEN
    RAISE EXCEPTION 'Для совершеннолетнего пользователя родительское согласие не требуется.';
  END IF;
  IF v_row.parent_exchange_status = 'approved' THEN
    RAISE EXCEPTION 'Доступ к бирже уже подтверждён.';
  END IF;
  IF v_row.parent_exchange_status = 'pending' THEN
    RAISE EXCEPTION 'Заявка уже отправлена и ожидает проверки администратора.';
  END IF;

  UPDATE private.scrl_user_safety
  SET parent_exchange_status = 'pending',
      parent_exchange_requested_at = now(),
      parent_exchange_verified_at = NULL,
      parent_exchange_verified_by = NULL,
      updated_at = now()
  WHERE user_id = auth.uid();

  INSERT INTO public.audit(actor_id, message)
  VALUES (auth.uid(), 'Отправлена заявка на проверку родительского согласия для биржи.');
END;
$function$;

CREATE OR REPLACE FUNCTION private.scrl_require_user_consents()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, private, pg_temp
AS $function$
DECLARE
  v_user uuid;
  v_role text := coalesce(current_setting('request.jwt.claim.role', true), '');
BEGIN
  IF v_role = 'service_role' THEN
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'profiles' THEN
    v_user := NEW.id;
    IF auth.uid() IS DISTINCT FROM v_user THEN
      RETURN NEW;
    END IF;
  ELSIF TG_TABLE_NAME IN ('posts', 'listings', 'auctions') THEN
    v_user := NEW.owner_id;
  ELSIF TG_TABLE_NAME IN ('deal_messages', 'reviews') THEN
    v_user := NEW.user_id;
  ELSIF TG_TABLE_NAME = 'reports' THEN
    v_user := NEW.reporter_id;
  ELSE
    RETURN NEW;
  END IF;

  IF v_user IS NULL OR NOT EXISTS (
    SELECT 1
    FROM private.scrl_user_safety AS s
    WHERE s.user_id = v_user
      AND s.personal_data_consent_at IS NOT NULL
      AND s.personal_data_consent_version = '2026-11-17-v1'
  ) THEN
    RAISE EXCEPTION 'Сначала прими актуальную политику обработки персональных данных.';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.scrl_save_my_safety_data(date, boolean, boolean, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.scrl_get_my_safety_status() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.scrl_request_exchange_parent_consent(boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION private.scrl_user_can_exchange(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION private.scrl_require_user_consents() FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.scrl_save_my_safety_data(date, boolean, boolean, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.scrl_get_my_safety_status() TO authenticated;
GRANT EXECUTE ON FUNCTION public.scrl_request_exchange_parent_consent(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION private.scrl_user_can_exchange(uuid) TO authenticated;

COMMIT;
