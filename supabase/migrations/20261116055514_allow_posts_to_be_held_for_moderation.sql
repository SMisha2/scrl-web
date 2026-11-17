alter table public.posts
  drop constraint if exists posts_status_check;

alter table public.posts
  add constraint posts_status_check
  check (status = any (array['active'::text,'review'::text,'closed'::text,'hidden'::text]));
