CREATE OR REPLACE FUNCTION public.scrl_admin_unblock_user(p_target uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_user public.profiles%rowtype;
BEGIN
  IF NOT public.scrl_is_admin() THEN
    RAISE EXCEPTION 'Нет доступа.';
  END IF;

  SELECT *
  INTO v_user
  FROM public.profiles
  WHERE id = p_target
  FOR UPDATE;

  IF NOT FOUND
     OR v_user.deleted_at IS NOT NULL
     OR v_user.id = auth.uid()
     OR v_user.role = 'admin' THEN
    RAISE EXCEPTION 'Недопустимое действие.';
  END IF;

  -- Close pending appeals attached to active bans that the administrator is lifting.
  UPDATE public.scrl_moderation_appeals AS appeal
  SET status = 'accepted',
      decision_note = 'Блокировка снята администратором.',
      reviewed_at = now(),
      reviewed_by = auth.uid()
  WHERE appeal.status = 'pending'
    AND EXISTS (
      SELECT 1
      FROM public.scrl_moderation_bans AS ban
      WHERE ban.id = appeal.ban_id
        AND ban.user_id = p_target
        AND ban.active
    );

  -- Lift every active AI-moderation ban for this user, retaining the audit trail.
  UPDATE public.scrl_moderation_bans
  SET active = false,
      lifted_at = now(),
      lifted_by = auth.uid()
  WHERE user_id = p_target
    AND active;

  -- Also remove an ordinary administrator-issued profile block, if present.
  UPDATE public.profiles
  SET blocked = false,
      block_reason = '',
      updated_at = now()
  WHERE id = p_target;

  INSERT INTO public.audit(actor_id, message)
  VALUES (auth.uid(), 'Администратор снял блокировку пользователя ' || p_target::text);
END;
$function$;

REVOKE ALL ON FUNCTION public.scrl_admin_unblock_user(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.scrl_admin_unblock_user(uuid) TO authenticated;
