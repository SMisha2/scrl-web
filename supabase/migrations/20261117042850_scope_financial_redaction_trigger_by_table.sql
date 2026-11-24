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

  -- Check table identity before reading table-specific record fields.
  if tg_op = 'UPDATE' and public.scrl_is_admin() then
    if tg_table_name = 'deals' then
      if new.title = 'Сделка удалённого участника'
         and old.buyer_id = new.buyer_id
         and old.seller_id = new.seller_id
         and (
           current_setting('scrl.account_cleanup_user', true) = new.buyer_id::text
           or current_setting('scrl.account_cleanup_user', true) = new.seller_id::text
         ) then
        return new;
      end if;
    end if;
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
