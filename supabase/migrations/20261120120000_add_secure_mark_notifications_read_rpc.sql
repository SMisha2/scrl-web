-- Notification actions must always be scoped to the authenticated user.
-- This also restores the p_action RPC name used by older deployed frontend builds.
BEGIN;

CREATE OR REPLACE FUNCTION public.scrl_manage_my_notifications(p_action text)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $function$
DECLARE
  v_affected integer := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Требуется вход.';
  END IF;

  CASE lower(coalesce(p_action, ''))
    WHEN 'read' THEN
      UPDATE public.notifications
      SET seen = true
      WHERE user_id = auth.uid()
        AND seen IS DISTINCT FROM true;
      GET DIAGNOSTICS v_affected = ROW_COUNT;
    WHEN 'clear' THEN
      DELETE FROM public.notifications
      WHERE user_id = auth.uid();
      GET DIAGNOSTICS v_affected = ROW_COUNT;
    ELSE
      RAISE EXCEPTION 'Неизвестное действие с уведомлениями.';
  END CASE;

  RETURN v_affected;
END;
$function$;

-- Keep the newer no-argument endpoint compatible with clients that already use it.
CREATE OR REPLACE FUNCTION public.scrl_mark_notifications_read()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $function$
BEGIN
  PERFORM public.scrl_manage_my_notifications('read');
END;
$function$;

REVOKE ALL ON FUNCTION public.scrl_manage_my_notifications(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.scrl_mark_notifications_read() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.scrl_manage_my_notifications(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.scrl_mark_notifications_read() TO authenticated;

COMMIT;
