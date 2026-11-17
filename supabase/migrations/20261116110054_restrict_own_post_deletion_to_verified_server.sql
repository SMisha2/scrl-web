drop function if exists public.scrl_delete_own_post(uuid);

create or replace function public.scrl_delete_own_post(p_user uuid, p_post uuid)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $function$
declare
  v_post public.posts%rowtype;
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' then
    raise exception 'Недостаточно прав для удаления публикации.';
  end if;

  if p_user is null or p_post is null then
    raise exception 'Не удалось определить публикацию.';
  end if;

  select * into v_post
  from public.posts
  where id = p_post and owner_id = p_user
  for update;

  if not found then
    raise exception 'Публикация не найдена или принадлежит другому участнику.';
  end if;

  if exists (
    select 1 from public.profiles
    where id = p_user and blocked = true
  ) then
    raise exception 'Аккаунт заблокирован.';
  end if;

  if exists (
    select 1
    from public.deals
    where source = 'board'
      and source_id = p_post::text
      and status in ('work', 'ready', 'dispute')
  ) then
    raise exception 'Нельзя удалить публикацию, пока по ней есть активная сделка.';
  end if;

  delete from public.favorites
  where kind = 'post' and target_id = p_post::text;

  delete from public.reports
  where kind = 'post' and target_id = p_post::text;

  delete from public.posts
  where id = p_post and owner_id = p_user;

  if not found then
    raise exception 'Не удалось удалить публикацию.';
  end if;

  perform public.scrl_log(p_user, 'Удалена собственная публикация.');
end;
$function$;

revoke all on function public.scrl_delete_own_post(uuid, uuid) from public;
revoke all on function public.scrl_delete_own_post(uuid, uuid) from anon;
revoke all on function public.scrl_delete_own_post(uuid, uuid) from authenticated;
grant execute on function public.scrl_delete_own_post(uuid, uuid) to service_role;
