-- Secure publication deletion for owners and administrators.
-- Owners may remove only their own posts/listings. Administrators may remove any.
CREATE OR REPLACE FUNCTION public.scrl_delete_publication(
  p_kind text,
  p_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_owner uuid;
  v_title text;
  v_is_admin boolean;
  v_source text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Требуется войти в аккаунт.';
  END IF;

  IF p_kind NOT IN ('post', 'listing') OR p_id IS NULL THEN
    RAISE EXCEPTION 'Некорректный тип или идентификатор публикации.';
  END IF;

  v_is_admin := public.scrl_is_admin();

  IF p_kind = 'post' THEN
    SELECT owner_id, title INTO v_owner, v_title
    FROM public.posts WHERE id = p_id FOR UPDATE;
    v_source := 'board';
  ELSE
    SELECT owner_id, title INTO v_owner, v_title
    FROM public.listings WHERE id = p_id FOR UPDATE;
    v_source := 'market';
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Публикация не найдена или уже удалена.';
  END IF;

  IF NOT v_is_admin AND v_owner <> auth.uid() THEN
    RAISE EXCEPTION 'Можно удалять только собственные публикации.';
  END IF;

  IF NOT v_is_admin THEN
    IF EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND blocked = true) THEN
      RAISE EXCEPTION 'Заблокированный аккаунт не может удалять публикации.';
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.deals
      WHERE source = v_source AND source_id = p_id::text
        AND status IN ('work', 'ready', 'dispute')
    ) THEN
      RAISE EXCEPTION 'Нельзя удалить публикацию, пока по ней есть активная сделка.';
    END IF;
  END IF;

  -- Deal and financial history stay intact. Admin may remove the public entry
  -- even when an existing deal still points to its original source ID.
  DELETE FROM public.favorites WHERE kind = p_kind AND target_id = p_id::text;
  DELETE FROM public.reports WHERE kind = p_kind AND target_id = p_id::text;

  IF p_kind = 'post' THEN
    DELETE FROM public.posts WHERE id = p_id;
  ELSE
    DELETE FROM public.listings WHERE id = p_id;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Не удалось удалить публикацию.';
  END IF;

  INSERT INTO public.audit(actor_id, message)
  VALUES (
    auth.uid(),
    CASE
      WHEN v_is_admin AND v_owner <> auth.uid()
        THEN 'Администратор удалил публикацию «' || left(v_title, 100) || '» пользователя ' || v_owner::text || '.'
      ELSE 'Пользователь удалил собственную публикацию «' || left(v_title, 100) || '».'
    END
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.scrl_delete_publication(text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.scrl_delete_publication(text, uuid) TO authenticated, service_role;
