-- =====================================================================
-- Red Hills Jamaat Jaman RSVP — initial schema (Supabase / Postgres 15+)
--
-- Who uses it
--   family : logs in with an ITS ID only (no password). Reads their own
--            household, reads events, creates/edits ONLY their own RSVPs.
--   admin  : logs in with their own ITS ID (listed in public.staff, role 'admin')
--            through the `staff-login` function. Creates events, sets thaal
--            settings, sees AGGREGATE counts only (no family names, same as
--            the demo's admin view).
--   cook   : same login, role 'cook'. Can only call cook_upcoming() ->
--            date + thaal count. Nothing else.
--
-- How family login works (no password, so it must never be done from the browser)
--   Browser -> Edge Function `family-login` (uses service role) which:
--     1. checks public.login_is_locked(client_key)
--     2. looks the ITS up in public.households (is_active = true)
--     3. logs the attempt in public.login_attempts
--     4. on success returns name + family_size and a short-lived JWT signed
--        with the project JWT secret:
--          { role:'authenticated', sub:<households.auth_id>, its_id:'10234567',
--            app_role:'family', exp: now()+12h }
--   RLS below trusts those claims, so a family can only ever touch rows
--   where its_id = their own ITS.
--   Admin / cook login is the same idea through `staff-login`, which checks
--   public.staff instead of public.households and mints:
--          { role:'authenticated', sub:<staff.auth_id>, app_role:'admin'|'cook',
--            staff_its:'30464909', exp: now()+8h }
--   There is deliberately NO its_id claim on a staff token, so staff are never
--   mistaken for a family. public.app_role() looks the staff row up on every
--   request, so setting staff.is_active = false cuts access immediately.
--   >>> In Supabase Auth settings, DISABLE public sign-ups. <<<
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Settings (single row)
-- ---------------------------------------------------------------------
create table public.settings (
  id                   boolean primary key default true check (id),   -- enforces one row
  people_per_thaal     int  not null default 8  check (people_per_thaal >= 1),
  buffer_percent       int  not null default 10 check (buffer_percent >= 0),   -- walk-in buffer
  edit_cutoff_hours    int  not null default 24 check (edit_cutoff_hours >= 0),-- RSVP locks this long before start
  members_warn_over    int  not null default 4  check (members_warn_over >= 0),-- "double-check" if members > household size + this
  login_max_fails      int  not null default 10 check (login_max_fails >= 1),  -- per client IP; generous because families share masjid wifi
  login_lock_minutes   int  not null default 15 check (login_lock_minutes >= 1),
  timezone             text not null default 'Asia/Kolkata',
  updated_at           timestamptz not null default now()
);
insert into public.settings default values;


-- ---------------------------------------------------------------------
-- 2. Households  (the valid-ITS list you import: ITS, name, family size)
-- ---------------------------------------------------------------------
create table public.households (
  its_id       text primary key check (its_id ~ '^[0-9]{8}$'),  -- Head of Family ITS
  name         text not null check (length(btrim(name)) > 0),
  family_size  int  not null check (family_size between 1 and 50),
  sector       text,                                            -- optional (area), shown in the demo data
  is_active    boolean not null default true,                   -- false = can no longer log in
  auth_id      uuid not null unique default gen_random_uuid(),  -- becomes JWT "sub" for the family session
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);


-- ---------------------------------------------------------------------
-- 3. Staff (admin / cook) — they log in with their own ITS ID
--    No Supabase Auth account is needed. Managed with the service role / SQL editor.
-- ---------------------------------------------------------------------
create table public.staff (
  its_id      text primary key check (its_id ~ '^[0-9]{8}$'),
  name        text not null check (length(btrim(name)) > 0),
  role        text not null check (role in ('admin', 'cook')),
  is_active   boolean not null default true,
  auth_id     uuid not null unique default gen_random_uuid(),   -- becomes JWT "sub" for the staff session
  created_at  timestamptz not null default now()
);


-- ---------------------------------------------------------------------
-- 4. Hijri calendar (replaces the hand-transcribed tables in index.html)
--    Filled by an import script, not by the app.
-- ---------------------------------------------------------------------
create table public.hijri_months (
  hijri_year   smallint not null,
  month_idx    smallint not null check (month_idx between 0 and 11),  -- 0 = Moharram ... 11 = Zilhijja
  month_name   text     not null,
  starts_on    date     not null,                                     -- Gregorian date of the 1st
  length_days  smallint not null check (length_days in (29, 30)),
  primary key (hijri_year, month_idx)
);

create table public.calendar_occasions (        -- Fatemi occasions, keyed by Hijri month+day (recur yearly)
  id          bigint generated always as identity primary key,
  month_idx   smallint not null check (month_idx between 0 and 11),
  day         smallint not null check (day between 1 and 30),
  name        text not null,
  location    text
);
create index calendar_occasions_md_idx on public.calendar_occasions (month_idx, day);


-- ---------------------------------------------------------------------
-- 5. Jaman events (created by admin)
-- ---------------------------------------------------------------------
create table public.events (
  id                 bigint generated always as identity primary key,
  name               text not null check (length(btrim(name)) > 0),
  venue              text not null default 'Masjid, Main Hall',
  meal               text,                                   -- Lunch / Dinner / Niyaz
  starts_at          timestamptz not null,
  rsvp_closes_at     timestamptz not null,                   -- set by trigger = starts_at - edit_cutoff_hours
  source             text not null default 'custom' check (source in ('calendar', 'custom')),
  occasions          jsonb not null default '[]'::jsonb,     -- snapshot of ticked occasions: [{"n":"...","loc":"..."}]
  hijri_year         smallint,                               -- Hijri date of the occasion (calendar events)
  hijri_month        smallint check (hijri_month between 0 and 11),
  hijri_day          smallint check (hijri_day between 1 and 30),
  actual_attendance  int check (actual_attendance >= 0),     -- entered by admin after the event
  is_cancelled       boolean not null default false,
  created_by         uuid default auth.uid() references public.staff(auth_id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index events_starts_at_idx on public.events (starts_at);


-- ---------------------------------------------------------------------
-- 6. RSVPs — one row per household per event
-- ---------------------------------------------------------------------
create table public.rsvps (
  event_id    bigint not null references public.events(id) on delete cascade,
  its_id      text   not null references public.households(its_id) on update cascade on delete cascade,
  members     int    not null check (members between 0 and 100),       -- people from the home
  guests      int    not null default 0 check (guests between 0 and 100), -- mehmaan visiting Hyderabad
  total       int generated always as (members + guests) stored,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (event_id, its_id)
);
create index rsvps_its_idx on public.rsvps (its_id);


-- ---------------------------------------------------------------------
-- 7. Change log (every submit / edit) and login attempts
-- ---------------------------------------------------------------------
create table public.rsvp_change_log (
  id          bigint generated always as identity primary key,
  event_id    bigint not null references public.events(id) on delete cascade,
  its_id      text   not null,
  from_total  int,                      -- null = first response
  to_total    int    not null,
  changed_at  timestamptz not null default now()
);
create index rsvp_change_log_event_idx on public.rsvp_change_log (event_id, changed_at desc);

create table public.login_attempts (
  id            bigint generated always as identity primary key,
  client_key    text not null,          -- IP (or IP+device) as seen by the edge function
  its_id        text,                   -- what they typed (may not exist)
  success       boolean not null,
  attempted_at  timestamptz not null default now()
);
create index login_attempts_key_idx on public.login_attempts (client_key, attempted_at desc);


-- =====================================================================
-- Helper functions
-- =====================================================================
create or replace function public.set_updated_at() returns trigger
language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

-- ITS of the logged-in family (from the JWT minted by the edge function)
create or replace function public.current_its() returns text
language sql stable as $$
  select nullif(auth.jwt() ->> 'its_id', '')
$$;

-- 'admin' | 'cook' (looked up live in public.staff, so deactivation is immediate)
-- or 'family' (JWT claim, which can never grant staff rights) or null
create or replace function public.app_role() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select s.role from public.staff s where s.auth_id = auth.uid() and s.is_active),
    case when auth.jwt() ->> 'app_role' = 'family' then 'family' end
  )
$$;

-- Always true/false, never NULL: a NULL here would slip through `if not is_admin() ...` checks.
create or replace function public.is_admin() returns boolean
language sql stable as $$ select coalesce(public.app_role() = 'admin', false) $$;

create or replace function public.is_cook() returns boolean
language sql stable as $$ select coalesce(public.app_role() in ('cook', 'admin'), false) $$;

-- true for the service role, the SQL editor and migrations
create or replace function public.is_privileged() returns boolean
language sql stable as $$
  select coalesce(auth.jwt() ->> 'role', 'postgres') in ('service_role', 'postgres', 'supabase_admin')
$$;

-- thaals = ceil(people * (1 + buffer%) / people_per_thaal)
create or replace function public.thaals_for(p_people int) returns int
language sql stable security definer set search_path = public as $$
  select ceil(p_people * (1 + s.buffer_percent / 100.0) / s.people_per_thaal)::int
  from public.settings s
$$;


-- =====================================================================
-- Triggers
-- =====================================================================
create trigger households_updated before update on public.households
  for each row execute function public.set_updated_at();
create trigger settings_updated before update on public.settings
  for each row execute function public.set_updated_at();
create trigger events_updated before update on public.events
  for each row execute function public.set_updated_at();

-- events: derive rsvp_closes_at from starts_at and the cutoff setting
create or replace function public.events_set_close() returns trigger
language plpgsql security definer set search_path = public as $$
declare cutoff int;
begin
  select edit_cutoff_hours into cutoff from public.settings;
  if tg_op = 'INSERT' and new.rsvp_closes_at is null then
    new.rsvp_closes_at := new.starts_at - make_interval(hours => cutoff);
  elsif tg_op = 'UPDATE' and new.starts_at is distinct from old.starts_at
        and new.rsvp_closes_at is not distinct from old.rsvp_closes_at then
    new.rsvp_closes_at := new.starts_at - make_interval(hours => cutoff);
  end if;
  return new;
end $$;
-- (NOT NULL is checked after BEFORE triggers run, so inserts may omit rsvp_closes_at)
create trigger events_close_before before insert or update on public.events
  for each row execute function public.events_set_close();

-- rsvps: the server (not the browser) enforces the 24-hour lock
create or replace function public.rsvps_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare ev public.events;
begin
  select * into ev from public.events where id = new.event_id;
  if not found then
    raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  if tg_op = 'UPDATE' and (new.event_id <> old.event_id or new.its_id <> old.its_id) then
    raise exception 'RSVP_KEY_IMMUTABLE' using errcode = '23514';
  end if;

  -- admin staff go through the service role / office, which may override the lock
  if not public.is_privileged() then
    if ev.is_cancelled then
      raise exception 'EVENT_CANCELLED' using errcode = '23514';
    end if;
    if now() >= ev.rsvp_closes_at then
      raise exception 'RSVP_CLOSED' using errcode = '23514',
        hint = 'Responses are locked. Please contact the masjid office for changes.';
    end if;
  end if;

  new.updated_at := now();
  return new;
end $$;
create trigger rsvps_guard_trg before insert or update on public.rsvps
  for each row execute function public.rsvps_guard();

create or replace function public.rsvps_log() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.rsvp_change_log (event_id, its_id, from_total, to_total)
  values (new.event_id, new.its_id,
          case when tg_op = 'UPDATE' then old.total end,
          new.total);
  return new;
end $$;
create trigger rsvps_log_trg after insert or update on public.rsvps
  for each row execute function public.rsvps_log();


-- =====================================================================
-- Login support (called only by the edge function with the service role)
-- =====================================================================
create or replace function public.login_is_locked(p_client_key text) returns boolean
language sql stable security definer set search_path = public as $$
  -- Failures only. A success does NOT reset the counter, otherwise someone who knows one
  -- valid ITS could interleave it with guesses and never get locked.
  select (
    select count(*) from public.login_attempts a, public.settings s
    where a.client_key = p_client_key
      and not a.success
      and a.attempted_at > now() - make_interval(mins => s.login_lock_minutes)
  ) >= (select login_max_fails from public.settings)
$$;


-- =====================================================================
-- Reporting functions (aggregates only — no family names or ITS numbers)
-- =====================================================================

-- Admin dashboard numbers for one event
create or replace function public.event_summary(p_event_id bigint)
returns table (
  members int, guests int, total int, thaals int,
  households_responded int, households_total int,
  actual_attendance int, gap int, gap_percent int
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() and not public.is_privileged() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  return query
  with r as (
    select coalesce(sum(x.members), 0)::int as m,
           coalesce(sum(x.guests), 0)::int  as g,
           count(*)::int                    as n
    from public.rsvps x where x.event_id = p_event_id
  ), e as (
    select ev.actual_attendance as act from public.events ev where ev.id = p_event_id
  )
  select r.m, r.g, r.m + r.g, public.thaals_for(r.m + r.g),
         r.n, (select count(*)::int from public.households h where h.is_active),
         e.act,
         case when e.act is not null then e.act - (r.m + r.g) end,
         case when e.act is not null and (r.m + r.g) > 0
              then round((e.act - (r.m + r.g)) * 100.0 / (r.m + r.g))::int end
  from r, e;
end $$;

-- Recent RSVP changes for the admin "Change log" card (event + counts, no names)
create or replace function public.admin_change_log(p_limit int default 20)
returns table (changed_at timestamptz, event_name text, from_total int, to_total int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() and not public.is_privileged() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  return query
  select l.changed_at, e.name, l.from_total, l.to_total
  from public.rsvp_change_log l join public.events e on e.id = l.event_id
  order by l.changed_at desc
  limit least(greatest(p_limit, 1), 200);
end $$;

-- Cook view: one line per day = date + thaal count (events on the same day are summed)
create or replace function public.cook_upcoming()
returns table (event_date date, people int, thaals int)
language plpgsql stable security definer set search_path = public as $$
declare tz text;
begin
  if not public.is_cook() and not public.is_privileged() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  select timezone into tz from public.settings;
  return query
  select (e.starts_at at time zone tz)::date                      as d,
         coalesce(sum(r.total), 0)::int                           as p,
         public.thaals_for(coalesce(sum(r.total), 0)::int)        as t
  from public.events e
  left join public.rsvps r on r.event_id = e.id
  where not e.is_cancelled
    and (e.starts_at at time zone tz)::date >= (now() at time zone tz)::date
  group by 1
  order by 1;
end $$;


-- =====================================================================
-- Row Level Security
-- =====================================================================
alter table public.settings           enable row level security;
alter table public.households         enable row level security;
alter table public.staff              enable row level security;   -- no policies: service role only
alter table public.hijri_months       enable row level security;
alter table public.calendar_occasions enable row level security;
alter table public.events             enable row level security;
alter table public.rsvps              enable row level security;
alter table public.rsvp_change_log    enable row level security;   -- no policies: functions only
alter table public.login_attempts     enable row level security;   -- no policies: service role only

-- settings: admin only (families get what they need from the login response)
create policy settings_admin_read   on public.settings for select to authenticated using (public.is_admin());
create policy settings_admin_update on public.settings for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- households: a family sees only its own row; staff never read this table
-- (import and edits are done with the service role / SQL editor)
create policy households_self_read on public.households for select to authenticated
  using (its_id = public.current_its());

-- calendar: admin reads; writes via service role
create policy hijri_admin_read on public.hijri_months       for select to authenticated using (public.is_admin());
create policy occ_admin_read   on public.calendar_occasions for select to authenticated using (public.is_admin());

-- events: families and admin can read; only admin writes
create policy events_read on public.events for select to authenticated
  using (public.current_its() is not null or public.is_admin());
create policy events_admin_insert on public.events for insert to authenticated with check (public.is_admin());
create policy events_admin_update on public.events for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy events_admin_delete on public.events for delete to authenticated using (public.is_admin());

-- rsvps: a family reads/creates/edits only its own; the trigger enforces the lock
-- (admins see totals via event_summary(), never individual rows; no deletes)
create policy rsvps_self_read   on public.rsvps for select to authenticated using (its_id = public.current_its());
create policy rsvps_self_insert on public.rsvps for insert to authenticated with check (its_id = public.current_its());
create policy rsvps_self_update on public.rsvps for update to authenticated
  using (its_id = public.current_its()) with check (its_id = public.current_its());


-- =====================================================================
-- Privileges (RLS above does the row filtering; this removes everything else)
-- =====================================================================
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
-- and make new tables/functions private by default (grant explicitly when needed)
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;

grant select                 on public.settings, public.households,
                                public.hijri_months, public.calendar_occasions to authenticated;
grant update                 on public.settings to authenticated;
grant select, insert, update, delete on public.events to authenticated;
grant select, insert, update on public.rsvps to authenticated;

-- RLS policies call these, so signed-in users must be able to execute them
grant execute on function public.current_its(), public.app_role(), public.is_admin(),
                          public.is_cook(), public.is_privileged() to authenticated;
-- app-facing report functions (each re-checks the role internally)
grant execute on function public.event_summary(bigint), public.admin_change_log(int),
                          public.cook_upcoming() to authenticated;
-- login_is_locked() / thaals_for() stay service-role only