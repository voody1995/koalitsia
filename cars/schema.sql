-- שמות לרכבים — database setup. Run once in Supabase → SQL Editor (safe to run again).
-- Everything lives in its own schema, "car_names", so it never touches the game's tables.
-- After running: add "car_names" to Project Settings → Data API → Exposed schemas.
--
-- The site never reads tables directly. Every action goes through a function below, so the
-- public board only ever sees counts — never who proposed or who voted. Only admins see names.

create schema if not exists car_names;

-- ---------- tables ----------

create table if not exists car_names.settings (
  id        int primary key default 1 check (id = 1),
  deadline  timestamptz not null
);
-- Monday 9.11.2026 at 12:00 Israel time
insert into car_names.settings (id, deadline) values (1, '2026-11-09 12:00:00+02') on conflict (id) do nothing;

create table if not exists car_names.admins (email text primary key);
insert into car_names.admins (email) values ('doronimrod@gmail.com') on conflict do nothing;

create table if not exists car_names.proposals (
  id            bigint generated always as identity primary key,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz,
  author        uuid not null,
  author_email  text,
  author_name   text,
  n603          text,            -- 571-55-603, Ioniq 5 (today: ויצמן)
  n703          text,            -- 571-54-703, Ioniq 5 (today: זלמן)
  nmg           text not null,   -- 858-60-204, MG S6 (new)
  idea          text,            -- the line that ties the names together
  key           text not null,   -- normalized names, for duplicate detection
  constraint ioniqs_together check ((n603 is null) = (n703 is null)),
  constraint name_lengths check (
    length(nmg) between 1 and 30
    and (n603 is null or length(n603) between 1 and 30)
    and (n703 is null or length(n703) between 1 and 30)
    and (idea is null or length(idea) <= 140))
);
create unique index if not exists proposals_key on car_names.proposals (key);

create table if not exists car_names.votes (
  proposal_id  bigint not null references car_names.proposals (id) on delete cascade,
  voter        uuid not null,
  voter_email  text,
  voter_name   text,
  v            smallint not null check (v in (1, -1)),   -- 1 = like, -1 = boo
  at           timestamptz not null default now(),
  primary key (proposal_id, voter)
);

create table if not exists car_names.visits (
  id     bigint generated always as identity primary key,
  at     timestamptz not null default now(),
  uid    uuid,
  email  text,
  name   text
);

-- No policies at all: the tables are unreachable from the site except through the functions below.
alter table car_names.settings  enable row level security;
alter table car_names.admins    enable row level security;
alter table car_names.proposals enable row level security;
alter table car_names.votes     enable row level security;
alter table car_names.visits    enable row level security;
revoke all on all tables in schema car_names from anon, authenticated;

-- ---------- helpers ----------

-- Trim, collapse spaces, empty → null
create or replace function car_names.clean(t text) returns text
language sql immutable as $$
  select nullif(regexp_replace(btrim(coalesce(t, '')), '\s+', ' ', 'g'), '');
$$;

-- For duplicate detection: lowercase, drop niqqud/spaces/punctuation, final letters → regular
create or replace function car_names.norm(t text) returns text
language sql immutable as $$
  select translate(regexp_replace(lower(coalesce(t, '')), '[^a-z0-9א-ת]', '', 'g'), 'ךםןףץ', 'כמנפצ');
$$;

create or replace function car_names.my_email() returns text
language sql stable as $$ select lower(coalesce(auth.jwt() ->> 'email', '')); $$;

create or replace function car_names.my_name() returns text
language sql stable as $$
  select coalesce(auth.jwt() -> 'user_metadata' ->> 'full_name', auth.jwt() -> 'user_metadata' ->> 'name', auth.jwt() ->> 'email');
$$;

create or replace function car_names.is_admin() returns boolean
language sql stable security definer set search_path = car_names, pg_temp as $$
  select exists (select 1 from car_names.admins where email = car_names.my_email());
$$;

create or replace function car_names.is_closed() returns boolean
language sql stable security definer set search_path = car_names, pg_temp as $$
  select now() >= (select deadline from car_names.settings where id = 1);
$$;

-- ---------- public API ----------

-- Everything the board needs: counts only, plus which proposals are mine and how I voted
create or replace function car_names.board() returns jsonb
language sql stable security definer set search_path = car_names, pg_temp as $$
  select jsonb_build_object(
    'now',      now(),
    'deadline', (select deadline from car_names.settings where id = 1),
    'is_admin', car_names.is_admin(),
    'proposals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'created_at', p.created_at,
        'n603', p.n603, 'n703', p.n703, 'nmg', p.nmg, 'idea', p.idea,
        'likes', (select count(*) from car_names.votes x where x.proposal_id = p.id and x.v = 1),
        'boos',  (select count(*) from car_names.votes x where x.proposal_id = p.id and x.v = -1),
        'mine',  p.author = auth.uid(),
        'my_vote', (select x.v from car_names.votes x where x.proposal_id = p.id and x.voter = auth.uid())
      ) order by p.id)
      from car_names.proposals p), '[]'::jsonb));
$$;

-- Returns {"id": n} or, if the exact same names were already proposed, {"dup": n}
create or replace function car_names.propose(p603 text, p703 text, pmg text, pidea text) returns jsonb
language plpgsql volatile security definer set search_path = car_names, pg_temp as $$
declare
  a text := car_names.clean(p603); b text := car_names.clean(p703);
  c text := car_names.clean(pmg);  i text := car_names.clean(pidea);
  k text; d bigint; nid bigint;
begin
  if auth.uid() is null then raise exception 'login'; end if;
  if car_names.is_closed() then raise exception 'closed'; end if;
  if c is null then raise exception 'mg_required'; end if;
  if (a is null) <> (b is null) then raise exception 'ioniqs_together'; end if;
  if (select count(*) from car_names.proposals where author = auth.uid() and created_at > now() - interval '1 minute') >= 10 then
    raise exception 'slow_down';
  end if;
  k := car_names.norm(a) || '|' || car_names.norm(b) || '|' || car_names.norm(c);
  select id into d from car_names.proposals where key = k;
  if found then return jsonb_build_object('dup', d); end if;
  insert into car_names.proposals (author, author_email, author_name, n603, n703, nmg, idea, key)
  values (auth.uid(), car_names.my_email(), car_names.my_name(), a, b, c, i, k)
  returning id into nid;
  return jsonb_build_object('id', nid);
end $$;

-- Fix a typo: only the author, only within 5 minutes of proposing
create or replace function car_names.edit(pid bigint, p603 text, p703 text, pmg text, pidea text) returns jsonb
language plpgsql volatile security definer set search_path = car_names, pg_temp as $$
declare
  a text := car_names.clean(p603); b text := car_names.clean(p703);
  c text := car_names.clean(pmg);  i text := car_names.clean(pidea);
  k text; d bigint;
begin
  if car_names.is_closed() then raise exception 'closed'; end if;
  if not exists (select 1 from car_names.proposals where id = pid and author = auth.uid()
                 and created_at > now() - interval '5 minutes') then
    raise exception 'edit_window';
  end if;
  if c is null then raise exception 'mg_required'; end if;
  if (a is null) <> (b is null) then raise exception 'ioniqs_together'; end if;
  k := car_names.norm(a) || '|' || car_names.norm(b) || '|' || car_names.norm(c);
  select id into d from car_names.proposals where key = k and id <> pid;
  if found then return jsonb_build_object('dup', d); end if;
  update car_names.proposals set n603 = a, n703 = b, nmg = c, idea = i, key = k, updated_at = now() where id = pid;
  return jsonb_build_object('id', pid);
end $$;

-- Delete: the author within 5 minutes, or an admin at any time
create or replace function car_names.remove(pid bigint) returns void
language plpgsql volatile security definer set search_path = car_names, pg_temp as $$
begin
  if car_names.is_admin() then
    delete from car_names.proposals where id = pid;
    return;
  end if;
  if car_names.is_closed() then raise exception 'closed'; end if;
  delete from car_names.proposals where id = pid and author = auth.uid() and created_at > now() - interval '5 minutes';
  if not found then raise exception 'edit_window'; end if;
end $$;

-- pv: 1 = like, -1 = boo, 0 = take back my vote
create or replace function car_names.vote(pid bigint, pv int) returns void
language plpgsql volatile security definer set search_path = car_names, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'login'; end if;
  if car_names.is_closed() then raise exception 'closed'; end if;
  if pv not in (1, -1, 0) then raise exception 'bad_vote'; end if;
  if pv = 0 then
    delete from car_names.votes where proposal_id = pid and voter = auth.uid();
  else
    insert into car_names.votes (proposal_id, voter, voter_email, voter_name, v)
    values (pid, auth.uid(), car_names.my_email(), car_names.my_name(), pv)
    on conflict (proposal_id, voter) do update set v = excluded.v, at = now();
  end if;
end $$;

create or replace function car_names.visit() returns void
language sql volatile security definer set search_path = car_names, pg_temp as $$
  insert into car_names.visits (uid, email, name)
  select auth.uid(), car_names.my_email(), car_names.my_name() where auth.uid() is not null;
$$;

-- ---------- admin ----------

create or replace function car_names.admin_board() returns jsonb
language plpgsql stable security definer set search_path = car_names, pg_temp as $$
begin
  if not car_names.is_admin() then raise exception 'not_admin'; end if;
  return jsonb_build_object(
    'proposals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'created_at', p.created_at, 'updated_at', p.updated_at,
        'n603', p.n603, 'n703', p.n703, 'nmg', p.nmg, 'idea', p.idea,
        'author_name', p.author_name, 'author_email', p.author_email,
        'likers', coalesce((select jsonb_agg(jsonb_build_object('name', x.voter_name, 'email', x.voter_email) order by x.at)
                            from car_names.votes x where x.proposal_id = p.id and x.v = 1), '[]'::jsonb),
        'booers', coalesce((select jsonb_agg(jsonb_build_object('name', x.voter_name, 'email', x.voter_email) order by x.at)
                            from car_names.votes x where x.proposal_id = p.id and x.v = -1), '[]'::jsonb)
      ) order by p.id)
      from car_names.proposals p), '[]'::jsonb),
    'visitors', coalesce((
      select jsonb_agg(jsonb_build_object('name', t.name, 'email', t.email, 'count', t.n, 'first', t.first, 'last', t.last) order by t.last desc)
      from (select email, max(name) as name, count(*) as n, min(at) as first, max(at) as last
            from car_names.visits group by email) t), '[]'::jsonb),
    'total_visits', (select count(*) from car_names.visits)
  );
end $$;

-- ---------- privileges ----------

grant usage on schema car_names to anon, authenticated;
revoke all on all functions in schema car_names from public, anon, authenticated;
grant execute on function car_names.board()                              to authenticated;
grant execute on function car_names.propose(text, text, text, text)      to authenticated;
grant execute on function car_names.edit(bigint, text, text, text, text) to authenticated;
grant execute on function car_names.remove(bigint)                       to authenticated;
grant execute on function car_names.vote(bigint, int)                    to authenticated;
grant execute on function car_names.visit()                              to authenticated;
grant execute on function car_names.admin_board()                        to authenticated;
