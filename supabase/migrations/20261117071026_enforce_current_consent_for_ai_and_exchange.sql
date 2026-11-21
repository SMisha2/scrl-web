create or replace function private.scrl_user_can_exchange(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public, auth, private, pg_temp
as $$
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
      and s.ai_moderation_consent_version = '2026-11-17-v1'
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
$$;

create or replace function public.scrl_get_my_safety_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, private, pg_temp
as $$
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
    and v_row.ai_moderation_consent_version = '2026-11-17-v1';

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
$$;

create or replace function private.scrl_require_user_consents()
returns trigger
language plpgsql
security definer
set search_path = public, auth, private, pg_temp
as $$
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
      and s.ai_moderation_consent_version = '2026-11-17-v1'
  ) then
    raise exception 'Сначала прими актуальное согласие на обработку персональных данных и ИИ-проверку.';
  end if;

  return new;
end;
$$;

create or replace function public.scrl_has_ai_processing_consent(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, private, pg_temp
as $$
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
      and s.ai_moderation_consent_version = '2026-11-17-v1'
  ), false);
$$;

revoke all on function public.scrl_has_ai_processing_consent(uuid) from public, anon, authenticated;
grant execute on function public.scrl_has_ai_processing_consent(uuid) to service_role;
