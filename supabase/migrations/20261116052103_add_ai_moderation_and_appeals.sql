begin;

create table if not exists public.scrl_moderation_tickets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('post','listing','auction','deal','message','review','profile','report','teacher_issue')),
  payload jsonb not null,
  decision text not null check (decision in ('allow','flag','hide')),
  severity text not null default 'none' check (severity in ('none','low','medium','high','critical')),
  confidence numeric(5,4) not null default 0 check (confidence >= 0 and confidence <= 1),
  categories text[] not null default '{}',
  reason text not null default '',
  case_id uuid,
  expires_at timestamptz not null default (now() + interval '3 minutes'),
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.scrl_moderation_cases (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null,
  source_table text not null check (source_table in ('posts','listings','auctions','deals','deal_messages','reviews','profiles','reports','ledger','prewrite')),
  source_id text,
  decision text not null check (decision in ('flag','hide','ban')),
  severity text not null check (severity in ('low','medium','high','critical')),
  confidence numeric(5,4) not null check (confidence >= 0 and confidence <= 1),
  categories text[] not null default '{}',
  reason text not null,
  evidence jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending','resolved')),
  resolution text not null default '',
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles(id) on delete set null
);

create table if not exists public.scrl_moderation_bans (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  case_id uuid references public.scrl_moderation_cases(id) on delete set null,
  reason text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  appeal_until timestamptz not null default (now() + interval '24 hours'),
  lifted_at timestamptz,
  lifted_by uuid references public.profiles(id) on delete set null
);

create table if not exists public.scrl_moderation_appeals (
  id uuid primary key default gen_random_uuid(),
  ban_id uuid not null references public.scrl_moderation_bans(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  reason text not null check (char_length(reason) between 10 and 1200),
  status text not null default 'pending' check (status in ('pending','accepted','rejected')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles(id) on delete set null,
  decision_note text not null default '',
  unique (ban_id,user_id)
);

create index if not exists scrl_moderation_tickets_lookup_idx
  on public.scrl_moderation_tickets(user_id,kind,created_at desc)
  where consumed_at is null;
create index if not exists scrl_moderation_cases_queue_idx
  on public.scrl_moderation_cases(status,created_at desc);
create index if not exists scrl_moderation_cases_user_idx
  on public.scrl_moderation_cases(user_id,created_at desc);
create index if not exists scrl_moderation_bans_user_idx
  on public.scrl_moderation_bans(user_id,active,created_at desc);
create index if not exists scrl_moderation_appeals_queue_idx
  on public.scrl_moderation_appeals(status,created_at asc);

alter table public.scrl_moderation_tickets enable row level security;
alter table public.scrl_moderation_cases enable row level security;
alter table public.scrl_moderation_bans enable row level security;
alter table public.scrl_moderation_appeals enable row level security;

revoke all on public.scrl_moderation_tickets from anon,authenticated;
revoke all on public.scrl_moderation_cases from anon,authenticated;
revoke all on public.scrl_moderation_bans from anon,authenticated;
revoke all on public.scrl_moderation_appeals from anon,authenticated;
grant all on public.scrl_moderation_tickets to service_role;
grant all on public.scrl_moderation_cases to service_role;
grant all on public.scrl_moderation_bans to service_role;
grant all on public.scrl_moderation_appeals to service_role;
grant select on public.scrl_moderation_cases to authenticated;
grant select on public.scrl_moderation_bans to authenticated;
grant select on public.scrl_moderation_appeals to authenticated;

drop policy if exists scrl_moderation_cases_read_own_admin on public.scrl_moderation_cases;
create policy scrl_moderation_cases_read_own_admin on public.scrl_moderation_cases
  for select to authenticated using (user_id = (select auth.uid()) or public.scrl_is_admin());
drop policy if exists scrl_moderation_bans_read_own_admin on public.scrl_moderation_bans;
create policy scrl_moderation_bans_read_own_admin on public.scrl_moderation_bans
  for select to authenticated using (user_id = (select auth.uid()) or public.scrl_is_admin());
drop policy if exists scrl_moderation_appeals_read_own_admin on public.scrl_moderation_appeals;
create policy scrl_moderation_appeals_read_own_admin on public.scrl_moderation_appeals
  for select to authenticated using (user_id = (select auth.uid()) or public.scrl_is_admin());

alter table public.deal_messages add column if not exists status text not null default 'active';
alter table public.deal_messages drop constraint if exists deal_messages_status_check;
alter table public.deal_messages add constraint deal_messages_status_check check (status in ('active','review','hidden'));

alter table public.reviews add column if not exists status text not null default 'active';
alter table public.reviews drop constraint if exists reviews_status_check;
alter table public.reviews add constraint reviews_status_check check (status in ('active','review','hidden'));

alter table public.auctions drop constraint if exists auctions_status_check;
alter table public.auctions add constraint auctions_status_check
  check (status in ('active','review','hidden','done','settlementError'));

drop policy if exists messages_read_participants on public.deal_messages;
create policy messages_read_participants on public.deal_messages
  for select to authenticated
  using (
    user_id = (select auth.uid())
    or public.scrl_is_admin()
    or (
      status = 'active'
      and exists (
        select 1 from public.deals d
        where d.id = deal_messages.deal_id
          and (d.buyer_id = (select auth.uid()) or d.seller_id = (select auth.uid()))
      )
    )
  );

drop policy if exists reviews_read_authenticated on public.reviews;
create policy reviews_read_authenticated on public.reviews
  for select to authenticated
  using (status = 'active' or user_id = (select auth.uid()) or public.scrl_is_admin());

drop policy if exists auctions_read on public.auctions;
create policy auctions_read on public.auctions
  for select to authenticated
  using (status = 'active' or owner_id = (select auth.uid()) or public.scrl_is_admin());

create or replace function public.scrl_moderation_guard_content()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $function$
declare
  v_uid uuid := auth.uid();
  v_kind text;
  v_payload jsonb;
  v_ticket public.scrl_moderation_tickets%rowtype;
  v_user_id uuid;
begin
  if v_uid is null then
    return new;
  end if;

  if exists (select 1 from public.profiles p where p.id = v_uid and p.blocked) then
    raise exception 'Аккаунт заблокирован.';
  end if;

  case tg_table_name
    when 'posts' then
      v_kind := 'post';
      v_user_id := new.owner_id;
      v_payload := jsonb_build_object(
        'type',new.type,'title',btrim(new.title),'description',btrim(new.description),
        'category',coalesce(nullif(btrim(new.category),''),'Другое'),'price',new.price
      );
    when 'listings' then
      v_kind := 'listing';
      v_user_id := new.owner_id;
      v_payload := jsonb_build_object(
        'title',btrim(new.title),'description',btrim(new.description),
        'category',coalesce(nullif(btrim(new.category),''),'Другое'),
        'price',new.price,'slots',new.slots
      );
    when 'auctions' then
      v_kind := 'auction';
      v_user_id := new.owner_id;
      v_payload := jsonb_build_object(
        'title',btrim(new.title),'prize',btrim(new.prize),
        'start_price',new.start_price,'step',new.step
      );
    when 'deals' then
      v_kind := 'deal';
      v_user_id := v_uid;
      v_payload := jsonb_build_object('title',btrim(new.title));
    when 'deal_messages' then
      v_kind := 'message';
      v_user_id := new.user_id;
      v_payload := jsonb_build_object('deal_id',new.deal_id::text,'message',btrim(new.message));
    when 'reviews' then
      v_kind := 'review';
      v_user_id := new.user_id;
      v_payload := jsonb_build_object(
        'deal_id',new.deal_id::text,'target_id',new.target_id::text,
        'rating',new.rating,'text',btrim(coalesce(new.text,''))
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
      v_payload := jsonb_build_object('full_name',btrim(new.full_name));
    when 'reports' then
      v_kind := 'report';
      v_user_id := new.reporter_id;
      v_payload := jsonb_build_object(
        'kind',new.kind,'target_id',new.target_id,
        'reason',btrim(new.reason),'reason_code',new.reason_code,
        'details',btrim(coalesce(new.details,''))
      );
    when 'ledger' then
      if new.note not like 'Начисление: %' then
        return new;
      end if;
      v_kind := 'teacher_issue';
      v_user_id := new.actor_id;
      v_payload := jsonb_build_object(
        'student_id',new.user_id::text,'amount',new.delta,
        'reason',left(btrim(substring(new.note from length('Начисление: ')+1)),120)
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

  update public.scrl_moderation_tickets set consumed_at = now() where id = v_ticket.id;

  if v_ticket.case_id is not null then
    update public.scrl_moderation_cases
    set source_id = new.id::text,source_table = tg_table_name
    where id = v_ticket.case_id;
  end if;

  if v_ticket.decision in ('flag','hide') then
    case tg_table_name
      when 'posts' then new.status := case when v_ticket.decision='flag' then 'review' else 'hidden' end;
      when 'listings' then new.status := case when v_ticket.decision='flag' then 'review' else 'hidden' end;
      when 'auctions' then new.status := case when v_ticket.decision='flag' then 'review' else 'hidden' end;
      when 'deal_messages' then new.status := case when v_ticket.decision='flag' then 'review' else 'hidden' end;
      when 'reviews' then new.status := case when v_ticket.decision='flag' then 'review' else 'hidden' end;
      when 'profiles' then new.full_name := old.full_name;
      when 'ledger' then new.note := 'Начисление: основание скрыто до проверки';
      else null;
    end case;
  end if;
  return new;
end;
$function$;

revoke all on function public.scrl_moderation_guard_content() from public,anon,authenticated;
grant execute on function public.scrl_moderation_guard_content() to service_role;

drop trigger if exists scrl_moderation_guard_posts on public.posts;
create trigger scrl_moderation_guard_posts before insert or update of type,title,description,category,price
  on public.posts for each row execute function public.scrl_moderation_guard_content();
drop trigger if exists scrl_moderation_guard_listings on public.listings;
create trigger scrl_moderation_guard_listings before insert or update of title,description,category,price,slots
  on public.listings for each row execute function public.scrl_moderation_guard_content();
drop trigger if exists scrl_moderation_guard_auctions on public.auctions;
create trigger scrl_moderation_guard_auctions before insert or update of title,prize
  on public.auctions for each row execute function public.scrl_moderation_guard_content();
drop trigger if exists scrl_moderation_guard_deals on public.deals;
create trigger scrl_moderation_guard_deals before insert or update of title
  on public.deals for each row execute function public.scrl_moderation_guard_content();
drop trigger if exists scrl_moderation_guard_messages on public.deal_messages;
create trigger scrl_moderation_guard_messages before insert or update of message
  on public.deal_messages for each row execute function public.scrl_moderation_guard_content();
drop trigger if exists scrl_moderation_guard_reviews on public.reviews;
create trigger scrl_moderation_guard_reviews before insert or update of text
  on public.reviews for each row execute function public.scrl_moderation_guard_content();
drop trigger if exists scrl_moderation_guard_profiles on public.profiles;
create trigger scrl_moderation_guard_profiles before update of full_name
  on public.profiles for each row execute function public.scrl_moderation_guard_content();
drop trigger if exists scrl_moderation_guard_reports on public.reports;
create trigger scrl_moderation_guard_reports before insert
  on public.reports for each row execute function public.scrl_moderation_guard_content();
drop trigger if exists scrl_moderation_guard_ledger on public.ledger;
create trigger scrl_moderation_guard_ledger before insert
  on public.ledger for each row execute function public.scrl_moderation_guard_content();

create or replace function public.scrl_reject_blocked_actor_write()
returns trigger
language plpgsql
security definer
set search_path = public,auth,pg_temp
as $function$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is not null and exists (select 1 from public.profiles p where p.id=v_uid and p.blocked) then
    raise exception 'Аккаунт заблокирован. Для обжалования используй форму апелляции.';
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$function$;

revoke all on function public.scrl_reject_blocked_actor_write() from public,anon,authenticated;
grant execute on function public.scrl_reject_blocked_actor_write() to service_role;

drop trigger if exists scrl_blocked_actor_profiles on public.profiles;
create trigger scrl_blocked_actor_profiles before insert or update or delete on public.profiles for each row execute function public.scrl_reject_blocked_actor_write();
drop trigger if exists scrl_blocked_actor_wallets on public.wallets;
create trigger scrl_blocked_actor_wallets before insert or update or delete on public.wallets for each row execute function public.scrl_reject_blocked_actor_write();
drop trigger if exists scrl_blocked_actor_posts on public.posts;
create trigger scrl_blocked_actor_posts before insert or update or delete on public.posts for each row execute function public.scrl_reject_blocked_actor_write();
drop trigger if exists scrl_blocked_actor_listings on public.listings;
create trigger scrl_blocked_actor_listings before insert or update or delete on public.listings for each row execute function public.scrl_reject_blocked_actor_write();
drop trigger if exists scrl_blocked_actor_deals on public.deals;
create trigger scrl_blocked_actor_deals before insert or update or delete on public.deals for each row execute function public.scrl_reject_blocked_actor_write();
drop trigger if exists scrl_blocked_actor_messages on public.deal_messages;
create trigger scrl_blocked_actor_messages before insert or update or delete on public.deal_messages for each row execute function public.scrl_reject_blocked_actor_write();
drop trigger if exists scrl_blocked_actor_orders on public.exchange_orders;
create trigger scrl_blocked_actor_orders before insert or update or delete on public.exchange_orders for each row execute function public.scrl_reject_blocked_actor_write();
drop trigger if exists scrl_blocked_actor_trades on public.trades;
create trigger scrl_blocked_actor_trades before insert or update or delete on public.trades for each row execute function public.scrl_reject_blocked_actor_write();
drop trigger if exists scrl_blocked_actor_auctions on public.auctions;
create trigger scrl_blocked_actor_auctions before insert or update or delete on public.auctions for each row execute function public.scrl_reject_blocked_actor_write();
drop trigger if exists scrl_blocked_actor_bids on public.bids;
create trigger scrl_blocked_actor_bids before insert or update or delete on public.bids for each row execute function public.scrl_reject_blocked_actor_write();
drop trigger if exists scrl_blocked_actor_favorites on public.favorites;
create trigger scrl_blocked_actor_favorites before insert or update or delete on public.favorites for each row execute function public.scrl_reject_blocked_actor_write();
drop trigger if exists scrl_blocked_actor_ledger on public.ledger;
create trigger scrl_blocked_actor_ledger before insert or update or delete on public.ledger for each row execute function public.scrl_reject_blocked_actor_write();
drop trigger if exists scrl_blocked_actor_reviews on public.reviews;
create trigger scrl_blocked_actor_reviews before insert or update or delete on public.reviews for each row execute function public.scrl_reject_blocked_actor_write();
drop trigger if exists scrl_blocked_actor_reports on public.reports;
create trigger scrl_blocked_actor_reports before insert or update or delete on public.reports for each row execute function public.scrl_reject_blocked_actor_write();
drop trigger if exists scrl_blocked_actor_notifications on public.notifications;
create trigger scrl_blocked_actor_notifications before insert or update or delete on public.notifications for each row execute function public.scrl_reject_blocked_actor_write();
drop trigger if exists scrl_blocked_actor_activity on public.activity;
create trigger scrl_blocked_actor_activity before insert or update or delete on public.activity for each row execute function public.scrl_reject_blocked_actor_write();
drop trigger if exists scrl_blocked_actor_audit on public.audit;
create trigger scrl_blocked_actor_audit before insert or update or delete on public.audit for each row execute function public.scrl_reject_blocked_actor_write();
drop trigger if exists scrl_blocked_actor_issuance on public.teacher_issuance;
create trigger scrl_blocked_actor_issuance before insert or update or delete on public.teacher_issuance for each row execute function public.scrl_reject_blocked_actor_write();

drop trigger if exists scrl_protect_profile_security_fields on public.profiles;
create or replace function public.scrl_protect_profile_security_fields()
returns trigger
language plpgsql
security definer
set search_path = public,auth,pg_temp
as $function$
begin
  if auth.uid() is not null and auth.uid()=old.id and not public.scrl_is_admin()
     and (new.role is distinct from old.role or new.blocked is distinct from old.blocked or new.block_reason is distinct from old.block_reason) then
    raise exception 'Роль и блокировку меняет только администратор.';
  end if;
  return new;
end;
$function$;
revoke all on function public.scrl_protect_profile_security_fields() from public,anon,authenticated;
grant execute on function public.scrl_protect_profile_security_fields() to service_role;
create trigger scrl_protect_profile_security_fields before update of role,blocked,block_reason
  on public.profiles for each row execute function public.scrl_protect_profile_security_fields();

create or replace function public.scrl_handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public,auth,pg_temp
as $function$
begin
  insert into public.profiles(id,full_name,role)
    values (new.id,'Участник','student') on conflict (id) do nothing;
  insert into public.wallets(user_id,scrl,vrub)
    values (new.id,100,50) on conflict (user_id) do nothing;
  insert into public.ledger(user_id,currency,delta,note) values
    (new.id,'ScRl',100,'Стартовый баланс'),
    (new.id,'V-RUB',50,'Стартовый виртуальный баланс');
  return new;
end;
$function$;

commit;
