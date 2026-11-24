-- Refuse escrow settlement when the buyer's reserved balance is incomplete.
-- Lock both participant wallets in a stable order before any settlement writes.
BEGIN;

CREATE OR REPLACE FUNCTION public.scrl_deal_action(
  p_deal uuid,
  p_action text,
  p_share numeric DEFAULT 1
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $function$
DECLARE
  v_deal public.deals%rowtype;
  v_buyer_wallet public.wallets%rowtype;
  v_seller_wallet public.wallets%rowtype;
  v_fee_rate numeric;
  v_fee numeric;
  v_gross numeric;
  v_seller numeric;
  v_buyer numeric;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Требуется вход.';
  END IF;

  SELECT * INTO v_deal
  FROM public.deals
  WHERE id = p_deal
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Сделка не найдена.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND blocked
  ) AND NOT public.scrl_is_admin() THEN
    RAISE EXCEPTION 'Аккаунт заблокирован. Решение по активной сделке принимает администратор.';
  END IF;

  IF p_action = 'delivered' THEN
    IF auth.uid() <> v_deal.seller_id OR v_deal.status <> 'work' THEN
      RAISE EXCEPTION 'Нельзя отметить выполнение этой сделки.';
    END IF;

    UPDATE public.deals SET status = 'ready' WHERE id = p_deal;
    PERFORM public.scrl_notify(v_deal.buyer_id, 'Исполнитель отметил заказ как выполненный.');
    PERFORM public.scrl_log(v_deal.seller_id, 'Отмечено выполнение заказа «' || left(v_deal.title, 100) || '».');
    RETURN;
  ELSIF p_action = 'dispute' THEN
    IF auth.uid() NOT IN (v_deal.buyer_id, v_deal.seller_id)
       OR v_deal.status NOT IN ('work', 'ready') THEN
      RAISE EXCEPTION 'Нельзя открыть спор по этой сделке.';
    END IF;

    UPDATE public.deals SET status = 'dispute' WHERE id = p_deal;
    INSERT INTO public.reports(kind, target_id, reporter_id, reason, reason_code)
    VALUES (
      'deal', p_deal::text, auth.uid(),
      'Спор по сделке «' || left(v_deal.title, 100) || '»', 'deal'
    );
    PERFORM public.scrl_notify(v_deal.buyer_id, 'Открыт спор по сделке.');
    PERFORM public.scrl_notify(v_deal.seller_id, 'Открыт спор по сделке.');
    PERFORM public.scrl_log(auth.uid(), 'Открыт спор по сделке «' || left(v_deal.title, 100) || '».');
    RETURN;
  END IF;

  IF p_action NOT IN ('confirm', 'refund', 'pay', 'split') THEN
    RAISE EXCEPTION 'Неизвестное действие.';
  END IF;

  IF p_action = 'confirm' THEN
    IF auth.uid() <> v_deal.buyer_id OR v_deal.status <> 'ready' THEN
      RAISE EXCEPTION 'Сначала исполнитель должен отметить выполнение.';
    END IF;
    p_action := 'pay';
  ELSIF NOT public.scrl_is_admin() THEN
    RAISE EXCEPTION 'Нет доступа.';
  END IF;

  IF v_deal.status NOT IN ('ready', 'dispute', 'work') THEN
    RAISE EXCEPTION 'Сделка уже завершена.';
  END IF;

  IF v_deal.escrow IS NULL OR v_deal.escrow < 0 THEN
    RAISE EXCEPTION 'У сделки некорректный резерв. Обратись к администратору.';
  END IF;

  IF v_deal.escrow = 0 THEN
    UPDATE public.deals
    SET status = CASE WHEN p_action = 'refund' THEN 'refund' ELSE 'done' END,
        closed_at = now()
    WHERE id = p_deal;
    RETURN;
  END IF;

  IF p_action = 'refund' THEN
    v_gross := 0;
    v_fee := 0;
    v_seller := 0;
    v_buyer := v_deal.escrow;
  ELSE
    v_fee_rate := public.scrl_current_fee();
    v_gross := CASE
      WHEN p_action = 'split'
        THEN round(v_deal.escrow * least(1, greatest(0, coalesce(p_share, 0.5))), 2)
      ELSE v_deal.escrow
    END;
    v_fee := round(v_gross * coalesce(v_fee_rate, 0.01), 2);
    v_seller := v_gross - v_fee;
    v_buyer := v_deal.escrow - v_gross;
  END IF;

  -- A fixed lock order prevents opposite-direction settlements from deadlocking.
  PERFORM w.user_id
  FROM public.wallets AS w
  WHERE w.user_id IN (v_deal.buyer_id, v_deal.seller_id)
  ORDER BY w.user_id
  FOR UPDATE;

  SELECT * INTO v_buyer_wallet
  FROM public.wallets
  WHERE user_id = v_deal.buyer_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Кошелёк покупателя не найден. Выплата остановлена.';
  END IF;

  SELECT * INTO v_seller_wallet
  FROM public.wallets
  WHERE user_id = v_deal.seller_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Кошелёк исполнителя не найден. Выплата остановлена.';
  END IF;

  IF v_buyer_wallet.hold_scrl < v_deal.escrow THEN
    RAISE EXCEPTION 'Резерв сделки не совпадает с удержанным балансом покупателя. Выплата остановлена.';
  END IF;

  UPDATE public.wallets
  SET hold_scrl = hold_scrl - v_deal.escrow,
      updated_at = now()
  WHERE user_id = v_deal.buyer_id
    AND hold_scrl >= v_deal.escrow;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Не удалось безопасно освободить резерв сделки.';
  END IF;

  IF v_seller > 0 THEN
    UPDATE public.wallets
    SET scrl = scrl + v_seller,
        updated_at = now()
    WHERE user_id = v_deal.seller_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Кошелёк исполнителя недоступен. Выплата отменена.';
    END IF;

    INSERT INTO public.ledger(user_id, currency, delta, note, actor_id)
    VALUES (
      v_deal.seller_id, 'ScRl', v_seller,
      'Оплата по сделке: ' || left(v_deal.title, 100), auth.uid()
    );
  END IF;

  IF v_buyer > 0 THEN
    UPDATE public.wallets
    SET scrl = scrl + v_buyer,
        updated_at = now()
    WHERE user_id = v_deal.buyer_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Кошелёк покупателя недоступен. Возврат отменён.';
    END IF;

    INSERT INTO public.ledger(user_id, currency, delta, note, actor_id)
    VALUES (
      v_deal.buyer_id, 'ScRl', v_buyer,
      'Возврат по сделке: ' || left(v_deal.title, 100), auth.uid()
    );
  END IF;

  UPDATE public.platform_settings
  SET fees_scrl = fees_scrl + v_fee,
      burned_scrl = burned_scrl + v_fee,
      updated_at = now()
  WHERE singleton = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Настройки экономики не найдены. Расчёт сделки отменён.';
  END IF;

  UPDATE public.deals
  SET escrow = 0,
      status = CASE WHEN p_action = 'refund' THEN 'refund' ELSE 'done' END,
      closed_at = now()
  WHERE id = p_deal;

  PERFORM public.scrl_notify(v_deal.buyer_id, 'Сделка «' || left(v_deal.title, 100) || '» завершена.');
  PERFORM public.scrl_notify(v_deal.seller_id, 'Сделка «' || left(v_deal.title, 100) || '» завершена.');
  PERFORM public.scrl_log(auth.uid(), 'Сделка «' || left(v_deal.title, 100) || '» завершена.');
END;
$function$;

REVOKE ALL ON FUNCTION public.scrl_deal_action(uuid, text, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.scrl_deal_action(uuid, text, numeric) TO authenticated;

COMMIT;
