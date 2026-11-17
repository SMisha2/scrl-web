-- Historical version 20261116110034_add_secure_own_post_deletion.
-- The original one-argument function is intentionally superseded by the immediately
-- following 20261116110054 migration, which drops that obsolete signature and creates
-- public.scrl_delete_own_post(p_user uuid, p_post uuid) with service_role-only execution.
-- Keep this marker so local and production migration version histories remain aligned.
select 1;
