CREATE OR REPLACE FUNCTION private.scrl_user_can_exchange(p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'private', 'pg_temp'
AS $function$
  select exists (
    select 1
    from private.scrl_user_safety s
    join public.profiles p on p.id = s.user_id
    where s.user_id = p_user
      and p.deleted_at is null
      and p.blocked = false
      and s.birth_date <= current_date
      and s.personal_data_consent_at is not null
      and s.personal_data_consent_version = '2026-11-17-v1'
      and s.ai_moderation_consent_at is not null
      and s.ai_moderation_consent_version = '2026-11-17-v2'
      and (
        extract(year from age(current_date, s.birth_date)) >= 18
        or (
          extract(year from age(current_date, s.birth_date)) >= 14
          and s.parent_exchange_status = 'approved'
          and s.parent_exchange_verified_at is not null
          and s.parent_exchange_verified_by is not null
        )
      )
  );
$function$;

CREATE OR REPLACE FUNCTION public.scrl_save_my_safety_data(p_birth_date date, p_personal_consent boolean, p_ai_consent boolean, p_personal_version text, p_ai_version text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'private', 'pg_temp'
AS $function$
declare
  v_existing private.scrl_user_safety%rowtype;
  v_age integer;
  v_now timestamptz := now();
begin
  if auth.uid() is null then
    raise exception 'Требуется вход.';
  end if;
  if p_birth_date is null or p_birth_date > current_date
     or p_birth_date < current_date - interval '120 years' then
    raise exception 'Укажи корректную дату рождения.';
  end if;
  if p_personal_consent is not true or p_ai_consent is not true then
    raise exception 'Для использования ScRl необходимо отдельно принять оба согласия.';
  end if;
  if p_personal_version <> '2026-11-17-v1'
     or p_ai_version <> '2026-11-17-v2' then
    raise exception 'Тексты согласий обновились. Обнови страницу и проверь их ещё раз.';
  end if;
  if not exists (
    select 1 from public.profiles
    where id = auth.uid() and deleted_at is null
  ) then
    raise exception 'Профиль не найден.';
  end if;

  select * into v_existing
  from private.scrl_user_safety
  where user_id = auth.uid()
  for update;

  if found and v_existing.birth_date is distinct from p_birth_date then
    raise exception 'Дата рождения уже сохранена. Для её исправления обратись к администратору.';
  end if;

  v_age := extract(year from age(current_date, p_birth_date))::integer;

  if not found then
    insert into private.scrl_user_safety (
      user_id, birth_date,
      personal_data_consent_at, personal_data_consent_version,
      ai_moderation_consent_at, ai_moderation_consent_version,
      parent_exchange_status
    ) values (
      auth.uid(), p_birth_date,
      v_now, p_personal_version,
      v_now, p_ai_version,
      case when v_age >= 18 then 'not_required' else 'not_requested' end
    );
  else
    update private.scrl_user_safety
    set personal_data_consent_at = case
          when personal_data_consent_version is distinct from p_personal_version then v_now
          else personal_data_consent_at end,
        personal_data_consent_version = p_personal_version,
        ai_moderation_consent_at = case
          when ai_moderation_consent_version is distinct from p_ai_version then v_now
          else ai_moderation_consent_at end,
        ai_moderation_consent_version = p_ai_version,
        parent_exchange_status = case
          when v_age >= 18 then 'not_required'
          else parent_exchange_status end,
        updated_at = v_now
    where user_id = auth.uid();
  end if;

  insert into private.scrl_user_consents(user_id, consent_type, policy_version, accepted_at)
  values
    (auth.uid(), 'personal_data', p_personal_version, v_now),
    (auth.uid(), 'ai_moderation', p_ai_version, v_now)
  on conflict (user_id, consent_type, policy_version) do nothing;
end;
$function$;

CREATE OR REPLACE FUNCTION public.scrl_get_my_safety_status()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'private', 'pg_temp'
AS $function$
declare
  v_row private.scrl_user_safety%rowtype;
  v_age integer;
  v_personal_ok boolean;
  v_ai_ok boolean;
begin
  if auth.uid() is null then
    raise exception 'Требуется вход.';
  end if;

  select * into v_row
  from private.scrl_user_safety
  where user_id = auth.uid();

  if not found then
    return jsonb_build_object(
      'birthDate', null,
      'ageYears', null,
      'hasPersonalDataConsent', false,
      'hasAiConsent', false,
      'personalDataConsentVersion', null,
      'aiConsentVersion', null,
      'parentExchangeStatus', 'not_requested',
      'canUseExchange', false,
      'needsOnboarding', true
    );
  end if;

  v_age := extract(year from age(current_date, v_row.birth_date))::integer;
  v_personal_ok := v_row.personal_data_consent_at is not null
    and v_row.personal_data_consent_version = '2026-11-17-v1';
  v_ai_ok := v_row.ai_moderation_consent_at is not null
    and v_row.ai_moderation_consent_version = '2026-11-17-v2';

  return jsonb_build_object(
    'birthDate', v_row.birth_date,
    'ageYears', v_age,
    'hasPersonalDataConsent', v_personal_ok,
    'hasAiConsent', v_ai_ok,
    'personalDataConsentVersion', v_row.personal_data_consent_version,
    'aiConsentVersion', v_row.ai_moderation_consent_version,
    'parentExchangeStatus', case
      when v_age >= 18 then 'not_required'
      when v_age < 14 then 'not_eligible'
      else v_row.parent_exchange_status
    end,
    'canUseExchange', private.scrl_user_can_exchange(auth.uid()),
    'needsOnboarding', (
      v_row.birth_date is null
      or not v_personal_ok
      or not v_ai_ok
    )
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.scrl_request_exchange_parent_consent(p_parent_confirmed boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'private', 'pg_temp'
AS $function$
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
     or v_row.ai_moderation_consent_version <> '2026-11-17-v2' then
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
$function$;

CREATE OR REPLACE FUNCTION private.scrl_require_user_consents()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'private', 'pg_temp'
AS $function$
declare
  v_user uuid;
  v_role text := coalesce(current_setting('request.jwt.claim.role', true), '');
begin
  if v_role = 'service_role' then
    return new;
  end if;

  if tg_table_name = 'profiles' then
    v_user := new.id;
    if auth.uid() is distinct from v_user then return new; end if;
  elsif tg_table_name in ('posts','listings','auctions') then
    v_user := new.owner_id;
  elsif tg_table_name in ('deal_messages','reviews') then
    v_user := new.user_id;
  elsif tg_table_name = 'reports' then
    v_user := new.reporter_id;
  else
    return new;
  end if;

  if v_user is null or not exists (
    select 1
    from private.scrl_user_safety s
    where s.user_id = v_user
      and s.personal_data_consent_at is not null
      and s.personal_data_consent_version = '2026-11-17-v1'
      and s.ai_moderation_consent_at is not null
      and s.ai_moderation_consent_version = '2026-11-17-v2'
  ) then
    raise exception 'Сначала прими актуальное согласие на обработку персональных данных и ИИ-проверку.';
  end if;

  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.scrl_has_ai_processing_consent(p_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  select coalesce(exists (
    select 1
    from private.scrl_user_safety s
    join public.profiles p on p.id = s.user_id
    where s.user_id = p_user_id
      and p.deleted_at is null
      and p.blocked = false
      and s.personal_data_consent_at is not null
      and s.personal_data_consent_version = '2026-11-17-v1'
      and s.ai_moderation_consent_at is not null
      and s.ai_moderation_consent_version = '2026-11-17-v2'
  ), false);
$function$;