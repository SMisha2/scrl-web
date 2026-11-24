create or replace function public.scrl_create_auction(p_title text,p_prize text,p_start numeric,p_step numeric,p_minutes integer)
returns uuid
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare v_id uuid; v_role text;
begin
  if auth.uid() is null then raise exception 'Требуется вход.'; end if;
  select role into v_role from public.profiles where id=auth.uid() and not blocked;
  if v_role is null or v_role not in ('teacher','admin') then raise exception 'Создавать аукционы могут активные учителя и администраторы.'; end if;
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
  v_role text;
  v_min numeric;
begin
  if auth.uid() is null then raise exception 'Требуется вход.'; end if;
  select role into v_role from public.profiles where id=auth.uid() and not blocked;
  if v_role is null or v_role <> 'student' then raise exception 'Ставки доступны только активным ученикам.'; end if;
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

create or replace function public.scrl_send_message(p_deal uuid, p_message text)
returns uuid
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare v_id uuid; v_other uuid; v_title text;
begin
  if auth.uid() is null then raise exception 'Требуется вход.'; end if;
  if exists(select 1 from public.profiles where id=auth.uid() and blocked) then raise exception 'Аккаунт заблокирован.'; end if;
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
  if exists(select 1 from public.profiles where id=auth.uid() and blocked) and not public.scrl_is_admin() then
    raise exception 'Аккаунт заблокирован. Решение по активной сделке принимает администратор.';
  end if;

  if p_action='delivered' then
    if auth.uid() <> v_deal.seller_id or v_deal.status <> 'work' then raise exception 'Нельзя отметить выполнение этой сделки.'; end if;
    update public.deals set status='ready' where id=p_deal;
    perform public.scrl_notify(v_deal.buyer_id,'Исполнитель отметил заказ как выполненный.');
    perform public.scrl_log(v_deal.seller_id,'Отмечено выполнение заказа «'||left(v_deal.title,100)||'».');
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
    v_fee_rate := public.scrl_current_fee();
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

create or replace function public.scrl_finish_auction(p_auction uuid)
returns void
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare v_a public.auctions%rowtype;
begin
  if auth.uid() is null then raise exception 'Требуется вход.'; end if;
  if exists(select 1 from public.profiles where id=auth.uid() and blocked) then raise exception 'Аккаунт заблокирован.'; end if;
  select * into v_a from public.auctions where id=p_auction and status in ('active','settlementError') for update;
  if not found then return; end if;
  if not public.scrl_is_admin() and auth.uid()<>v_a.owner_id and v_a.ends_at>now() then raise exception 'Завершить аукцион можно только после окончания или владельцу.'; end if;
  if v_a.leader_id is not null and v_a.current_bid>0 then
    if not exists(select 1 from public.wallets where user_id=v_a.leader_id and hold_scrl>=v_a.current_bid) then
      update public.auctions set status='settlementError' where id=p_auction;
      return;
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

create or replace function public.scrl_claim_initial_admin(p_code text)
returns boolean
language plpgsql security definer
set search_path = public, auth, private, pg_temp
as $$
declare v_hash text;
begin
  if auth.uid() is null then raise exception 'Требуется вход.'; end if;
  perform pg_advisory_xact_lock(hashtext('scrl_initial_admin'));
  if exists(select 1 from public.profiles where role='admin') then return false; end if;
  select code_hash into v_hash from private.scrl_admin_bootstrap where singleton=true for update;
  if v_hash is null or p_code is null or length(p_code) > 128 or encode(digest(p_code,'sha256'),'hex') <> v_hash then return false; end if;
  if not exists(select 1 from public.profiles where id=auth.uid() and not blocked) then return false; end if;
  update public.profiles set role='admin',updated_at=now() where id=auth.uid();
  update private.scrl_admin_bootstrap set code_hash=null,code_once=null,claimed_at=now() where singleton=true;
  insert into public.audit(actor_id,message) values(auth.uid(),'Первый администратор назначен через одноразовый код.');
  return true;
end;
$$;

create or replace function public.scrl_prevent_teacher_room_self_change()
returns trigger
language plpgsql
set search_path = public, auth, pg_temp
as $$
begin
  if old.role='teacher' and auth.uid()=old.id and new.room is distinct from old.room then
    raise exception 'Класс учителя может менять только администратор.';
  end if;
  return new;
end;
$$;
drop trigger if exists scrl_teacher_room_guard on public.profiles;
create trigger scrl_teacher_room_guard
before update on public.profiles
for each row execute function public.scrl_prevent_teacher_room_self_change();

revoke all on function public.scrl_prevent_teacher_room_self_change() from public,anon,authenticated;
