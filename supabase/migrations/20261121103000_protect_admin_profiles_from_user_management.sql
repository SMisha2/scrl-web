-- Keep administrator accounts outside the ordinary user-role management RPC.
-- A peer admin must not be able to demote or edit another admin through student/teacher actions.
BEGIN;

CREATE OR REPLACE FUNCTION public.scrl_admin_set_user(
  p_target uuid,
  p_action text,
  p_reason text DEFAULT '',
  p_room text DEFAULT ''
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $function$
DECLARE
  v_user public.profiles%rowtype;
  v_order public.exchange_orders%rowtype;
  v_refunded boolean := false;
BEGIN
  IF NOT public.scrl_is_admin() THEN
    RAISE EXCEPTION 'Нет доступа.';
  END IF;

  SELECT * INTO v_user
  FROM public.profiles
  WHERE id = p_target
  FOR UPDATE;

  IF NOT FOUND OR v_user.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'Недопустимое действие.';
  END IF;

  IF v_user.role = 'admin' THEN
    RAISE EXCEPTION 'Профили администраторов нельзя изменять через управление участниками.';
  END IF;

  IF v_user.id = auth.uid() AND p_action IN ('block', 'remove', 'anonymize') THEN
    RAISE EXCEPTION 'Нельзя заблокировать или обезличить собственный аккаунт администратора.';
  END IF;

  IF p_action = 'teacher' THEN
    IF length(btrim(coalesce(p_room, ''))) = 0 OR length(btrim(p_room)) > 12 THEN
      RAISE EXCEPTION 'Укажи класс учителя (до 12 символов).';
    END IF;

    UPDATE public.profiles
    SET role = 'teacher', room = btrim(p_room), updated_at = now()
    WHERE id = p_target;

  ELSIF p_action = 'student' THEN
    UPDATE public.profiles
    SET role = 'student', room = '', updated_at = now()
    WHERE id = p_target;

  ELSIF p_action = 'class' THEN
    IF v_user.role NOT IN ('student', 'teacher')
       OR length(btrim(coalesce(p_room, ''))) = 0
       OR length(btrim(p_room)) > 12 THEN
      RAISE EXCEPTION 'Класс должен содержать от 1 до 12 символов.';
    END IF;

    UPDATE public.profiles
    SET room = btrim(p_room), updated_at = now()
    WHERE id = p_target;

  ELSIF p_action = 'block' THEN
    IF v_user.blocked THEN
      IF EXISTS (
        SELECT 1
        FROM public.scrl_moderation_bans
        WHERE user_id = p_target AND active
      ) THEN
        RAISE EXCEPTION 'ИИ-блокировку нужно снимать через рассмотрение дела или апелляции.';
      END IF;

      UPDATE public.profiles
      SET blocked = false, block_reason = '', updated_at = now()
      WHERE id = p_target;
    ELSE
      IF EXISTS (
        SELECT 1
        FROM public.deals
        WHERE (buyer_id = p_target OR seller_id = p_target)
          AND status IN ('work', 'ready', 'dispute')
      ) THEN
        RAISE EXCEPTION 'Сначала заверши активные сделки и разреши споры участника.';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM public.auctions
        WHERE status IN ('active', 'settlementError')
          AND (owner_id = p_target OR leader_id = p_target)
      ) THEN
        RAISE EXCEPTION 'Сначала заверши активные аукционы участника.';
      END IF;

      FOR v_order IN
        SELECT *
        FROM public.exchange_orders
        WHERE owner_id = p_target AND status = 'active'
        ORDER BY id
        FOR UPDATE
      LOOP
        IF v_order.side = 'scrlSell' THEN
          UPDATE public.wallets
          SET hold_scrl = hold_scrl - v_order.amount,
              scrl = scrl + v_order.amount,
              updated_at = now()
          WHERE user_id = p_target AND hold_scrl >= v_order.amount;

          IF NOT FOUND THEN
            RAISE EXCEPTION 'Не удалось проверить резерв ScRl заявки участника.';
          END IF;

          INSERT INTO public.ledger(user_id, currency, delta, note, actor_id)
          VALUES (p_target, 'ScRl', v_order.amount, 'Возврат резерва заявки при блокировке', auth.uid());

        ELSIF v_order.side = 'vrubSell' THEN
          UPDATE public.wallets
          SET hold_vrub = hold_vrub - v_order.amount,
              vrub = vrub + v_order.amount,
              updated_at = now()
          WHERE user_id = p_target AND hold_vrub >= v_order.amount;

          IF NOT FOUND THEN
            RAISE EXCEPTION 'Не удалось проверить резерв V-RUB заявки участника.';
          END IF;

          INSERT INTO public.ledger(user_id, currency, delta, note, actor_id)
          VALUES (p_target, 'V-RUB', v_order.amount, 'Возврат резерва заявки при блокировке', auth.uid());

        ELSE
          RAISE EXCEPTION 'Неизвестное направление заявки биржи.';
        END IF;

        UPDATE public.exchange_orders
        SET status = 'cancelled', cancelled_at = now()
        WHERE id = v_order.id;
        v_refunded := true;
      END LOOP;

      UPDATE public.profiles
      SET blocked = true,
          block_reason = left(coalesce(nullif(btrim(p_reason), ''), 'Нарушение правил'), 180),
          updated_at = now()
      WHERE id = p_target;

      IF v_refunded THEN
        PERFORM public.scrl_notify(p_target, 'Заявки биржи отменены, резервы возвращены при блокировке аккаунта.');
      END IF;
    END IF;

  ELSIF p_action = 'anonymize' THEN
    IF EXISTS (
      SELECT 1 FROM public.deals
      WHERE (buyer_id = p_target OR seller_id = p_target)
        AND status IN ('work', 'ready', 'dispute')
    )
    OR EXISTS (
      SELECT 1 FROM public.exchange_orders
      WHERE owner_id = p_target AND status = 'active'
    )
    OR EXISTS (
      SELECT 1 FROM public.auctions
      WHERE status IN ('active', 'settlementError')
        AND (owner_id = p_target OR leader_id = p_target)
    ) THEN
      RAISE EXCEPTION 'Сначала заверши активные сделки, заявки и аукционы.';
    END IF;

    UPDATE public.profiles
    SET full_name = 'Удалённый участник',
        room = '',
        role = 'student',
        blocked = true,
        block_reason = 'Профиль обезличен',
        updated_at = now()
    WHERE id = p_target;

    UPDATE public.posts SET status = 'hidden' WHERE owner_id = p_target;
    UPDATE public.listings SET status = 'hidden' WHERE owner_id = p_target;

  ELSE
    RAISE EXCEPTION 'Неизвестное административное действие.';
  END IF;

  INSERT INTO public.audit(actor_id, message)
  VALUES (auth.uid(), 'Администраторское действие ' || p_action || ' для ' || p_target::text);
END;
$function$;

REVOKE ALL ON FUNCTION public.scrl_admin_set_user(uuid, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.scrl_admin_set_user(uuid, text, text, text) TO authenticated;

COMMIT;
