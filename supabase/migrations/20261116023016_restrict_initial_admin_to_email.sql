-- Bind first-admin bootstrap to a designated email.
ALTER TABLE private.scrl_admin_bootstrap ADD COLUMN IF NOT EXISTS target_email text;
CREATE OR REPLACE FUNCTION public.scrl_claim_initial_admin(p_code text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'auth', 'private', 'pg_temp'
AS $function$
DECLARE v_hash text; v_target_email text; v_user_email text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Требуется вход.'; END IF;
  v_user_email := lower(coalesce(auth.jwt() ->> 'email', ''));
  PERFORM pg_advisory_xact_lock(hashtext('scrl_initial_admin'));
  IF EXISTS (SELECT 1 FROM public.profiles WHERE role = 'admin') THEN RETURN false; END IF;
  SELECT code_hash, target_email INTO v_hash, v_target_email
    FROM private.scrl_admin_bootstrap WHERE singleton = true FOR UPDATE;
  IF v_hash IS NULL OR v_target_email IS NULL OR v_user_email <> lower(v_target_email)
     OR p_code IS NULL OR length(p_code) > 128
     OR encode(digest(p_code, 'sha256'), 'hex') <> v_hash THEN RETURN false; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND NOT blocked) THEN RETURN false; END IF;
  UPDATE public.profiles SET role = 'admin', updated_at = now() WHERE id = auth.uid();
  UPDATE private.scrl_admin_bootstrap SET code_hash = NULL, code_once = NULL, claimed_at = now()
   WHERE singleton = true;
  INSERT INTO public.audit(actor_id, message) VALUES (auth.uid(), 'Первый администратор назначен через одноразовый код.');
  RETURN true;
END;
$function$;
