create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default 'Участник' check (char_length(full_name) between 1 and 100),
  room text not null default '' check (char_length(room) <= 12),
  role text not null default 'student' check (role in ('student','teacher','admin')),
  blocked boolean not null default false,
  block_reason text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.wallets (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  scrl numeric(14,2) not null default 0 check (scrl >= 0),
  vrub numeric(14,2) not null default 0 check (vrub >= 0),
  hold_scrl numeric(14,2) not null default 0 check (hold_scrl >= 0),
  hold_vrub numeric(14,2) not null default 0 check (hold_vrub >= 0),
  updated_at timestamptz not null default now()
);

create table if not exists public.ledger (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  currency text not null check (currency in ('ScRl','V-RUB')),
  delta numeric(14,2) not null,
  note text not null default '',
  actor_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists ledger_user_created_idx on public.ledger(user_id, created_at desc);

create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  type text not null check (type in ('need','offer')),
  title text not null check (char_length(title) between 1 and 100),
  description text not null check (char_length(description) between 1 and 1500),
  category text not null default 'Другое',
  price numeric(12,2) not null default 0 check (price between 0 and 500),
  owner_id uuid not null references public.profiles(id) on delete restrict,
  status text not null default 'active' check (status in ('active','review','closed','hidden')),
  created_at timestamptz not null default now()
);
create index if not exists posts_feed_idx on public.posts(status, created_at desc);

create table if not exists public.listings (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 100),
  description text not null check (char_length(description) between 1 and 1500),
  category text not null default 'Другое',
  price numeric(12,2) not null check (price between 1 and 500),
  slots integer not null default 1 check (slots between 0 and 10),
  owner_id uuid not null references public.profiles(id) on delete restrict,
  status text not null default 'active' check (status in ('active','review','sold','closed','hidden')),
  created_at timestamptz not null default now()
);
create index if not exists listings_feed_idx on public.listings(status, created_at desc);

create table if not exists public.deals (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  buyer_id uuid not null references public.profiles(id) on delete restrict,
  seller_id uuid not null references public.profiles(id) on delete restrict,
  amount numeric(14,2) not null check (amount between 0 and 500),
  escrow numeric(14,2) not null default 0 check (escrow >= 0),
  source text not null default '',
  source_id text not null default '',
  status text not null default 'work' check (status in ('work','ready','dispute','done','refund')),
  created_at timestamptz not null default now(),
  closed_at timestamptz,
  check (buyer_id <> seller_id)
);
create index if not exists deals_buyer_idx on public.deals(buyer_id, created_at desc);
create index if not exists deals_seller_idx on public.deals(seller_id, created_at desc);

create table if not exists public.deal_messages (
  id uuid primary key default gen_random_uuid(),
  deal_id uuid not null references public.deals(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete restrict,
  message text not null check (char_length(message) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index if not exists deal_messages_deal_idx on public.deal_messages(deal_id, created_at);

create table if not exists public.exchange_orders (
  id uuid primary key default gen_random_uuid(),
  side text not null check (side in ('scrlSell','vrubSell')),
  owner_id uuid not null references public.profiles(id) on delete restrict,
  amount numeric(14,2) not null check (amount > 0),
  price numeric(14,4) not null check (price between 0.0001 and 10000),
  status text not null default 'active' check (status in ('active','filled','cancelled')),
  buyer_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  filled_at timestamptz,
  cancelled_at timestamptz
);
create index if not exists exchange_orders_feed_idx on public.exchange_orders(status, created_at desc);

create table if not exists public.trades (
  id uuid primary key default gen_random_uuid(),
  buyer_id uuid not null references public.profiles(id) on delete restrict,
  seller_id uuid not null references public.profiles(id) on delete restrict,
  qty numeric(14,2) not null,
  price numeric(14,6) not null,
  amount_scrl numeric(14,2) not null,
  amount_vrub numeric(14,2) not null,
  fee numeric(14,2) not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.auctions (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 100),
  prize text not null check (char_length(prize) between 1 and 250),
  start_price numeric(14,2) not null check (start_price between 1 and 1000000),
  step numeric(14,2) not null check (step between 1 and 1000000),
  current_bid numeric(14,2) not null default 0,
  leader_id uuid references public.profiles(id) on delete set null,
  owner_id uuid not null references public.profiles(id) on delete restrict,
  ends_at timestamptz not null,
  status text not null default 'active' check (status in ('active','done','settlementError')),
  bids_count integer not null default 0,
  created_at timestamptz not null default now(),
  closed_at timestamptz
);
create index if not exists auctions_feed_idx on public.auctions(status, ends_at);

create table if not exists public.bids (
  id uuid primary key default gen_random_uuid(),
  auction_id uuid not null references public.auctions(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete restrict,
  amount numeric(14,2) not null check (amount > 0),
  status text not null default 'active' check (status in ('active','outbid','raised','won')),
  created_at timestamptz not null default now()
);
create index if not exists bids_auction_idx on public.bids(auction_id, created_at desc);

create table if not exists public.favorites (
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('post','listing')),
  target_id text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, kind, target_id)
);

create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  kind text not null,
  target_id text not null,
  reporter_id uuid not null references public.profiles(id) on delete restrict,
  reason text not null,
  reason_code text not null default 'other',
  details text not null default '',
  status text not null default 'open' check (status in ('open','kept','hidden','resolved')),
  created_at timestamptz not null default now()
);
create index if not exists reports_status_idx on public.reports(status, created_at desc);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  message text not null check (char_length(message) between 1 and 300),
  seen boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists notifications_user_idx on public.notifications(user_id, created_at desc);

create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  deal_id uuid not null references public.deals(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete restrict,
  target_id uuid not null references public.profiles(id) on delete restrict,
  rating integer not null check (rating between 1 and 5),
  text text not null default '' check (char_length(text) <= 1000),
  created_at timestamptz not null default now(),
  unique (deal_id, user_id),
  check (user_id <> target_id)
);

create table if not exists public.activity (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  message text not null check (char_length(message) between 1 and 300),
  created_at timestamptz not null default now()
);
create index if not exists activity_user_idx on public.activity(user_id, created_at desc);

create table if not exists public.audit (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references public.profiles(id) on delete set null,
  message text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.teacher_issuance (
  teacher_id uuid not null references public.profiles(id) on delete cascade,
  week_start date not null,
  amount integer not null default 0 check (amount between 0 and 500),
  primary key (teacher_id, week_start)
);

create table if not exists public.platform_settings (
  singleton boolean primary key default true check (singleton),
  target_rate numeric(12,4) not null default 0.05 check (target_rate between 0.001 and 1),
  fee_rate numeric(8,6) not null default 0.01 check (fee_rate between 0 and 0.2),
  fees_scrl numeric(14,2) not null default 0,
  burned_scrl numeric(14,2) not null default 0,
  updated_at timestamptz not null default now()
);
insert into public.platform_settings(singleton) values (true) on conflict do nothing;

create or replace function public.scrl_is_admin()
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists(select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin' and not p.blocked);
$$;
revoke all on function public.scrl_is_admin() from public;
grant execute on function public.scrl_is_admin() to authenticated;

create or replace function public.scrl_notify(p_user uuid, p_message text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if p_user is null or p_message is null or char_length(p_message) = 0 then return; end if;
  insert into public.notifications(user_id, message)
  values (p_user, left(p_message, 300));
end;
$$;

create or replace function public.scrl_log(p_user uuid, p_message text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if p_user is null or p_message is null or char_length(p_message) = 0 then return; end if;
  insert into public.activity(user_id, message) values (p_user, left(p_message, 300));
end;
$$;

create or replace function public.scrl_current_fee()
returns numeric
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_tokens numeric;
  v_vrub numeric;
  v_rate numeric;
  v_ratio numeric;
begin
  select target_rate into v_rate from public.platform_settings where singleton = true;
  select coalesce(sum(scrl + hold_scrl),0), coalesce(sum(vrub + hold_vrub),0)
    into v_tokens, v_vrub from public.wallets;
  if v_rate is null or v_rate <= 0 or v_tokens <= 0 then return 0.01; end if;
  v_ratio := v_vrub / (v_tokens * v_rate);
  if v_ratio < 1 then return least(0.2, greatest(0, 0.005 + (1 - v_ratio) * 0.2)); end if;
  if v_ratio < 2 then return greatest(0, 0.005 * (2 - v_ratio)); end if;
  return 0;
end;
$$;

create or replace function public.scrl_handle_new_user()
returns trigger
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_name text;
begin
  v_name := coalesce(nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''), split_part(coalesce(new.email,''),'@',1), 'Участник');
  insert into public.profiles(id, full_name) values (new.id, left(v_name,100)) on conflict (id) do nothing;
  insert into public.wallets(user_id, scrl, vrub) values (new.id, 100, 50) on conflict (user_id) do nothing;
  insert into public.ledger(user_id, currency, delta, note) values
    (new.id, 'ScRl', 100, 'Стартовый баланс'),
    (new.id, 'V-RUB', 50, 'Стартовый виртуальный баланс');
  return new;
end;
$$;

drop trigger if exists scrl_auth_user_created on auth.users;
create trigger scrl_auth_user_created
after insert on auth.users
for each row execute function public.scrl_handle_new_user();

create or replace function public.scrl_claim_initial_admin()
returns boolean
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_count integer;
  v_admins integer;
begin
  if auth.uid() is null then raise exception 'Требуется вход.'; end if;
  perform pg_advisory_xact_lock(hashtext('scrl_initial_admin'));
  select count(*) into v_count from public.profiles;
  select count(*) into v_admins from public.profiles where role = 'admin';
  if v_count <> 1 or v_admins <> 0 or not exists(select 1 from public.profiles where id = auth.uid()) then
    return false;
  end if;
  update public.profiles set role = 'admin', updated_at = now() where id = auth.uid();
  insert into public.audit(actor_id, message) values (auth.uid(), 'Назначен первый администратор проекта.');
  return true;
end;
$$;

create or replace function public.scrl_create_deal(
  p_title text, p_buyer uuid, p_seller uuid, p_amount numeric, p_source text default '', p_source_id text default ''
)
returns uuid
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_id uuid;
  v_buyer public.wallets%rowtype;
  v_post public.posts%rowtype;
  v_listing public.listings%rowtype;
begin
  if auth.uid() is null then raise exception 'Требуется вход.'; end if;
  if length(trim(coalesce(p_title,''))) = 0 or length(p_title) > 120 then raise exception 'Некорректное название сделки.'; end if;
  if p_amount < 0 or p_amount > 500 then raise exception 'Некорректная сумма.'; end if;
  if p_buyer = p_seller then raise exception 'Нельзя создать сделку с самим собой.'; end if;
  if exists(select 1 from public.profiles where id in (p_buyer,p_seller) and blocked) then raise exception 'Аккаунт заблокирован.'; end if;
  if not exists(select 1 from public.profiles where id=p_buyer) or not exists(select 1 from public.profiles where id=p_seller) then raise exception 'Участник не найден.'; end if;

  if p_source = 'market' then
    select * into v_listing from public.listings where id::text = p_source_id and status='active' for update;
    if not found or v_listing.owner_id <> p_seller or p_buyer <> auth.uid() then raise exception 'Услуга больше недоступна.'; end if;
    if v_listing.slots < 1 then raise exception 'Свободные места закончились.'; end if;
    update public.listings set slots=slots-1, status=case when slots-1 <= 0 then 'sold' else status end where id=v_listing.id;
  elsif p_source = 'board' then
    select * into v_post from public.posts where id::text = p_source_id and status='active' for update;
    if not found then raise exception 'Публикация больше недоступна.'; end if;
    if v_post.type='need' and not (p_buyer=v_post.owner_id and p_seller=auth.uid()) then raise exception 'Неверные участники отклика.'; end if;
    if v_post.type='offer' and not (p_seller=v_post.owner_id and p_buyer=auth.uid()) then raise exception 'Неверные участники отклика.'; end if;
  else
    raise exception 'Неизвестный источник сделки.';
  end if;

  select * into v_buyer from public.wallets where user_id=p_buyer for update;
  if not found or v_buyer.scrl < p_amount then raise exception 'Недостаточно ScRl для резерва.'; end if;
  update public.wallets set scrl=scrl-p_amount, hold_scrl=hold_scrl+p_amount, updated_at=now() where user_id=p_buyer;
  insert into public.ledger(user_id,currency,delta,note,actor_id)
    values(p_buyer,'ScRl',-p_amount,'Резерв по сделке: '||left(p_title,100),auth.uid());
  insert into public.deals(title,buyer_id,seller_id,amount,escrow,source,source_id)
    values(left(trim(p_title),120),p_buyer,p_seller,p_amount,p_amount,p_source,p_source_id)
    returning id into v_id;
  perform public.scrl_notify(p_buyer,'Создана сделка: '||left(p_title,100));
  perform public.scrl_notify(p_seller,'Тебе поступил заказ: '||left(p_title,100));
  perform public.scrl_log(auth.uid(),'Создана сделка «'||left(p_title,100)||'».');
  return v_id;
end;
$$;

create or replace function public.scrl_deal_action(p_deal uuid, p_action text, p_share numeric default 1)
returns void
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_deal public.deals%rowtype;
  v_fee_rate numeric;
  v_fee numeric;
  v_gross numeric;
  v_seller numeric;
  v_buyer numeric;
begin
  if auth.uid() is null then raise exception 'Требуется вход.'; end if;
  select * into v_deal from public.deals where id=p_deal for update;
  if not found then raise exception 'Сделка не найдена.'; end if;

  if p_action='delivered' then
    if auth.uid() <> v_deal.seller_id or v_deal.status <> 'work' then raise exception 'Нельзя отметить выполнение этой сделки.'; end if;
    update public.deals set status='ready' where id=p_deal;
    perform public.scrl_notify(v_deal.buyer_id,'Исполнитель отметил заказ как выполненный.');
    perform public.scrl_log(auth.uid(),'Отмечено выполнение заказа «'||left(v_deal.title,100)||'».');
    return;
  elsif p_action='dispute' then
    if auth.uid() not in (v_deal.buyer_id,v_deal.seller_id) or v_deal.status not in ('work','ready') then raise exception 'Нельзя открыть спор по этой сделке.'; end if;
    update public.deals set status='dispute' where id=p_deal;
    insert into public.reports(kind,target_id,reporter_id,reason,reason_code)
      values('deal',p_deal::text,auth.uid(),'Спор по сделке «'||left(v_deal.title,100)||'»','deal');
    perform public.scrl_notify(v_deal.buyer_id,'Открыт спор по сделке.');
    perform public.scrl_notify(v_deal.seller_id,'Открыт спор по сделке.');
    perform public.scrl_log(auth.uid(),'Открыт спор по сделке «'||left(v_deal.title,100)||'».');
    return;
  end if;

  if p_action not in ('confirm','refund','pay','split') then raise exception 'Неизвестное действие.'; end if;
  if p_action='confirm' then
    if auth.uid() <> v_deal.buyer_id or v_deal.status <> 'ready' then raise exception 'Сначала исполнитель должен отметить выполнение.'; end if;
    p_action := 'pay';
  elsif not public.scrl_is_admin() then
    raise exception 'Нет доступа.';
  end if;
  if v_deal.status not in ('ready','dispute','work') then raise exception 'Сделка уже завершена.'; end if;
  if v_deal.escrow <= 0 then
    update public.deals set status=case when p_action='refund' then 'refund' else 'done' end, closed_at=now() where id=p_deal;
    return;
  end if;

  if p_action='refund' then
    v_gross := 0; v_fee := 0; v_seller := 0; v_buyer := v_deal.escrow;
  else
    select fee_rate into v_fee_rate from public.platform_settings where singleton=true;
    v_gross := case when p_action='split' then round(v_deal.escrow * least(1,greatest(0,coalesce(p_share,0.5))),2) else v_deal.escrow end;
    v_fee := round(v_gross * coalesce(v_fee_rate,0.01),2);
    v_seller := v_gross - v_fee;
    v_buyer := v_deal.escrow - v_gross;
  end if;
  update public.wallets set hold_scrl=greatest(0,hold_scrl-v_deal.escrow), updated_at=now() where user_id=v_deal.buyer_id;
  if v_seller > 0 then
    update public.wallets set scrl=scrl+v_seller, updated_at=now() where user_id=v_deal.seller_id;
    insert into public.ledger(user_id,currency,delta,note,actor_id) values(v_deal.seller_id,'ScRl',v_seller,'Оплата по сделке: '||left(v_deal.title,100),auth.uid());
  end if;
  if v_buyer > 0 then
    update public.wallets set scrl=scrl+v_buyer, updated_at=now() where user_id=v_deal.buyer_id;
    insert into public.ledger(user_id,currency,delta,note,actor_id) values(v_deal.buyer_id,'ScRl',v_buyer,'Возврат по сделке: '||left(v_deal.title,100),auth.uid());
  end if;
  update public.platform_settings set fees_scrl=fees_scrl+v_fee, burned_scrl=burned_scrl+v_fee, updated_at=now() where singleton=true;
  update public.deals set escrow=0, status=case when p_action='refund' then 'refund' else 'done' end, closed_at=now() where id=p_deal;
  perform public.scrl_notify(v_deal.buyer_id,'Сделка «'||left(v_deal.title,100)||'» завершена.');
  perform public.scrl_notify(v_deal.seller_id,'Сделка «'||left(v_deal.title,100)||'» завершена.');
  perform public.scrl_log(auth.uid(),'Сделка «'||left(v_deal.title,100)||'» завершена.');
end;
$$;

create or replace function public.scrl_send_message(p_deal uuid, p_message text)
returns uuid
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare v_id uuid; v_other uuid; v_title text;
begin
  if auth.uid() is null then raise exception 'Требуется вход.'; end if;
  if length(trim(coalesce(p_message,'')))=0 or length(p_message)>2000 then raise exception 'Сообщение пустое или слишком длинное.'; end if;
  select case when buyer_id=auth.uid() then seller_id else buyer_id end, title
    into v_other,v_title from public.deals
    where id=p_deal and auth.uid() in (buyer_id,seller_id) and status in ('work','ready','dispute');
  if not found then raise exception 'Нет доступа к переписке.'; end if;
  insert into public.deal_messages(deal_id,user_id,message) values(p_deal,auth.uid(),trim(p_message)) returning id into v_id;
  perform public.scrl_notify(v_other,'Новое сообщение по сделке «'||left(v_title,80)||'».');
  return v_id;
end;
$$;

create or replace function public.scrl_place_exchange_order(p_side text, p_amount numeric, p_price numeric)
returns uuid
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare v_wallet public.wallets%rowtype; v_id uuid;
begin
  if auth.uid() is null then raise exception 'Требуется вход.'; end if;
  if p_side not in ('scrlSell','vrubSell') or p_amount < 1 or p_amount > 1000000 or trunc(p_amount)<>p_amount or p_price < 0.0001 or p_price > 10000 then
    raise exception 'Проверь количество и цену.';
  end if;
  if exists(select 1 from public.profiles where id=auth.uid() and blocked) then raise exception 'Аккаунт заблокирован.'; end if;
  select * into v_wallet from public.wallets where user_id=auth.uid() for update;
  if p_side='scrlSell' then
    if v_wallet.scrl < p_amount then raise exception 'Не хватает ScRl для резерва.'; end if;
    update public.wallets set scrl=scrl-p_amount, hold_scrl=hold_scrl+p_amount, updated_at=now() where user_id=auth.uid();
    insert into public.ledger(user_id,currency,delta,note,actor_id) values(auth.uid(),'ScRl',-p_amount,'Резерв заявки: продажа ScRl',auth.uid());
  else
    if v_wallet.vrub < p_amount then raise exception 'Не хватает V-RUB для резерва.'; end if;
    update public.wallets set vrub=vrub-p_amount, hold_vrub=hold_vrub+p_amount, updated_at=now() where user_id=auth.uid();
    insert into public.ledger(user_id,currency,delta,note,actor_id) values(auth.uid(),'V-RUB',-p_amount,'Резерв заявки: продажа V-RUB',auth.uid());
  end if;
  insert into public.exchange_orders(side,owner_id,amount,price) values(p_side,auth.uid(),p_amount,p_price) returning id into v_id;
  perform public.scrl_log(auth.uid(),'Выставлена заявка на бирже.');
  return v_id;
end;
$$;

create or replace function public.scrl_buy_exchange_order(p_order uuid)
returns void
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_order public.exchange_orders%rowtype;
  v_seller_wallet public.wallets%rowtype;
  v_buyer_wallet public.wallets%rowtype;
  v_qty numeric;
  v_cost numeric;
  v_fee_rate numeric;
  v_fee numeric;
  v_scrl numeric;
  v_vrub numeric;
begin
  if auth.uid() is null then raise exception 'Требуется вход.'; end if;
  select * into v_order from public.exchange_orders where id=p_order and status='active' for update;
  if not found then raise exception 'Предложение уже недоступно.'; end if;
  if v_order.owner_id=auth.uid() then raise exception 'Нельзя купить собственное предложение.'; end if;
  if exists(select 1 from public.profiles where id in (auth.uid(),v_order.owner_id) and blocked) then raise exception 'Один из участников заблокирован.'; end if;
  select * into v_seller_wallet from public.wallets where user_id=v_order.owner_id for update;
  select * into v_buyer_wallet from public.wallets where user_id=auth.uid() for update;
  v_qty := v_order.amount;
  v_cost := round(v_qty*v_order.price,2);
  select fee_rate into v_fee_rate from public.platform_settings where singleton=true;
  if v_order.side='scrlSell' then
    if v_seller_wallet.hold_scrl < v_qty then raise exception 'Резерв ScRl не найден.'; end if;
    if v_buyer_wallet.vrub < v_cost then raise exception 'Не хватает V-RUB для покупки ScRl.'; end if;
    v_fee := round(v_qty*coalesce(v_fee_rate,0.01),2);
    update public.wallets set vrub=vrub-v_cost, scrl=scrl+round(greatest(0,v_qty-v_fee),2), updated_at=now() where user_id=auth.uid();
    update public.wallets set hold_scrl=hold_scrl-v_qty, vrub=vrub+v_cost, updated_at=now() where user_id=v_order.owner_id;
    v_scrl := round(greatest(0,v_qty-v_fee),2); v_vrub := v_cost;
    insert into public.ledger(user_id,currency,delta,note,actor_id) values
      (auth.uid(),'V-RUB',-v_cost,'Покупка ScRl на бирже',auth.uid()),
      (auth.uid(),'ScRl',v_scrl,'Получено ScRl на бирже',auth.uid()),
      (v_order.owner_id,'V-RUB',v_cost,'Продажа ScRl на бирже',auth.uid());
  else
    if v_seller_wallet.hold_vrub < v_qty then raise exception 'Резерв V-RUB не найден.'; end if;
    if v_buyer_wallet.scrl < v_cost then raise exception 'Не хватает ScRl для покупки V-RUB.'; end if;
    v_fee := round(v_cost*coalesce(v_fee_rate,0.01),2);
    update public.wallets set scrl=scrl-v_cost, vrub=vrub+v_qty, updated_at=now() where user_id=auth.uid();
    update public.wallets set hold_vrub=hold_vrub-v_qty, scrl=scrl+round(greatest(0,v_cost-v_fee),2), updated_at=now() where user_id=v_order.owner_id;
    v_scrl := v_cost; v_vrub := v_qty;
    insert into public.ledger(user_id,currency,delta,note,actor_id) values
      (auth.uid(),'ScRl',-v_cost,'Покупка V-RUB на бирже',auth.uid()),
      (auth.uid(),'V-RUB',v_qty,'Получено V-RUB на бирже',auth.uid()),
      (v_order.owner_id,'ScRl',round(greatest(0,v_cost-v_fee),2),'Продажа V-RUB на бирже',auth.uid());
  end if;
  update public.platform_settings set fees_scrl=fees_scrl+v_fee,burned_scrl=burned_scrl+v_fee,updated_at=now() where singleton=true;
  update public.exchange_orders set status='filled',buyer_id=auth.uid(),filled_at=now() where id=p_order;
  insert into public.trades(buyer_id,seller_id,qty,price,amount_scrl,amount_vrub,fee)
    values(auth.uid(),v_order.owner_id,v_scrl,case when v_scrl>0 then round(v_vrub/v_scrl,6) else 0 end,v_scrl,v_vrub,v_fee);
  perform public.scrl_notify(v_order.owner_id,'Твоё предложение на бирже купили.');
  perform public.scrl_notify(auth.uid(),'Обмен завершён.');
  perform public.scrl_log(auth.uid(),'Обмен на бирже завершён.');
end;
$$;

create or replace function public.scrl_cancel_exchange_order(p_order uuid)
returns void
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare v_order public.exchange_orders%rowtype;
begin
  select * into v_order from public.exchange_orders where id=p_order and status='active' and owner_id=auth.uid() for update;
  if not found then raise exception 'Активная заявка не найдена.'; end if;
  if v_order.side='scrlSell' then
    update public.wallets set hold_scrl=hold_scrl-v_order.amount,scrl=scrl+v_order.amount,updated_at=now() where user_id=auth.uid();
    insert into public.ledger(user_id,currency,delta,note,actor_id) values(auth.uid(),'ScRl',v_order.amount,'Возврат резерва заявки биржи',auth.uid());
  else
    update public.wallets set hold_vrub=hold_vrub-v_order.amount,vrub=vrub+v_order.amount,updated_at=now() where user_id=auth.uid();
    insert into public.ledger(user_id,currency,delta,note,actor_id) values(auth.uid(),'V-RUB',v_order.amount,'Возврат резерва заявки биржи',auth.uid());
  end if;
  update public.exchange_orders set status='cancelled',cancelled_at=now() where id=p_order;
end;
$$;

create or replace function public.scrl_create_auction(p_title text,p_prize text,p_start numeric,p_step numeric,p_minutes integer)
returns uuid
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare v_id uuid; v_role text;
begin
  select role into v_role from public.profiles where id=auth.uid() and not blocked;
  if v_role not in ('teacher','admin') then raise exception 'Создавать аукционы могут учителя и администраторы.'; end if;
  if length(trim(p_title)) not between 1 and 100 or length(trim(p_prize)) not between 1 and 250 or p_start not between 1 and 1000000 or p_step not between 1 and 1000000 or p_minutes not between 1 and 10080 then
    raise exception 'Проверь данные аукциона.';
  end if;
  if p_prize ~* '(руб|рубл|деньг|денеж|налич|перевод|оплат|usd|eur|cash|dollar|банковск|[₽€$])' then raise exception 'Приз должен быть неденежным.'; end if;
  insert into public.auctions(title,prize,start_price,step,owner_id,ends_at)
    values(trim(p_title),trim(p_prize),p_start,p_step,auth.uid(),now()+make_interval(mins=>p_minutes)) returning id into v_id;
  perform public.scrl_log(auth.uid(),'Создан аукцион «'||left(p_title,100)||'».');
  return v_id;
end;
$$;

create or replace function public.scrl_place_bid(p_auction uuid,p_amount numeric)
returns void
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_auction public.auctions%rowtype;
  v_wallet public.wallets%rowtype;
  v_old public.wallets%rowtype;
  v_min numeric;
begin
  if (select role from public.profiles where id=auth.uid() and not blocked) <> 'student' then raise exception 'Ставки доступны ученикам.'; end if;
  select * into v_auction from public.auctions where id=p_auction and status='active' and ends_at>now() for update;
  if not found or v_auction.owner_id=auth.uid() then raise exception 'Этот аукцион уже закрыт или принадлежит тебе.'; end if;
  v_min := case when v_auction.current_bid>0 then v_auction.current_bid+v_auction.step else v_auction.start_price end;
  if p_amount < v_min or p_amount > 1000000 or trunc(p_amount)<>p_amount then raise exception 'Минимальная ставка — % ScRl.', v_min; end if;

  if v_auction.leader_id is not null and v_auction.current_bid>0 then
    select * into v_old from public.wallets where user_id=v_auction.leader_id for update;
    update public.wallets set hold_scrl=greatest(0,hold_scrl-v_auction.current_bid),scrl=scrl+v_auction.current_bid,updated_at=now() where user_id=v_auction.leader_id;
    update public.bids set status=case when user_id=v_auction.leader_id then 'raised' else 'outbid' end
      where auction_id=p_auction and user_id=v_auction.leader_id and amount=v_auction.current_bid and status='active';
    insert into public.ledger(user_id,currency,delta,note,actor_id) values(v_auction.leader_id,'ScRl',v_auction.current_bid,'Возврат перебитой ставки',auth.uid());
    perform public.scrl_notify(v_auction.leader_id,'Твою ставку в аукционе «'||left(v_auction.title,80)||'» перебили.');
  end if;

  select * into v_wallet from public.wallets where user_id=auth.uid() for update;
  if not found or v_wallet.scrl < p_amount then raise exception 'Недостаточно ScRl для такой ставки.'; end if;
  update public.wallets set scrl=scrl-p_amount,hold_scrl=hold_scrl+p_amount,updated_at=now() where user_id=auth.uid();
  insert into public.ledger(user_id,currency,delta,note,actor_id) values(auth.uid(),'ScRl',-p_amount,'Ставка в аукционе: '||left(v_auction.title,100),auth.uid());
  insert into public.bids(auction_id,user_id,amount) values(p_auction,auth.uid(),p_amount);
  update public.auctions set current_bid=p_amount,leader_id=auth.uid(),bids_count=bids_count+1 where id=p_auction;
  perform public.scrl_notify(v_auction.owner_id,'Новая ставка в аукционе «'||left(v_auction.title,80)||'».');
  perform public.scrl_log(auth.uid(),'Сделана ставка '||p_amount||' ScRl в аукционе.');
end;
$$;

create or replace function public.scrl_finish_auction(p_auction uuid)
returns void
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare v_a public.auctions%rowtype;
begin
  select * into v_a from public.auctions where id=p_auction and status in ('active','settlementError') for update;
  if not found then return; end if;
  if not public.scrl_is_admin() and auth.uid()<>v_a.owner_id and v_a.ends_at>now() then raise exception 'Завершить аукцион можно только после окончания или владельцу.'; end if;
  if v_a.leader_id is not null and v_a.current_bid>0 then
    if not exists(select 1 from public.wallets where user_id=v_a.leader_id and hold_scrl>=v_a.current_bid) then
      update public.auctions set status='settlementError' where id=p_auction;
      raise exception 'Не удалось подтвердить удержанную победную ставку.';
    end if;
    update public.wallets set hold_scrl=hold_scrl-v_a.current_bid,updated_at=now() where user_id=v_a.leader_id;
    update public.bids set status='won' where auction_id=p_auction and user_id=v_a.leader_id and amount=v_a.current_bid and status='active';
    insert into public.ledger(user_id,currency,delta,note,actor_id) values(v_a.leader_id,'ScRl',0,'Победная ставка списана',auth.uid());
    update public.platform_settings set burned_scrl=burned_scrl+v_a.current_bid,updated_at=now() where singleton=true;
    perform public.scrl_notify(v_a.leader_id,'Ты выиграл аукцион «'||left(v_a.title,80)||'».');
  end if;
  update public.auctions set status='done',closed_at=now() where id=p_auction;
  perform public.scrl_notify(v_a.owner_id,'Аукцион «'||left(v_a.title,80)||'» завершён.');
end;
$$;

create or replace function public.scrl_teacher_issue(p_student uuid,p_amount integer,p_reason text)
returns void
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare v_teacher public.profiles%rowtype; v_student public.profiles%rowtype; v_week date; v_used integer;
begin
  select * into v_teacher from public.profiles where id=auth.uid() and not blocked;
  select * into v_student from public.profiles where id=p_student and not blocked;
  if v_teacher.role not in ('teacher','admin') then raise exception 'Нет доступа.'; end if;
  if not found or v_student.role<>'student' then raise exception 'Выбери активного ученика.'; end if;
  if v_teacher.role='teacher' and v_student.room<>v_teacher.room then raise exception 'Можно начислять только ученикам своего класса.'; end if;
  if p_amount not between 1 and 500 then raise exception 'Сумма должна быть от 1 до 500 ScRl.'; end if;
  v_week := date_trunc('week',now())::date;
  insert into public.teacher_issuance(teacher_id,week_start,amount) values(auth.uid(),v_week,0) on conflict do nothing;
  select amount into v_used from public.teacher_issuance where teacher_id=auth.uid() and week_start=v_week for update;
  if v_used+p_amount>500 then raise exception 'Превышен недельный лимит 500 ScRl.'; end if;
  update public.teacher_issuance set amount=amount+p_amount where teacher_id=auth.uid() and week_start=v_week;
  update public.wallets set scrl=scrl+p_amount,updated_at=now() where user_id=p_student;
  insert into public.ledger(user_id,currency,delta,note,actor_id) values(p_student,'ScRl',p_amount,'Начисление: '||left(coalesce(p_reason,'Без комментария'),120),auth.uid());
  perform public.scrl_notify(p_student,'Тебе начислено '||p_amount||' ScRl.');
  insert into public.audit(actor_id,message) values(auth.uid(),'Начислено '||p_amount||' ScRl участнику '||p_student::text);
end;
$$;

create or replace function public.scrl_admin_set_user(p_target uuid,p_action text,p_reason text default '',p_room text default '')
returns void
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare v_user public.profiles%rowtype;
begin
  if not public.scrl_is_admin() then raise exception 'Нет доступа.'; end if;
  select * into v_user from public.profiles where id=p_target for update;
  if not found or v_user.id=auth.uid() and p_action in ('block','remove') then raise exception 'Недопустимое действие.'; end if;
  if v_user.role='admin' and p_action in ('block','remove') then raise exception 'Нельзя заблокировать другого администратора.'; end if;
  if p_action='teacher' then
    if length(trim(p_room))=0 or length(p_room)>12 then raise exception 'Укажи класс учителя.'; end if;
    update public.profiles set role='teacher',room=trim(p_room),updated_at=now() where id=p_target;
  elsif p_action='student' then
    update public.profiles set role='student',room='',updated_at=now() where id=p_target;
  elsif p_action='block' then
    update public.profiles set blocked=not blocked,block_reason=case when blocked then '' else left(coalesce(p_reason,'Нарушение правил'),180) end,updated_at=now() where id=p_target;
  elsif p_action='anonymize' then
    if exists(select 1 from public.deals where (buyer_id=p_target or seller_id=p_target) and status in ('work','ready','dispute'))
      or exists(select 1 from public.exchange_orders where owner_id=p_target and status='active')
      or exists(select 1 from public.auctions where status='active' and (owner_id=p_target or leader_id=p_target)) then
      raise exception 'Сначала заверши активные сделки, заявки и аукционы.';
    end if;
    update public.profiles set full_name='Удалённый участник',room='',role='student',blocked=true,block_reason='Профиль обезличен',updated_at=now() where id=p_target;
    update public.posts set status='hidden' where owner_id=p_target;
    update public.listings set status='hidden' where owner_id=p_target;
  else
    raise exception 'Неизвестное административное действие.';
  end if;
  insert into public.audit(actor_id,message) values(auth.uid(),'Администраторское действие '||p_action||' для '||p_target::text);
end;
$$;

create or replace function public.scrl_admin_moderate(p_kind text,p_target text,p_action text)
returns void
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare v_report public.reports%rowtype;
begin
  if not public.scrl_is_admin() then raise exception 'Нет доступа.'; end if;
  if p_kind not in ('post','listing') or p_action not in ('keep','hide') then raise exception 'Некорректное решение модерации.'; end if;
  if p_kind='post' then
    update public.posts set status=case when p_action='keep' then 'active' else 'hidden' end where id::text=p_target;
  else
    update public.listings set status=case when p_action='keep' then 'active' else 'hidden' end where id::text=p_target;
  end if;
  update public.reports set status=case when p_action='keep' then 'kept' else 'hidden' end
    where kind=p_kind and target_id=p_target and status='open';
  insert into public.audit(actor_id,message) values(auth.uid(),p_action||' публикация '||p_kind||' '||p_target);
end;
$$;

create or replace function public.scrl_admin_update_economy(p_rate numeric)
returns void
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
begin
  if not public.scrl_is_admin() then raise exception 'Нет доступа.'; end if;
  if p_rate not between 0.001 and 1 then raise exception 'Курс должен быть от 0,001 до 1 V-RUB.'; end if;
  update public.platform_settings set target_rate=p_rate,updated_at=now() where singleton=true;
  insert into public.audit(actor_id,message) values(auth.uid(),'Изменён целевой курс ScRl: '||p_rate::text);
end;
$$;

-- Row-level security for all public application tables.
alter table public.profiles enable row level security;
alter table public.wallets enable row level security;
alter table public.ledger enable row level security;
alter table public.posts enable row level security;
alter table public.listings enable row level security;
alter table public.deals enable row level security;
alter table public.deal_messages enable row level security;
alter table public.exchange_orders enable row level security;
alter table public.trades enable row level security;
alter table public.auctions enable row level security;
alter table public.bids enable row level security;
alter table public.favorites enable row level security;
alter table public.reports enable row level security;
alter table public.notifications enable row level security;
alter table public.reviews enable row level security;
alter table public.activity enable row level security;
alter table public.audit enable row level security;
alter table public.teacher_issuance enable row level security;
alter table public.platform_settings enable row level security;

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
grant usage on schema public to authenticated;
grant select on public.profiles to authenticated;
grant update(full_name,room) on public.profiles to authenticated;
grant select on public.wallets, public.ledger, public.posts, public.listings, public.deals,
  public.deal_messages, public.exchange_orders, public.trades, public.auctions, public.bids,
  public.favorites, public.reports, public.notifications, public.reviews, public.activity,
  public.audit, public.teacher_issuance, public.platform_settings to authenticated;
grant insert on public.posts, public.listings, public.reports, public.favorites, public.deal_messages, public.reviews to authenticated;
grant update(title,description,category,price) on public.posts to authenticated;
grant update(title,description,category,price,slots) on public.listings to authenticated;
grant delete on public.favorites to authenticated;
grant update(seen) on public.notifications to authenticated;

drop policy if exists profiles_read_authenticated on public.profiles;
create policy profiles_read_authenticated on public.profiles for select to authenticated using (true);
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update to authenticated using (id=auth.uid()) with check (id=auth.uid());

drop policy if exists wallets_read_self_or_admin on public.wallets;
create policy wallets_read_self_or_admin on public.wallets for select to authenticated using (user_id=auth.uid() or public.scrl_is_admin());
drop policy if exists ledger_read_self_or_admin on public.ledger;
create policy ledger_read_self_or_admin on public.ledger for select to authenticated using (user_id=auth.uid() or public.scrl_is_admin());

drop policy if exists posts_read_feed on public.posts;
create policy posts_read_feed on public.posts for select to authenticated using (status='active' or owner_id=auth.uid() or public.scrl_is_admin());
drop policy if exists posts_insert_self on public.posts;
create policy posts_insert_self on public.posts for insert to authenticated with check (owner_id=auth.uid() and status in ('active','review'));
drop policy if exists posts_update_self on public.posts;
create policy posts_update_self on public.posts for update to authenticated using (owner_id=auth.uid()) with check (owner_id=auth.uid());
drop policy if exists listings_read_feed on public.listings;
create policy listings_read_feed on public.listings for select to authenticated using (status='active' or owner_id=auth.uid() or public.scrl_is_admin());
drop policy if exists listings_insert_self on public.listings;
create policy listings_insert_self on public.listings for insert to authenticated with check (owner_id=auth.uid() and status in ('active','review'));
drop policy if exists listings_update_self on public.listings;
create policy listings_update_self on public.listings for update to authenticated using (owner_id=auth.uid()) with check (owner_id=auth.uid());

drop policy if exists deals_read_participants on public.deals;
create policy deals_read_participants on public.deals for select to authenticated using (buyer_id=auth.uid() or seller_id=auth.uid() or public.scrl_is_admin());
drop policy if exists messages_read_participants on public.deal_messages;
create policy messages_read_participants on public.deal_messages for select to authenticated using (exists(select 1 from public.deals d where d.id=deal_id and auth.uid() in (d.buyer_id,d.seller_id)) or public.scrl_is_admin());
drop policy if exists messages_insert_participant on public.deal_messages;
create policy messages_insert_participant on public.deal_messages for insert to authenticated with check (user_id=auth.uid() and exists(select 1 from public.deals d where d.id=deal_id and auth.uid() in (d.buyer_id,d.seller_id) and d.status in ('work','ready','dispute')));

drop policy if exists exchange_orders_read on public.exchange_orders;
create policy exchange_orders_read on public.exchange_orders for select to authenticated using (status='active' or owner_id=auth.uid() or public.scrl_is_admin());
drop policy if exists trades_read_authenticated on public.trades;
create policy trades_read_authenticated on public.trades for select to authenticated using (true);
drop policy if exists auctions_read on public.auctions;
create policy auctions_read on public.auctions for select to authenticated using (status='active' or owner_id=auth.uid() or public.scrl_is_admin());
drop policy if exists bids_read_authenticated on public.bids;
create policy bids_read_authenticated on public.bids for select to authenticated using (exists(select 1 from public.auctions a where a.id=auction_id and (a.status='active' or a.owner_id=auth.uid() or public.scrl_is_admin())) or user_id=auth.uid());

drop policy if exists favorites_read_self on public.favorites;
create policy favorites_read_self on public.favorites for select to authenticated using (user_id=auth.uid());
drop policy if exists favorites_insert_self on public.favorites;
create policy favorites_insert_self on public.favorites for insert to authenticated with check (user_id=auth.uid());
drop policy if exists favorites_delete_self on public.favorites;
create policy favorites_delete_self on public.favorites for delete to authenticated using (user_id=auth.uid());

drop policy if exists reports_read on public.reports;
create policy reports_read on public.reports for select to authenticated using (reporter_id=auth.uid() or public.scrl_is_admin());
drop policy if exists reports_insert_self on public.reports;
create policy reports_insert_self on public.reports for insert to authenticated with check (reporter_id=auth.uid() and status='open');

drop policy if exists notifications_read_self on public.notifications;
create policy notifications_read_self on public.notifications for select to authenticated using (user_id=auth.uid());
drop policy if exists notifications_update_self on public.notifications;
create policy notifications_update_self on public.notifications for update to authenticated using (user_id=auth.uid()) with check (user_id=auth.uid());

drop policy if exists reviews_read_authenticated on public.reviews;
create policy reviews_read_authenticated on public.reviews for select to authenticated using (true);
drop policy if exists reviews_insert_participant on public.reviews;
create policy reviews_insert_participant on public.reviews for insert to authenticated with check (
  user_id=auth.uid() and exists(select 1 from public.deals d where d.id=deal_id and d.status='done'
    and auth.uid() in (d.buyer_id,d.seller_id)
    and target_id=case when auth.uid()=d.buyer_id then d.seller_id else d.buyer_id end)
);

drop policy if exists activity_read_self_admin on public.activity;
create policy activity_read_self_admin on public.activity for select to authenticated using (user_id=auth.uid() or public.scrl_is_admin());
drop policy if exists audit_read_admin on public.audit;
create policy audit_read_admin on public.audit for select to authenticated using (public.scrl_is_admin());
drop policy if exists issuance_read_teacher_admin on public.teacher_issuance;
create policy issuance_read_teacher_admin on public.teacher_issuance for select to authenticated using (teacher_id=auth.uid() or public.scrl_is_admin());
drop policy if exists settings_read_authenticated on public.platform_settings;
create policy settings_read_authenticated on public.platform_settings for select to authenticated using (true);

-- Only authenticated users can invoke the transactional API. Financial tables are write-protected by RLS and column privileges.
revoke all on function public.scrl_notify(uuid,text) from public;
revoke all on function public.scrl_log(uuid,text) from public;
revoke all on function public.scrl_current_fee() from public;
revoke all on function public.scrl_handle_new_user() from public;
revoke all on function public.scrl_claim_initial_admin() from public;
revoke all on function public.scrl_create_deal(text,uuid,uuid,numeric,text,text) from public;
revoke all on function public.scrl_deal_action(uuid,text,numeric) from public;
revoke all on function public.scrl_send_message(uuid,text) from public;
revoke all on function public.scrl_place_exchange_order(text,numeric,numeric) from public;
revoke all on function public.scrl_buy_exchange_order(uuid) from public;
revoke all on function public.scrl_cancel_exchange_order(uuid) from public;
revoke all on function public.scrl_create_auction(text,text,numeric,numeric,integer) from public;
revoke all on function public.scrl_place_bid(uuid,numeric) from public;
revoke all on function public.scrl_finish_auction(uuid) from public;
revoke all on function public.scrl_teacher_issue(uuid,integer,text) from public;
revoke all on function public.scrl_admin_set_user(uuid,text,text,text) from public;
revoke all on function public.scrl_admin_moderate(text,text,text) from public;
revoke all on function public.scrl_admin_update_economy(numeric) from public;
grant execute on function public.scrl_claim_initial_admin() to authenticated;
grant execute on function public.scrl_create_deal(text,uuid,uuid,numeric,text,text) to authenticated;
grant execute on function public.scrl_deal_action(uuid,text,numeric) to authenticated;
grant execute on function public.scrl_send_message(uuid,text) to authenticated;
grant execute on function public.scrl_place_exchange_order(text,numeric,numeric) to authenticated;
grant execute on function public.scrl_buy_exchange_order(uuid) to authenticated;
grant execute on function public.scrl_cancel_exchange_order(uuid) to authenticated;
grant execute on function public.scrl_create_auction(text,text,numeric,numeric,integer) to authenticated;
grant execute on function public.scrl_place_bid(uuid,numeric) to authenticated;
grant execute on function public.scrl_finish_auction(uuid) to authenticated;
grant execute on function public.scrl_teacher_issue(uuid,integer,text) to authenticated;
grant execute on function public.scrl_admin_set_user(uuid,text,text,text) to authenticated;
grant execute on function public.scrl_admin_moderate(text,text,text) to authenticated;
grant execute on function public.scrl_admin_update_economy(numeric) to authenticated;
