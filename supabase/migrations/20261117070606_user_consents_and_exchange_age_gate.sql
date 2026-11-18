create schema if not exists private;

create table if not exists private.scrl_user_safety (
  user_id uuid primary key references auth.users(id) on delete cascade,
  birth_date date not null,
  personal_data_consent_at timestamptz not null,
  personal_data_consent_version text not null,
  ai_moderation_consent_at timestamptz not null,
  ai_moderation_consent_version text not null,
  parent_exchange_status text not null default 'not_requested'
    check (parent_exchange_status in ('not_requested','pending','approved','rejected','not_required')),
  parent_exchange_requested_at timestamptz,
  parent_exchange_verified_at timestamptz,
  parent_exchange_verified_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint scrl_user_safety_birth_date_valid check (birth_date <= current_date)
);

create table if not exists private.scrl_user_consents (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  consent_type text not null check (consent_type in ('personal_data','ai_moderation','parent_exchange')),
  policy_version text not null,
  accepted_at timestamptz not null default now(),
  verified_by uuid references public.profiles(id) on delete set null,
  unique (user_id, consent_type, policy_version)
);

alter table private.scrl_user_safety enable row level security;
alter table private.scrl_user_safety force row level security;
alter table private.scrl_user_consents enable row level security;
alter table private.scrl_user_consents force row level security;

revoke all on private.scrl_user_safety from public, anon, authenticated, service_role;
revoke all on private.scrl_user_consents from public, anon, authenticated, service_role;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

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
      and s.ai_moderation_consent_at is not null
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

revoke all on function private.scrl_user_can_exchange(uuid) from public, anon;
grant execute on function private.scrl_user_can_exchange(uuid) to authenticated;

create or replace function public.scrl_save_my_safety_data(
  p_birth_date date,
  p_personal_consent boolean,
  p_ai_consent boolean,
  p_personal_version text,
  p_ai_version text
)
returns void
language plpgsql
security definer
set search_path = public, auth, private, pg_temp
as $$
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
     or p_ai_version <> '2026-11-17-v1' then
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
      'parentExchangeStatus', 'not_requested',
      'canUseExchange', false,
      'needsOnboarding', true
    );
  end if;

  v_age := extract(year from age(current_date, v_row.birth_date))::integer;

  return jsonb_build_object(
    'birthDate', v_row.birth_date,
    'ageYears', v_age,
    'hasPersonalDataConsent', v_row.personal_data_consent_at is not null,
    'hasAiConsent', v_row.ai_moderation_consent_at is not null,
    'parentExchangeStatus', case
      when v_age >= 18 then 'not_required'
      when v_age < 14 then 'not_eligible'
      else v_row.parent_exchange_status
    end,
    'canUseExchange', private.scrl_user_can_exchange(auth.uid()),
    'needsOnboarding', (
      v_row.birth_date is null
      or v_row.personal_data_consent_at is null
      or v_row.ai_moderation_consent_at is null
    )
  );
end;
$$;

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
     or v_row.ai_moderation_consent_at is null then
    raise exception 'Сначала прими согласия на странице конфиденциальности.';
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

create or replace function public.scrl_admin_pending_exchange_consents()
returns table (
  user_id uuid,
  full_name text,
  room text,
  age_years integer,
  requested_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, auth, private, pg_temp
as $$
begin
  if not public.scrl_is_admin() then
    raise exception 'Нет доступа.';
  end if;

  return query
  select s.user_id, p.full_name, p.room,
         extract(year from age(current_date, s.birth_date))::integer,
         s.parent_exchange_requested_at
  from private.scrl_user_safety s
  join public.profiles p on p.id = s.user_id
  where s.parent_exchange_status = 'pending'
    and p.deleted_at is null
    and p.blocked = false
    and extract(year from age(current_date, s.birth_date))::integer between 14 and 17
  order by s.parent_exchange_requested_at asc;
end;
$$;

create or replace function public.scrl_admin_review_exchange_parent_consent(
  p_user_id uuid,
  p_decision text
)
returns void
language plpgsql
security definer
set search_path = public, auth, private, pg_temp
as $$
declare
  v_row private.scrl_user_safety%rowtype;
  v_name text;
  v_age integer;
begin
  if not public.scrl_is_admin() then raise exception 'Нет доступа.'; end if;
  if p_decision not in ('approve','reject') then
    raise exception 'Некорректное решение.';
  end if;

  select * into v_row
  from private.scrl_user_safety
  where user_id = p_user_id
  for update;

  if not found or v_row.parent_exchange_status <> 'pending' then
    raise exception 'Заявка уже обработана или не найдена.';
  end if;

  v_age := extract(year from age(current_date, v_row.birth_date))::integer;
  if v_age < 14 or v_age >= 18 then
    raise exception 'Проверять родительское согласие для этого возраста не требуется или биржа недоступна.';
  end if;

  select full_name into v_name
  from public.profiles
  where id = p_user_id and deleted_at is null and blocked = false;

  if not found then raise exception 'Профиль участника недоступен.'; end if;

  update private.scrl_user_safety
  set parent_exchange_status = case when p_decision = 'approve' then 'approved' else 'rejected' end,
      parent_exchange_verified_at = now(),
      parent_exchange_verified_by = auth.uid(),
      updated_at = now()
  where user_id = p_user_id;

  if p_decision = 'approve' then
    insert into private.scrl_user_consents(user_id, consent_type, policy_version, accepted_at, verified_by)
    values (p_user_id, 'parent_exchange', 'parent-exchange-v1', now(), auth.uid())
    on conflict (user_id, consent_type, policy_version) do nothing;
    perform public.scrl_notify(p_user_id, 'Администратор подтвердил родительское согласие. Доступ к бирже открыт.');
  else
    perform public.scrl_notify(p_user_id, 'Администратор пока не подтвердил родительское согласие. Обратись к нему для уточнения.');
  end if;

  insert into public.audit(actor_id, message)
  values (auth.uid(), 'Решение по родительскому согласию биржи (' || p_decision || '): ' || v_name || ' · ' || p_user_id::text);
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
    -- Administrators may anonymize or maintain another profile; enforce consent only
    -- when a user edits their own display name.
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
      and s.ai_moderation_consent_at is not null
  ) then
    raise exception 'Сначала прими согласие на обработку персональных данных и ИИ-проверку.';
  end if;

  return new;
end;
$$;

revoke all on function private.scrl_require_user_consents() from public, anon, authenticated;

drop trigger if exists scrl_require_user_consents_profiles on public.profiles;
create trigger scrl_require_user_consents_profiles
before update of full_name on public.profiles
for each row execute function private.scrl_require_user_consents();

drop trigger if exists scrl_require_user_consents_posts on public.posts;
create trigger scrl_require_user_consents_posts
before insert or update of type, title, description, category, price on public.posts
for each row execute function private.scrl_require_user_consents();

drop trigger if exists scrl_require_user_consents_listings on public.listings;
create trigger scrl_require_user_consents_listings
before insert or update of title, description, category, price, slots on public.listings
for each row execute function private.scrl_require_user_consents();

drop trigger if exists scrl_require_user_consents_auctions on public.auctions;
create trigger scrl_require_user_consents_auctions
before insert or update of title, prize on public.auctions
for each row execute function private.scrl_require_user_consents();

drop trigger if exists scrl_require_user_consents_messages on public.deal_messages;
create trigger scrl_require_user_consents_messages
before insert or update of message on public.deal_messages
for each row execute function private.scrl_require_user_consents();

drop trigger if exists scrl_require_user_consents_reviews on public.reviews;
create trigger scrl_require_user_consents_reviews
before insert or update of text on public.reviews
for each row execute function private.scrl_require_user_consents();

drop trigger if exists scrl_require_user_consents_reports on public.reports;
create trigger scrl_require_user_consents_reports
before insert on public.reports
for each row execute function private.scrl_require_user_consents();

create or replace function private.scrl_guard_exchange_order_access()
returns trigger
language plpgsql
security definer
set search_path = public, auth, private, pg_temp
as $$
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') = 'service_role' then
    return new;
  end if;
  if auth.uid() is null or new.owner_id is distinct from auth.uid() then
    raise exception 'Нельзя выставлять заявки от имени другого участника.';
  end if;
  if not private.scrl_user_can_exchange(new.owner_id) then
    raise exception 'Биржа доступна с 14 лет. Пользователям 14–17 лет нужен подтверждённый администратором допуск с согласия родителей.';
  end if;
  return new;
end;
$$;

create or replace function private.scrl_guard_exchange_trade_access()
returns trigger
language plpgsql
security definer
set search_path = public, auth, private, pg_temp
as $$
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') = 'service_role' then
    return new;
  end if;
  if auth.uid() is null or new.buyer_id is distinct from auth.uid() then
    raise exception 'Покупка биржевого предложения должна выполняться от своего аккаунта.';
  end if;
  if not private.scrl_user_can_exchange(new.buyer_id)
     or not private.scrl_user_can_exchange(new.seller_id) then
    raise exception 'Сделка заблокирована: оба участника должны иметь допуск к бирже.';
  end if;
  return new;
end;
$$;

revoke all on function private.scrl_guard_exchange_order_access() from public, anon, authenticated;
revoke all on function private.scrl_guard_exchange_trade_access() from public, anon, authenticated;

drop trigger if exists scrl_guard_exchange_order_access on public.exchange_orders;
create trigger scrl_guard_exchange_order_access
before insert on public.exchange_orders
for each row execute function private.scrl_guard_exchange_order_access();

drop trigger if exists scrl_guard_exchange_trade_access on public.trades;
create trigger scrl_guard_exchange_trade_access
before insert on public.trades
for each row execute function private.scrl_guard_exchange_trade_access();

drop policy if exists exchange_orders_read on public.exchange_orders;
create policy exchange_orders_read on public.exchange_orders
for select to authenticated
using (
  owner_id = (select auth.uid())
  or public.scrl_is_admin()
  or (status = 'active' and private.scrl_user_can_exchange(owner_id))
);

revoke all on function public.scrl_save_my_safety_data(date, boolean, boolean, text, text) from public, anon;
revoke all on function public.scrl_get_my_safety_status() from public, anon;
revoke all on function public.scrl_request_exchange_parent_consent(boolean) from public, anon;
revoke all on function public.scrl_admin_pending_exchange_consents() from public, anon;
revoke all on function public.scrl_admin_review_exchange_parent_consent(uuid, text) from public, anon;

grant execute on function public.scrl_save_my_safety_data(date, boolean, boolean, text, text) to authenticated;
grant execute on function public.scrl_get_my_safety_status() to authenticated;
grant execute on function public.scrl_request_exchange_parent_consent(boolean) to authenticated;
grant execute on function public.scrl_admin_pending_exchange_consents() to authenticated;
grant execute on function public.scrl_admin_review_exchange_parent_consent(uuid, text) to authenticated;
