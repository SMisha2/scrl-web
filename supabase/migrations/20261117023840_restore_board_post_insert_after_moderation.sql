-- Repair/restore the board insert in the moderation-aware create_post RPC.
-- This is idempotent and intentionally repeats the final definition from the main permission/pricing migration.
CREATE OR REPLACE FUNCTION public.scrl_create_post(p_type text, p_title text, p_description text, p_category text, p_price numeric)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_id uuid;
  v_status text;
begin
  if auth.uid() is null then
    raise exception 'Требуется вход.';
  end if;
  if p_type not in ('need','offer')
    or length(trim(coalesce(p_title,''))) not between 1 and 100
    or length(trim(coalesce(p_description,''))) not between 1 and 1500
    or p_price is null or p_price < 0 then
    raise exception 'Проверь заголовок, описание и цену.';
  end if;
  if exists(select 1 from public.profiles where id=auth.uid() and blocked) then
    raise exception 'Аккаунт заблокирован.';
  end if;

  -- The moderation guard consumes the AI ticket and sets review/hidden when needed.
  v_status := 'active';
  insert into public.posts(type,title,description,category,price,owner_id,status)
    values(p_type,trim(p_title),trim(p_description),coalesce(nullif(trim(p_category),''),'Другое'),p_price,auth.uid(),v_status)
    returning id into v_id;

  perform public.scrl_log(auth.uid(),'Создана публикация «'||left(p_title,100)||'».');
  return v_id;
end;
$function$;
