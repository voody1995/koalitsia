-- קואליציה עיוורת — database setup. Run once in Supabase → SQL Editor.

-- Quotes added or edited from the admin screen (the starter bank lives in the page itself)
create table if not exists public.quotes (
  id          text primary key,
  party       text not null,
  appeal      text,
  text        text,
  context     text default '',
  source      text default '',
  date        text default '',
  url         text default '',
  active      boolean not null default true,
  deleted     boolean not null default false,
  updated_at  timestamptz not null default now()
);

-- One row per finished game. No names, only a random per-browser id.
create table if not exists public.plays (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  session     text,
  voted       text not null,
  bloc        text not null,
  seats       int  not null check (seats between 0 and 120),
  formed      boolean not null,
  picks       jsonb not null
);

-- Who may manage quotes and read statistics
create table if not exists public.admins (email text primary key);
insert into public.admins (email) values ('doronimrod@gmail.com') on conflict do nothing;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where email = lower(coalesce(auth.jwt() ->> 'email','')));
$$;

-- Row-level security
alter table public.quotes enable row level security;
alter table public.plays  enable row level security;
alter table public.admins enable row level security;   -- no policies: not reachable from the site

drop policy if exists "everyone reads quotes" on public.quotes;
create policy "everyone reads quotes" on public.quotes for select using (true);
drop policy if exists "admins write quotes" on public.quotes;
create policy "admins write quotes" on public.quotes for all
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "anyone saves a finished game" on public.plays;
create policy "anyone saves a finished game" on public.plays for insert
  with check (
    jsonb_typeof(picks) = 'object'
    and length(picks::text) < 4000
    and length(voted) <= 40 and length(bloc) <= 20
    and (session is null or length(session) <= 60)
  );
drop policy if exists "admins read games" on public.plays;
create policy "admins read games" on public.plays for select using (public.is_admin());

-- "X% of voters of your party let party Y in" — aggregates only, no rows
create or replace function public.peer_rates(p_voted text)
returns table (party text, rate numeric, n int)
language sql stable security definer set search_path = public as $$
  select e.key, avg(case when (e.value ->> 'in')::boolean then 1 else 0 end)::numeric, count(*)::int
  from plays, jsonb_each(plays.picks) as e
  where plays.voted = p_voted
  group by e.key;
$$;

grant execute on function public.is_admin()        to anon, authenticated;
grant execute on function public.peer_rates(text)  to anon, authenticated;
