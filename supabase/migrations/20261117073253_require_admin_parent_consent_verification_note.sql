alter table private.scrl_user_safety
  add column if not exists parent_exchange_verification_note text;

drop function if exists public.scrl_admin_review_exchange_parent_consent(uuid, text);

create or replace function public.scrl_admin_review_exchange_parent_consent(
  p_user_id uuid,
  p_decision text,
  p_verification_note text default null
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
  v_note text := left(trim(coalesce(p_verification_note, '')), 300);
begin
  if not public.scrl_is_admin() then raise exception 'Нет доступа.'; end if;
  if p_decision not in ('approve','reject') then
    raise exception 'Некорректное решение.';
  end if;
  if p_decision = 'approve' and length(v_note) < 5 then
    raise exception 'Для подтверждения укажи, как проверено согласие родителя (от 5 до 300 символов).';
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
      parent_exchange_verification_note = case when p_decision = 'approve' then v_note else null end,
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
  values (
    auth.uid(),
    'Решение по родительскому согласию биржи (' || p_decision || '): ' ||
    v_name || ' · ' || p_user_id::text
  );
end;
$$;

revoke all on function public.scrl_admin_review_exchange_parent_consent(uuid, text, text) from public, anon;
grant execute on function public.scrl_admin_review_exchange_parent_consent(uuid, text, text) to authenticated;
