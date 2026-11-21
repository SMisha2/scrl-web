-- Notification actions must always be scoped to the authenticated user.
-- Keeps the old read RPC compatible while fixing the shared read/clear endpoint.
BEGIN;

CREATE OR REPLACE FUNCTION public.scrl_manage_my_notifications(p_action text)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $function$
DECLARE
  v_action text := lower(btrim(coalesce(p_action, '')));
  v_affected integer := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Требуется вход.';
  END IF;

  IF v_action IN ('read', 'mark_read', 'mark_all_read', 'read_all') THEN
    UPDATE public.notifications
    SET seen = true
    WHERE user_id = auth.uid()
      AND seen IS DISTINCT FROM true;
    GET DIAGNOSTICS v_affected = ROW_COUNT;
  ELSIF v_action IN ('clear', 'delete', 'clear_all', 'delete_all') THEN
    DELETE FROM public.notifications
    WHERE user_id = auth.uid();
    GET DIAGNOSTICS v_affected = ROW_COUNT;
  ELSE
    RAISE EXCEPTION 'Неизвестное действие с уведомлениями.';
  END IF;

  RETURN v_affected;
END;
$function$;

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
