-- Provide the notification-read RPC used by the current frontend.
-- Keep the operation scoped to auth.uid(); clients cannot mark another user's
-- notifications as read, even when this SECURITY DEFINER function is called.
BEGIN;

CREATE OR REPLACE FUNCTION public.scrl_mark_notifications_read()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Требуется вход.';
  END IF;

  UPDATE public.notifications
  SET seen = true
  WHERE user_id = auth.uid()
    AND seen IS DISTINCT FROM true;
END;
$function$;

REVOKE ALL ON FUNCTION public.scrl_mark_notifications_read() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.scrl_mark_notifications_read() TO authenticated;

COMMIT;
