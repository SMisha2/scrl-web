create or replace function public.scrl_reject_held_financial_content()
returns trigger
language plpgsql
security definer
set search_path = public,auth,pg_temp
as $function$
declare
  v_kind text;
  v_payload jsonb;
  v_decision text;
begin
  if auth.uid() is null then return new; end if;
  if tg_table_name='deals' then
    v_kind:='deal';
    v_payload:=jsonb_build_object('title',btrim(new.title));
  elsif tg_table_name='ledger' then
    if new.note not like 'Начисление: %' then return new; end if;
    v_kind:='teacher_issue';
    v_payload:=jsonb_build_object(
      'student_id',new.user_id::text,
      'amount',new.delta,
      'reason',left(btrim(substring(new.note from length('Начисление: ')+1)),120)
    );
  else
    return new;
  end if;

  select decision into v_decision
  from public.scrl_moderation_tickets
  where user_id=auth.uid() and kind=v_kind and payload=v_payload and consumed_at is not null
  order by consumed_at desc limit 1;

  if v_decision in ('flag','hide') then
    raise exception 'Операция остановлена ИИ-модерацией и отправлена администратору на проверку.';
  end if;
  return new;
end;
$function$;

revoke all on function public.scrl_reject_held_financial_content() from public,anon,authenticated;
grant execute on function public.scrl_reject_held_financial_content() to service_role;

drop trigger if exists scrl_stop_held_deals on public.deals;
create trigger scrl_stop_held_deals before insert or update of title
  on public.deals for each row execute function public.scrl_reject_held_financial_content();

drop trigger if exists scrl_stop_held_teacher_issues on public.ledger;
create trigger scrl_stop_held_teacher_issues before insert
  on public.ledger for each row execute function public.scrl_reject_held_financial_content();
