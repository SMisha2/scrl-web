CREATE OR REPLACE FUNCTION public.scrl_moderation_guard_content()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_kind text;
  v_payload jsonb;
  v_ticket public.scrl_moderation_tickets%rowtype;
  v_user_id uuid;
begin
  -- Background/service-role operations without an end-user JWT are trusted server operations.
  if v_uid is null then
    return new;
  end if;

  if exists (select 1 from public.profiles p where p.id = v_uid and p.blocked) then
    raise exception 'Аккаунт заблокирован.';
  end if;

  -- Only the authorized administrator account-redaction RPC can set this
  -- transaction-local marker. Check table identity before accessing table-specific fields.
  if tg_op = 'UPDATE' and public.scrl_is_admin() then
    if tg_table_name = 'posts' then
      if current_setting('scrl.account_cleanup_user', true) = new.owner_id::text
         and old.owner_id = new.owner_id
         and new.title = 'Удалённая публикация'
         and new.description = 'Содержимое удалено автором'
         and new.status = 'hidden' then
        return new;
      end if;
    elsif tg_table_name = 'listings' then
      if current_setting('scrl.account_cleanup_user', true) = new.owner_id::text
         and old.owner_id = new.owner_id
         and new.title = 'Удалённая услуга'
         and new.description = 'Содержимое удалено автором'
         and new.status = 'hidden' then
        return new;
      end if;
    elsif tg_table_name = 'auctions' then
      if current_setting('scrl.account_cleanup_user', true) = new.owner_id::text
         and old.owner_id = new.owner_id
         and new.title = 'Аукцион удалённого участника'
         and new.prize = 'Информация удалена' then
        return new;
      end if;
    elsif tg_table_name = 'deals' then
      if new.title = 'Сделка удалённого участника'
         and (
           (current_setting('scrl.account_cleanup_user', true) = new.buyer_id::text and old.buyer_id = new.buyer_id)
           or
           (current_setting('scrl.account_cleanup_user', true) = new.seller_id::text and old.seller_id = new.seller_id)
         ) then
        return new;
      end if;
    end if;
  end if;

  case tg_table_name
    when 'posts' then
      v_kind := 'post';
      v_user_id := new.owner_id;
      v_payload := jsonb_build_object(
        'type', new.type, 'title', btrim(new.title), 'description', btrim(new.description),
        'category', coalesce(nullif(btrim(new.category), ''), 'Другое'), 'price', new.price
      );
    when 'listings' then
      v_kind := 'listing';
      v_user_id := new.owner_id;
      v_payload := jsonb_build_object(
        'title', btrim(new.title), 'description', btrim(new.description),
        'category', coalesce(nullif(btrim(new.category), ''), 'Другое'),
        'price', new.price, 'slots', new.slots
      );
    when 'auctions' then
      v_kind := 'auction';
      v_user_id := new.owner_id;
      v_payload := jsonb_build_object(
        'title', btrim(new.title), 'prize', btrim(new.prize),
        'start_price', new.start_price, 'step', new.step
      );
    when 'deals' then
      v_kind := 'deal';
      v_user_id := v_uid;
      v_payload := jsonb_build_object('title', btrim(new.title));
    when 'deal_messages' then
      v_kind := 'message';
      v_user_id := new.user_id;
      v_payload := jsonb_build_object('deal_id', new.deal_id::text, 'message', btrim(new.message));
    when 'reviews' then
      v_kind := 'review';
      v_user_id := new.user_id;
      v_payload := jsonb_build_object(
        'deal_id', new.deal_id::text, 'target_id', new.target_id::text,
        'rating', new.rating, 'text', btrim(coalesce(new.text, ''))
      );
    when 'profiles' then
      if tg_op = 'UPDATE' and new.full_name is not distinct from old.full_name then
        return new;
      end if;
      if tg_op = 'UPDATE' and new.full_name = 'Удалённый участник' and public.scrl_is_admin() then
        return new;
      end if;
      v_kind := 'profile';
      v_user_id := new.id;
      v_payload := jsonb_build_object('full_name', btrim(new.full_name));
    when 'reports' then
      v_kind := 'report';
      v_user_id := new.reporter_id;
      v_payload := jsonb_build_object(
        'kind', new.kind, 'target_id', new.target_id,
        'reason', btrim(new.reason), 'reason_code', new.reason_code,
        'details', btrim(coalesce(new.details, ''))
      );
    when 'ledger' then
      if new.note not like 'Начисление: %' then
        return new;
      end if;
      v_kind := 'teacher_issue';
      v_user_id := new.actor_id;
      v_payload := jsonb_build_object(
        'student_id', new.user_id::text, 'amount', new.delta,
        'reason', left(btrim(substring(new.note from length('Начисление: ') + 1)), 120)
      );
    else
      return new;
  end case;

  if v_user_id is null or v_user_id <> v_uid then
    raise exception 'Не удалось сопоставить автора с проверяемым содержимым.';
  end if;

  select * into v_ticket
  from public.scrl_moderation_tickets t
  where t.user_id = v_uid
    and t.kind = v_kind
    and t.payload = v_payload
    and t.consumed_at is null
    and t.expires_at > now()
  order by t.created_at desc
  limit 1
  for update;

  if not found then
    raise exception 'Публикация не прошла серверную ИИ-проверку. Повтори отправку.';
  end if;

  update public.scrl_moderation_tickets
  set consumed_at = now()
  where id = v_ticket.id;

  if v_ticket.case_id is not null then
    update public.scrl_moderation_cases
    set source_id = case
      when tg_table_name = 'profiles' then new.id::text
      else new.id::text
    end,
    source_table = tg_table_name
    where id = v_ticket.case_id;
  end if;

  if v_ticket.decision in ('flag','hide') then
    case tg_table_name
      when 'posts' then new.status := case when v_ticket.decision = 'flag' then 'review' else 'hidden' end;
      when 'listings' then new.status := case when v_ticket.decision = 'flag' then 'review' else 'hidden' end;
      when 'auctions' then new.status := case when v_ticket.decision = 'flag' then 'review' else 'hidden' end;
      when 'deal_messages' then new.status := case when v_ticket.decision = 'flag' then 'review' else 'hidden' end;
      when 'reviews' then new.status := case when v_ticket.decision = 'flag' then 'review' else 'hidden' end;
      when 'profiles' then new.full_name := old.full_name;
      when 'ledger' then new.note := 'Начисление: основание скрыто до проверки';
      else
        null;
    end case;
  end if;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.scrl_reject_held_financial_content()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_kind text;
  v_payload jsonb;
  v_decision text;
begin
  if auth.uid() is null then return new; end if;

  -- Authorized account anonymization may redact an existing deal title only.
  if tg_op = 'UPDATE' and tg_table_name = 'deals'
     and public.scrl_is_admin()
     and new.title = 'Сделка удалённого участника'
     and old.buyer_id = new.buyer_id
     and old.seller_id = new.seller_id
     and (
       current_setting('scrl.account_cleanup_user', true) = new.buyer_id::text
       or current_setting('scrl.account_cleanup_user', true) = new.seller_id::text
     ) then
    return new;
  end if;

  if tg_table_name = 'deals' then
    v_kind := 'deal';
    v_payload := jsonb_build_object('title', btrim(new.title));
  elsif tg_table_name = 'ledger' then
    if new.note not like 'Начисление: %' then return new; end if;
    v_kind := 'teacher_issue';
    v_payload := jsonb_build_object(
      'student_id', new.user_id::text,
      'amount', new.delta,
      'reason', left(btrim(substring(new.note from length('Начисление: ') + 1)), 120)
    );
  else
    return new;
  end if;

  select decision into v_decision
  from public.scrl_moderation_tickets
  where user_id = auth.uid()
    and kind = v_kind
    and payload = v_payload
    and consumed_at is not null
  order by consumed_at desc
  limit 1;

  if v_decision in ('flag','hide') then
    raise exception 'Операция остановлена ИИ-модерацией и отправлена администратору на проверку.';
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.scrl_delete_account(p_user uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_profile public.profiles%rowtype;
  v_wallet public.wallets%rowtype;
BEGIN
  IF coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' AND NOT public.scrl_is_admin() THEN
    RAISE EXCEPTION 'Недостаточно прав для удаления аккаунта.';
  END IF;
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'Не удалось определить аккаунт.';
  END IF;

  SELECT * INTO v_profile
  FROM public.profiles
  WHERE id = p_user
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Профиль не найден.';
  END IF;
  IF v_profile.deleted_at IS NOT NULL THEN
    RETURN;
  END IF;

  IF v_profile.role = 'admin' AND NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE role = 'admin'
      AND blocked = false
      AND deleted_at IS NULL
      AND id <> p_user
  ) THEN
    RAISE EXCEPTION 'Сначала назначь другого администратора, затем можно удалить этот аккаунт.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.deals
    WHERE (buyer_id = p_user OR seller_id = p_user)
      AND status IN ('work', 'ready', 'dispute')
  ) THEN
    RAISE EXCEPTION 'Перед удалением заверши или урегулируй активные сделки.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.exchange_orders
    WHERE owner_id = p_user AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'Перед удалением отмени активные заявки на бирже.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.auctions
    WHERE status IN ('active', 'settlementError')
      AND (owner_id = p_user OR leader_id = p_user)
  ) THEN
    RAISE EXCEPTION 'Перед удалением дождись завершения активных аукционов.';
  END IF;

  SELECT * INTO v_wallet
  FROM public.wallets
  WHERE user_id = p_user
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Кошелёк аккаунта не найден. Обратись к администратору.';
  END IF;

  IF v_wallet.hold_scrl > 0 OR v_wallet.hold_vrub > 0 THEN
    RAISE EXCEPTION 'Сначала освободи все резервы ScRl и V-RUB.';
  END IF;

  -- Explicitly remove the unavailable balance from active supply.
  -- The following ledger anonymization preserves the accounting trail without PII.
  IF v_wallet.scrl > 0 THEN
    INSERT INTO public.ledger(user_id, currency, delta, note, actor_id)
    VALUES (p_user, 'ScRl', -v_wallet.scrl, 'Остаток ScRl списан при удалении аккаунта', p_user);

    UPDATE public.platform_settings
    SET burned_scrl = burned_scrl + v_wallet.scrl,
        updated_at = now()
    WHERE singleton = true;
  END IF;

  IF v_wallet.vrub > 0 THEN
    INSERT INTO public.ledger(user_id, currency, delta, note, actor_id)
    VALUES (p_user, 'V-RUB', -v_wallet.vrub, 'Остаток V-RUB списан при удалении аккаунта', p_user);
  END IF;

  UPDATE public.wallets
  SET scrl = 0,
      vrub = 0,
      hold_scrl = 0,
      hold_vrub = 0,
      updated_at = now()
  WHERE user_id = p_user;

  -- Mark this transaction as the authorized anonymization of exactly this user.
  -- The content trigger validates this marker, the current admin role and fixed redaction text.
  PERFORM set_config('scrl.account_cleanup_user', p_user::text, true);

  -- Remove user-authored personal content while preserving financial records.
  UPDATE public.posts
  SET title = 'Удалённая публикация',
      description = 'Содержимое удалено автором',
      category = 'Другое',
      status = 'hidden'
  WHERE owner_id = p_user;

  UPDATE public.listings
  SET title = 'Удалённая услуга',
      description = 'Содержимое удалено автором',
      category = 'Другое',
      status = 'hidden'
  WHERE owner_id = p_user;

  UPDATE public.deals
  SET title = 'Сделка удалённого участника'
  WHERE buyer_id = p_user OR seller_id = p_user;

  UPDATE public.auctions
  SET title = 'Аукцион удалённого участника',
      prize = 'Информация удалена'
  WHERE owner_id = p_user
    AND status NOT IN ('active', 'settlementError');

  PERFORM set_config('scrl.account_cleanup_user', '', true);

  DELETE FROM public.deal_messages WHERE user_id = p_user;
  DELETE FROM public.reviews WHERE user_id = p_user;
  DELETE FROM public.reports WHERE reporter_id = p_user;
  DELETE FROM public.favorites WHERE user_id = p_user;
  DELETE FROM public.notifications WHERE user_id = p_user;
  DELETE FROM public.activity WHERE user_id = p_user;
  DELETE FROM public.teacher_issuance WHERE teacher_id = p_user;
  DELETE FROM public.scrl_moderation_appeals WHERE user_id = p_user;
  DELETE FROM public.scrl_moderation_bans WHERE user_id = p_user;
  DELETE FROM public.scrl_moderation_cases WHERE user_id = p_user;
  DELETE FROM public.scrl_moderation_tickets WHERE user_id = p_user;

  -- Preserve the ledger but remove free-text notes that could contain PII.
  UPDATE public.ledger
  SET note = 'Операция удалённого участника'
  WHERE user_id = p_user
     OR actor_id = p_user;

  -- Retain a pseudonymous profile as the stable FK target for historical records.
  UPDATE public.profiles
  SET full_name = 'Удалённый участник',
      room = '',
      role = 'student',
      blocked = true,
      block_reason = 'Аккаунт удалён пользователем',
      deleted_at = now(),
      updated_at = now()
  WHERE id = p_user;
END;
$function$
;