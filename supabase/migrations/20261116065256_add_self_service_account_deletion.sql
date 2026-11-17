-- Self-service account deletion while preserving anonymized financial history.
alter table public.profiles add column if not exists deleted_at timestamptz;
alter table public.profiles drop constraint if exists profiles_id_fkey;
create or replace function public.scrl_delete_account(p_user uuid)
returns void language plpgsql security definer
set search_path to 'public', 'auth', 'pg_temp'
as $function$
declare v_profile public.profiles%rowtype; v_wallet public.wallets%rowtype;
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' then
    raise exception 'Недостаточно прав для удаления аккаунта.';
  end if;
  if p_user is null then raise exception 'Не удалось определить аккаунт.'; end if;
  select * into v_profile from public.profiles where id=p_user for update;
  if not found then raise exception 'Профиль не найден.'; end if;
  if v_profile.deleted_at is not null then return; end if;
  if v_profile.role='admin' and not exists (
    select 1 from public.profiles where role='admin' and blocked=false and deleted_at is null and id<>p_user
  ) then raise exception 'Сначала назначь другого администратора, затем можно удалить этот аккаунт.'; end if;
  if exists (
    select 1 from public.deals where (buyer_id=p_user or seller_id=p_user) and status in ('work','ready','dispute')
  ) then raise exception 'Перед удалением заверши или урегулируй активные сделки.'; end if;
  if exists (select 1 from public.exchange_orders where owner_id=p_user and status='active') then
    raise exception 'Перед удалением отмени активные заявки на бирже.';
  end if;
  if exists (
    select 1 from public.auctions where status in ('active','settlementError') and (owner_id=p_user or leader_id=p_user)
  ) then raise exception 'Перед удалением дождись завершения активных аукционов.'; end if;
  select * into v_wallet from public.wallets where user_id=p_user for update;
  if not found then raise exception 'Кошелёк аккаунта не найден. Обратись к администратору.'; end if;
  if v_wallet.hold_scrl>0 or v_wallet.hold_vrub>0 then raise exception 'Сначала освободи все резервы ScRl и V-RUB.'; end if;

  update public.posts set title='Удалённая публикация',description='Содержимое удалено автором',category='Другое',status='hidden' where owner_id=p_user;
  update public.listings set title='Удалённая услуга',description='Содержимое удалено автором',category='Другое',status='hidden' where owner_id=p_user;
  update public.deals set title='Сделка удалённого участника' where buyer_id=p_user or seller_id=p_user;
  update public.auctions set title='Аукцион удалённого участника',prize='Информация удалена'
    where owner_id=p_user and status not in ('active','settlementError');

  delete from public.deal_messages where user_id=p_user;
  delete from public.reviews where user_id=p_user;
  delete from public.reports where reporter_id=p_user;
  delete from public.favorites where user_id=p_user;
  delete from public.notifications where user_id=p_user;
  delete from public.activity where user_id=p_user;
  delete from public.teacher_issuance where teacher_id=p_user;
  delete from public.scrl_moderation_appeals where user_id=p_user;
  delete from public.scrl_moderation_bans where user_id=p_user;
  delete from public.scrl_moderation_cases where user_id=p_user;
  delete from public.scrl_moderation_tickets where user_id=p_user;

  update public.ledger set note='Операция удалённого участника' where user_id=p_user or actor_id=p_user;
  update public.profiles set full_name='Удалённый участник',room='',role='student',blocked=true,
    block_reason='Аккаунт удалён пользователем',deleted_at=now(),updated_at=now() where id=p_user;
end;
$function$;
revoke all on function public.scrl_delete_account(uuid) from public, anon, authenticated;
grant execute on function public.scrl_delete_account(uuid) to service_role;
