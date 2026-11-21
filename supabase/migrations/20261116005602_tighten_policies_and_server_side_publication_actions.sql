-- Tighten Data API grants and move publication creation behind trusted SQL.
revoke all on public.profiles from anon, authenticated;
grant select(id,full_name,room,role,blocked,created_at) on public.profiles to authenticated;
grant update(full_name,room) on public.profiles to authenticated;

revoke insert on public.posts, public.listings, public.deal_messages from authenticated;
revoke update(status) on public.posts, public.listings from authenticated;
revoke update(slots) on public.listings from authenticated;

create or replace function public.scrl_create_post(p_type text,p_title text,p_description text,p_category text,p_price numeric)
returns uuid
language plpgsql security definer
set search_path=public,auth,pg_temp
as $$
declare v_id uuid; v_status text; v_text text;
begin
  if auth.uid() is null then raise exception 'Требуется вход.'; end if;
  if p_type not in ('need','offer') or length(trim(coalesce(p_title,''))) not between 1 and 100
    or length(trim(coalesce(p_description,''))) not between 1 and 1500
    or p_price not between 0 and 500 then raise exception 'Проверь заголовок, описание и цену.'; end if;
  if exists(select 1 from public.profiles where id=auth.uid() and blocked) then raise exception 'Аккаунт заблокирован.'; end if;
  v_text:=p_title||' '||p_description;
  v_status:=case when v_text ~* '(https?://|www\.|[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}|\+?[0-9][0-9 ()-]{8,})' then 'review' else 'active' end;
  insert into public.posts(type,title,description,category,price,owner_id,status)
    values(p_type,trim(p_title),trim(p_description),coalesce(nullif(trim(p_category),''),'Другое'),p_price,auth.uid(),v_status)
    returning id into v_id;
  if v_status='review' then
    insert into public.reports(kind,target_id,reporter_id,reason,reason_code)
      values('post',v_id::text,auth.uid(),'Автопроверка: в тексте есть ссылка или контактные данные','auto');
  end if;
  perform public.scrl_log(auth.uid(),'Создана публикация «'||left(p_title,100)||'».');
  return v_id;
end;
$$;

create or replace function public.scrl_create_listing(p_title text,p_description text,p_category text,p_price numeric,p_slots integer)
returns uuid
language plpgsql security definer
set search_path=public,auth,pg_temp
as $$
declare v_id uuid; v_status text; v_text text;
begin
  if auth.uid() is null then raise exception 'Требуется вход.'; end if;
  if length(trim(coalesce(p_title,''))) not between 1 and 100
    or length(trim(coalesce(p_description,''))) not between 1 and 1500
    or p_price not between 1 and 500 or p_slots not between 1 and 10 then raise exception 'Проверь данные услуги.'; end if;
  if exists(select 1 from public.profiles where id=auth.uid() and blocked) then raise exception 'Аккаунт заблокирован.'; end if;
  v_text:=p_title||' '||p_description;
  v_status:=case when v_text ~* '(https?://|www\.|[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}|\+?[0-9][0-9 ()-]{8,})' then 'review' else 'active' end;
  insert into public.listings(title,description,category,price,slots,owner_id,status)
    values(trim(p_title),trim(p_description),coalesce(nullif(trim(p_category),''),'Другое'),p_price,p_slots,auth.uid(),v_status)
    returning id into v_id;
  if v_status='review' then
    insert into public.reports(kind,target_id,reporter_id,reason,reason_code)
      values('listing',v_id::text,auth.uid(),'Автопроверка: в тексте есть ссылка или контактные данные','auto');
  end if;
  perform public.scrl_log(auth.uid(),'Добавлена услуга «'||left(p_title,100)||'».');
  return v_id;
end;
$$;

create or replace function public.scrl_close_publication(p_kind text,p_id uuid)
returns void
language plpgsql security definer
set search_path=public,auth,pg_temp
as $$
begin
  if p_kind='post' then
    update public.posts set status='closed' where id=p_id and owner_id=auth.uid() and status='active';
  elsif p_kind='listing' then
    update public.listings set status='closed' where id=p_id and owner_id=auth.uid() and status='active';
  else
    raise exception 'Неизвестный тип публикации.';
  end if;
  if not found then raise exception 'Публикация не найдена или уже закрыта.'; end if;
end;
$$;

create or replace function public.scrl_mark_notifications_read()
returns void
language sql security definer
set search_path=public,auth,pg_temp
as $$
  update public.notifications set seen=true where user_id=auth.uid() and seen=false;
$$;

-- Require the order price to match the source publication, preventing a caller from choosing an arbitrary escrow amount.
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
    if p_amount<>v_listing.price then raise exception 'Цена услуги изменилась. Обнови страницу.'; end if;
    update public.listings set slots=slots-1, status=case when slots-1 <= 0 then 'sold' else status end where id=v_listing.id;
  elsif p_source = 'board' then
    select * into v_post from public.posts where id::text = p_source_id and status='active' for update;
    if not found then raise exception 'Публикация больше недоступна.'; end if;
    if p_amount<>v_post.price then raise exception 'Цена публикации изменилась. Обнови страницу.'; end if;
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

revoke all on function public.scrl_create_post(text,text,text,text,numeric) from public, anon;
revoke all on function public.scrl_create_listing(text,text,text,numeric,integer) from public, anon;
revoke all on function public.scrl_close_publication(text,uuid) from public, anon;
revoke all on function public.scrl_mark_notifications_read() from public, anon;
grant execute on function public.scrl_create_post(text,text,text,text,numeric) to authenticated;
grant execute on function public.scrl_create_listing(text,text,text,numeric,integer) to authenticated;
grant execute on function public.scrl_close_publication(text,uuid) to authenticated;
grant execute on function public.scrl_mark_notifications_read() to authenticated;

-- Explicitly strip anonymous execute privileges from every application API routine.
revoke execute on function public.scrl_is_admin() from anon;
revoke execute on function public.scrl_current_fee() from anon;
revoke execute on function public.scrl_claim_initial_admin() from anon;
revoke execute on function public.scrl_create_deal(text,uuid,uuid,numeric,text,text) from anon;
revoke execute on function public.scrl_deal_action(uuid,text,numeric) from anon;
revoke execute on function public.scrl_send_message(uuid,text) from anon;
revoke execute on function public.scrl_place_exchange_order(text,numeric,numeric) from anon;
revoke execute on function public.scrl_buy_exchange_order(uuid) from anon;
revoke execute on function public.scrl_cancel_exchange_order(uuid) from anon;
revoke execute on function public.scrl_create_auction(text,text,numeric,numeric,integer) from anon;
revoke execute on function public.scrl_place_bid(uuid,numeric) from anon;
revoke execute on function public.scrl_finish_auction(uuid) from anon;
revoke execute on function public.scrl_teacher_issue(uuid,integer,text) from anon;
revoke execute on function public.scrl_admin_set_user(uuid,text,text,text) from anon;
revoke execute on function public.scrl_admin_moderate(text,text,text) from anon;
revoke execute on function public.scrl_admin_update_economy(numeric) from anon;
revoke execute on function public.scrl_notify(uuid,text) from anon;
revoke execute on function public.scrl_log(uuid,text) from anon;
revoke execute on function public.scrl_handle_new_user() from anon;
revoke execute on function public.scrl_create_post(text,text,text,text,numeric) from anon;
revoke execute on function public.scrl_create_listing(text,text,text,numeric,integer) from anon;
revoke execute on function public.scrl_close_publication(text,uuid) from anon;
revoke execute on function public.scrl_mark_notifications_read() from anon;
