-- קואליציה עיוורת — database setup. Run once in Supabase → SQL Editor.
-- Everything lives in its own schema, "koalitsia", so it never touches other tables in the project.
-- After running: add "koalitsia" to Project Settings → Data API → Exposed schemas.

create schema if not exists koalitsia;

-- Quotes added or edited from the admin screen (the starter bank lives in the page itself)
create table if not exists koalitsia.quotes (
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
create table if not exists koalitsia.plays (
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
create table if not exists koalitsia.admins (email text primary key);
insert into koalitsia.admins (email) values ('doronimrod@gmail.com') on conflict do nothing;

create or replace function koalitsia.is_admin() returns boolean
language sql stable security definer set search_path = koalitsia, pg_temp as $$
  select exists (select 1 from koalitsia.admins where email = lower(coalesce(auth.jwt() ->> 'email','')));
$$;

-- "X% of voters of your party let party Y in" — aggregates only, never rows
create or replace function koalitsia.peer_rates(p_voted text)
returns table (party text, rate numeric, n int)
language sql stable security definer set search_path = koalitsia, pg_temp as $$
  select e.key, avg(case when (e.value ->> 'in')::boolean then 1 else 0 end)::numeric, count(*)::int
  from koalitsia.plays p, jsonb_each(p.picks) as e
  where p.voted = p_voted
  group by e.key;
$$;

-- Row-level security
alter table koalitsia.quotes enable row level security;
alter table koalitsia.plays  enable row level security;
alter table koalitsia.admins enable row level security;   -- no policies: not reachable from the site

drop policy if exists "everyone reads quotes" on koalitsia.quotes;
create policy "everyone reads quotes" on koalitsia.quotes for select using (true);
drop policy if exists "admins write quotes" on koalitsia.quotes;
create policy "admins write quotes" on koalitsia.quotes for all to authenticated
  using (koalitsia.is_admin()) with check (koalitsia.is_admin());

drop policy if exists "anyone saves a finished game" on koalitsia.plays;
create policy "anyone saves a finished game" on koalitsia.plays for insert
  with check (
    jsonb_typeof(picks) = 'object'
    and length(picks::text) < 4000
    and length(voted) <= 40 and length(bloc) <= 20
    and (session is null or length(session) <= 60)
  );
drop policy if exists "admins read games" on koalitsia.plays;
create policy "admins read games" on koalitsia.plays for select to authenticated using (koalitsia.is_admin());

-- Privileges for the website's API roles (row-level security above still decides per row)
grant usage on schema koalitsia to anon, authenticated;
grant select on koalitsia.quotes to anon, authenticated;
grant insert, update, delete on koalitsia.quotes to authenticated;
grant insert on koalitsia.plays to anon, authenticated;
grant select on koalitsia.plays to authenticated;
revoke all on koalitsia.admins from anon, authenticated;
grant execute on function koalitsia.is_admin()       to anon, authenticated;
grant execute on function koalitsia.peer_rates(text) to anon, authenticated;
