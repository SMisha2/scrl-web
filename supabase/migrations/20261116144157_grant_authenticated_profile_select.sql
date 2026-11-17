-- Allow signed-in ScRl users to load profile data.
-- Row visibility remains constrained by the existing profiles RLS policies.
GRANT SELECT ON TABLE public.profiles TO authenticated;
