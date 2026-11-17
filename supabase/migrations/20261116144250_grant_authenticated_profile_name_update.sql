-- Allow users to update only their own display name.
-- RLS, moderation checks, and security-field triggers remain in force.
GRANT UPDATE (full_name) ON TABLE public.profiles TO authenticated;
