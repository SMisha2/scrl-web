create index if not exists scrl_user_consents_verified_by_idx
  on private.scrl_user_consents (verified_by)
  where verified_by is not null;

create index if not exists scrl_user_safety_parent_exchange_verified_by_idx
  on private.scrl_user_safety (parent_exchange_verified_by)
  where parent_exchange_verified_by is not null;

create or replace function public.scrl_request_exchange_parent_consent(p_parent_confirmed boolean)
returns void
language plpgsql
security definer
set search_path = public, auth, private, pg_temp
as $$
declare
  v_row private.scrl_user_safety%rowtype;
  v_age integer;
begin
  if auth.uid() is null then raise exception 'Требуется вход.'; end if;
  if p_parent_confirmed is not true then
    raise exception 'Подтверди, что законный представитель действительно дал согласие.';
  end if;

  select * into v_row
  from private.scrl_user_safety
  where user_id = auth.uid()
  for update;

  if not found
     or v_row.personal_data_consent_at is null
     or v_row.personal_data_consent_version <> '2026-11-17-v1'
     or v_row.ai_moderation_consent_at is null
     or v_row.ai_moderation_consent_version <> '2026-11-17-v1' then
    raise exception 'Сначала прими актуальные согласия на странице конфиденциальности.';
  end if;

  v_age := extract(year from age(current_date, v_row.birth_date))::integer;
  if v_age < 14 then raise exception 'Биржа доступна только с 14 лет.'; end if;
  if v_age >= 18 then raise exception 'Для совершеннолетнего пользователя родительское согласие не требуется.'; end if;
  if v_row.parent_exchange_status = 'approved' then
    raise exception 'Доступ к бирже уже подтверждён.';
  end if;
  if v_row.parent_exchange_status = 'pending' then
    raise exception 'Заявка уже отправлена и ожидает проверки администратора.';
  end if;

  update private.scrl_user_safety
  set parent_exchange_status = 'pending',
      parent_exchange_requested_at = now(),
      parent_exchange_verified_at = null,
      parent_exchange_verified_by = null,
      updated_at = now()
  where user_id = auth.uid();

  insert into public.audit(actor_id, message)
  values (auth.uid(), 'Отправлена заявка на проверку родительского согласия для биржи.');
end;
$$;

revoke all on function public.scrl_request_exchange_parent_consent(boolean) from public, anon;
grant execute on function public.scrl_request_exchange_parent_consent(boolean) to authenticated;
