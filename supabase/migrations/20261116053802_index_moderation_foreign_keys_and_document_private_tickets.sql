create index if not exists scrl_moderation_appeals_reviewed_by_idx on public.scrl_moderation_appeals(reviewed_by);
create index if not exists scrl_moderation_appeals_user_id_idx on public.scrl_moderation_appeals(user_id);
create index if not exists scrl_moderation_bans_case_id_idx on public.scrl_moderation_bans(case_id);
create index if not exists scrl_moderation_bans_lifted_by_idx on public.scrl_moderation_bans(lifted_by);
create index if not exists scrl_moderation_cases_reviewed_by_idx on public.scrl_moderation_cases(reviewed_by);
comment on table public.scrl_moderation_tickets is 'Private single-use write permits. RLS is enabled with no client policies by design; only the scrl-moderation Edge Function service role can access tickets.';
