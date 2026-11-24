create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.scrl_admin_bootstrap (
  singleton boolean primary key default true check (singleton),
  code_hash text,
  code_once text,
  claimed_at timestamptz
);
revoke all on private.scrl_admin_bootstrap from public, anon, authenticated;

create or replace function private.scrl_take_admin_code()
returns text
language plpgsql security definer
set search_path = private, pg_temp
as $$
declare v_code text;
begin
  select code_once into v_code from private.scrl_admin_bootstrap where singleton=true for update;
  update private.scrl_admin_bootstrap set code_once=null where singleton=true;
  return v_code;
end;
$$;
revoke all on function private.scrl_take_admin_code() from public, anon, authenticated;

do $$
declare v_code text;
begin
  if not exists(select 1 from public.profiles where role='admin') then
    v_code := encode(gen_random_bytes(24),'hex');
    insert into private.scrl_admin_bootstrap(singleton,code_hash,code_once,claimed_at)
      values(true,encode(digest(v_code,'sha256'),'hex'),v_code,null)
    on conflict(singleton) do update
      set code_hash=excluded.code_hash, code_once=excluded.code_once, claimed_at=null;
  else
    insert into private.scrl_admin_bootstrap(singleton,code_hash,code_once,claimed_at)
      values(true,null,null,now()) on conflict(singleton) do nothing;
  end if;
end;
$$;

create or replace function public.scrl_handle_new_user()
returns trigger
language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare v_name text;
begin
  v_name := coalesce(nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''), split_part(coalesce(new.email,''),'@',1), 'Участник');
  insert into public.profiles(id, full_name, role)
    values (new.id, left(v_name,100), 'student') on conflict (id) do nothing;
  insert into public.wallets(user_id, scrl, vrub) values (new.id, 100, 50) on conflict (user_id) do nothing;
  insert into public.ledger(user_id, currency, delta, note) values
    (new.id, 'ScRl', 100, 'Стартовый баланс'),
    (new.id, 'V-RUB', 50, 'Стартовый виртуальный баланс');
  return new;
end;
$$;

drop function if exists public.scrl_claim_initial_admin();
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
  if v_hash is null or p_code is null or length(p_code) > 128 or encode(digest(p_code,'sha256'),'hex') <> v_hash then
    return false;
  end if;
  if not exists(select 1 from public.profiles where id=auth.uid()) then return false; end if;
  update public.profiles set role='admin',updated_at=now() where id=auth.uid();
  update private.scrl_admin_bootstrap set code_hash=null,code_once=null,claimed_at=now() where singleton=true;
  insert into public.audit(actor_id,message) values(auth.uid(),'Первый администратор назначен через одноразовый код.');
  return true;
end;
$$;
revoke all on function public.scrl_claim_initial_admin(text) from public,anon;
grant execute on function public.scrl_claim_initial_admin(text) to authenticated;
