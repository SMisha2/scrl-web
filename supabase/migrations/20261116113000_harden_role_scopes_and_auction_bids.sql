-- Protect class assignment and keep financial reservations consistent on administrative actions.
-- The existing trigger name is retained for compatibility; it now covers every non-admin user.
CREATE OR REPLACE FUNCTION public.scrl_prevent_teacher_room_self_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL
     AND auth.uid() = OLD.id
     AND NOT public.scrl_is_admin()
     AND NEW.room IS DISTINCT FROM OLD.room THEN
    RAISE EXCEPTION 'Класс может менять только администратор.';
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.scrl_admin_set_user(
  p_target uuid,
  p_action text,
  p_reason text DEFAULT '',
  p_room text DEFAULT ''
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
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

  IF NOT FOUND
     OR v_user.deleted_at IS NOT NULL
     OR (v_user.id = auth.uid() AND p_action IN ('block', 'remove')) THEN
    RAISE EXCEPTION 'Недопустимое действие.';
  END IF;

  IF v_user.role = 'admin' AND p_action IN ('block', 'remove', 'anonymize') THEN
    RAISE EXCEPTION 'Нельзя изменить статус другого администратора.';
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

      -- Release every active exchange order in the same transaction as the block.
      -- Lock each order before its wallet, matching the buyer settlement order.
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

CREATE OR REPLACE FUNCTION public.scrl_place_bid(p_auction uuid, p_amount numeric)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_auction public.auctions%rowtype;
  v_wallet public.wallets%rowtype;
  v_old public.wallets%rowtype;
  v_role text;
  v_min numeric;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Требуется вход.';
  END IF;

  -- Serialise a user's bids with administrative blocking.
  SELECT role INTO v_role
  FROM public.profiles
  WHERE id = auth.uid() AND NOT blocked AND deleted_at IS NULL
  FOR UPDATE;

  IF v_role IS NULL OR v_role <> 'student' THEN
    RAISE EXCEPTION 'Ставки доступны только активным ученикам.';
  END IF;

  SELECT * INTO v_auction
  FROM public.auctions
  WHERE id = p_auction AND status = 'active' AND ends_at > now()
  FOR UPDATE;

  IF NOT FOUND OR v_auction.owner_id = auth.uid() THEN
    RAISE EXCEPTION 'Этот аукцион уже закрыт или принадлежит тебе.';
  END IF;

  v_min := CASE
    WHEN v_auction.current_bid > 0 THEN v_auction.current_bid + v_auction.step
    ELSE v_auction.start_price
  END;

  IF p_amount IS NULL
     OR p_amount::text = 'NaN'
     OR p_amount < v_min
     OR p_amount > 1000000
     OR trunc(p_amount) <> p_amount THEN
    RAISE EXCEPTION 'Минимальная ставка — % ScRl.', v_min;
  END IF;

  IF v_auction.leader_id IS NOT NULL AND v_auction.current_bid > 0 THEN
    IF v_auction.leader_id = auth.uid() THEN
      SELECT * INTO v_wallet
      FROM public.wallets
      WHERE user_id = auth.uid()
      FOR UPDATE;

      IF NOT FOUND OR v_wallet.hold_scrl < v_auction.current_bid THEN
        RAISE EXCEPTION 'Не найден полный резерв предыдущей ставки.';
      END IF;

      UPDATE public.wallets
      SET hold_scrl = hold_scrl - v_auction.current_bid,
          scrl = scrl + v_auction.current_bid,
          updated_at = now()
      WHERE user_id = auth.uid();

      UPDATE public.bids
      SET status = 'raised'
      WHERE auction_id = p_auction
        AND user_id = auth.uid()
        AND amount = v_auction.current_bid
        AND status = 'active';

      INSERT INTO public.ledger(user_id, currency, delta, note, actor_id)
      VALUES (auth.uid(), 'ScRl', v_auction.current_bid, 'Возврат предыдущей ставки перед повышением', auth.uid());

      SELECT * INTO v_wallet
      FROM public.wallets
      WHERE user_id = auth.uid()
      FOR UPDATE;

    ELSE
      -- Always lock the bidder and previous leader wallets in UUID order.
      IF auth.uid() < v_auction.leader_id THEN
        SELECT * INTO v_wallet
        FROM public.wallets
        WHERE user_id = auth.uid()
        FOR UPDATE;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Кошелёк участника не найден.';
        END IF;

        SELECT * INTO v_old
        FROM public.wallets
        WHERE user_id = v_auction.leader_id
        FOR UPDATE;
      ELSE
        SELECT * INTO v_old
        FROM public.wallets
        WHERE user_id = v_auction.leader_id
        FOR UPDATE;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Кошелёк предыдущего лидера не найден.';
        END IF;

        SELECT * INTO v_wallet
        FROM public.wallets
        WHERE user_id = auth.uid()
        FOR UPDATE;
      END IF;

      IF v_wallet.user_id IS NULL THEN
        RAISE EXCEPTION 'Кошелёк участника не найден.';
      END IF;
      IF v_old.user_id IS NULL OR v_old.hold_scrl < v_auction.current_bid THEN
        RAISE EXCEPTION 'Не найден полный резерв предыдущей ставки.';
      END IF;

      UPDATE public.wallets
      SET hold_scrl = hold_scrl - v_auction.current_bid,
          scrl = scrl + v_auction.current_bid,
          updated_at = now()
      WHERE user_id = v_auction.leader_id;

      UPDATE public.bids
      SET status = 'outbid'
      WHERE auction_id = p_auction
        AND user_id = v_auction.leader_id
        AND amount = v_auction.current_bid
        AND status = 'active';

      INSERT INTO public.ledger(user_id, currency, delta, note, actor_id)
      VALUES (v_auction.leader_id, 'ScRl', v_auction.current_bid, 'Возврат перебитой ставки', auth.uid());

      PERFORM public.scrl_notify(
        v_auction.leader_id,
        'Твою ставку в аукционе «' || left(v_auction.title, 80) || '» перебили.'
      );
    END IF;

  ELSE
    SELECT * INTO v_wallet
    FROM public.wallets
    WHERE user_id = auth.uid()
    FOR UPDATE;
  END IF;

  IF v_wallet.user_id IS NULL OR v_wallet.scrl < p_amount THEN
    RAISE EXCEPTION 'Недостаточно ScRl для такой ставки.';
  END IF;

  UPDATE public.wallets
  SET scrl = scrl - p_amount,
      hold_scrl = hold_scrl + p_amount,
      updated_at = now()
  WHERE user_id = auth.uid();

  INSERT INTO public.ledger(user_id, currency, delta, note, actor_id)
  VALUES (auth.uid(), 'ScRl', -p_amount, 'Ставка в аукционе: ' || left(v_auction.title, 100), auth.uid());

  INSERT INTO public.bids(auction_id, user_id, amount)
  VALUES (p_auction, auth.uid(), p_amount);

  UPDATE public.auctions
  SET current_bid = p_amount,
      leader_id = auth.uid(),
      bids_count = bids_count + 1
  WHERE id = p_auction;

  PERFORM public.scrl_notify(v_auction.owner_id, 'Новая ставка в аукционе «' || left(v_auction.title, 80) || '».');
  PERFORM public.scrl_log(auth.uid(), 'Сделана ставка ' || p_amount || ' ScRl в аукционе.');
END;
$function$;
