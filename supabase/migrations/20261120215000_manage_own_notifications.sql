-- Allow each signed-in participant to mark or clear only their own notifications.
CREATE OR REPLACE FUNCTION public.scrl_manage_my_notifications(p_action text)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_affected integer := 0;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '28000';
  END IF;

  IF p_action = 'read' THEN
    UPDATE public.notifications
       SET seen = true
     WHERE user_id = v_user_id
       AND seen IS DISTINCT FROM true;
    GET DIAGNOSTICS v_affected = ROW_COUNT;
  ELSIF p_action = 'clear' THEN
    UPDATE public.notifications
       SET seen = true
     WHERE user_id = v_user_id
       AND seen IS DISTINCT FROM true;

    DELETE FROM public.notifications
     WHERE user_id = v_user_id;
    GET DIAGNOSTICS v_affected = ROW_COUNT;
  ELSE
    RAISE EXCEPTION 'Unsupported notification action';
  END IF;

  RETURN v_affected;
END;
$function$;

REVOKE ALL ON FUNCTION public.scrl_manage_my_notifications(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.scrl_manage_my_notifications(text) TO authenticated;
