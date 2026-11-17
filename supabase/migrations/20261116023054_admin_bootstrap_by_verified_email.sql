-- Only the designated, email-confirmed account can claim the first admin role.
UPDATE private.scrl_admin_bootstrap
   SET target_email = lower('smisha214@gmail.com'),
       code_hash = NULL, code_once = NULL, claimed_at = NULL
 WHERE singleton = true;
CREATE OR REPLACE FUNCTION public.scrl_claim_initial_admin_for_email()
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'auth', 'private', 'pg_temp'
AS $function$
DECLARE v_target_email text; v_user_email text; v_email_confirmed_at timestamptz;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Требуется вход.'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('scrl_initial_admin'));
  IF EXISTS (SELECT 1 FROM public.profiles WHERE role = 'admin') THEN RETURN false; END IF;
  SELECT target_email INTO v_target_email
    FROM private.scrl_admin_bootstrap WHERE singleton = true FOR UPDATE;
  SELECT lower(email), email_confirmed_at INTO v_user_email, v_email_confirmed_at
    FROM auth.users WHERE id = auth.uid();
  IF v_target_email IS NULL OR v_user_email IS NULL OR v_user_email <> lower(v_target_email)
     OR v_email_confirmed_at IS NULL THEN RETURN false; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND NOT blocked) THEN RETURN false; END IF;
  UPDATE public.profiles SET role = 'admin', updated_at = now() WHERE id = auth.uid();
  UPDATE private.scrl_admin_bootstrap SET code_hash = NULL, code_once = NULL, claimed_at = now()
   WHERE singleton = true;
  INSERT INTO public.audit(actor_id, message)
    VALUES (auth.uid(), 'Первый администратор назначен после подтверждения целевой почты.');
  RETURN true;
END;
$function$;
REVOKE ALL ON FUNCTION public.scrl_claim_initial_admin(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.scrl_claim_initial_admin_for_email() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.scrl_claim_initial_admin_for_email() TO authenticated;
