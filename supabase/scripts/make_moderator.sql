-- Make an existing account a moderator (or a player again).
-- Run in the Supabase SQL Editor. The person must have signed up first.
-- They see the change the next time they log in.
--
-- Replace the email below, then run the whole file.

update public.profiles
set role = 'moderator'          -- or 'player' to demote
where id = (select id from auth.users where lower(email) = lower('someone@example.com'));

-- Check: should list the account with its new role.
select p.display_name, u.email, p.role
from public.profiles p
join auth.users u on u.id = p.id
order by p.role desc, u.email;
