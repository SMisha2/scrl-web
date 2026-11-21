-- Match the server-side exchange gate to the admin access already provided by the UI.
-- Active administrators may operate the school-token exchange without the participant parent-consent gate.
-- Blocked and deleted administrators remain denied.
BEGIN;

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
    LEFT JOIN private.scrl_user_safety AS s
      ON s.user_id = p.id
    WHERE p.id = p_user
      AND p.deleted_at IS NULL
      AND p.blocked = false
      AND (
        p.role = 'admin'
        OR (
          s.birth_date <= current_date
          AND s.personal_data_consent_at IS NOT NULL
          AND s.personal_data_consent_version = '2026-11-17-v1'
          AND s.ai_moderation_consent_at IS NOT NULL
          AND s.ai_moderation_consent_version = '2026-11-17-v2'
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

REVOKE ALL ON FUNCTION private.scrl_user_can_exchange(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.scrl_user_can_exchange(uuid) TO authenticated;

COMMIT;
