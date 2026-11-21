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
