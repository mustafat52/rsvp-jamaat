-- =====================================================================
-- Seed data. Run in the Supabase SQL editor (or via `supabase db reset` locally).
-- =====================================================================

-- A) DEMO ONLY — the 8 sample families from the front-end demo.
--    Delete these before loading real data:  delete from public.households;
insert into public.households (its_id, name, sector, family_size) values
  ('10234567', 'Mohammed bhai Saifee',      'Tolichowki',    5),
  ('10345678', 'Abbas bhai Nalwala',        'Banjara Hills', 4),
  ('10456789', 'Fatema ben Kapadia',        'Mehdipatnam',   2),
  ('10567890', 'Husain bhai Lokhandwala',   'Tolichowki',    6),
  ('10678901', 'Taher bhai Ujjaini',        'Attapur',       3),
  ('10789012', 'Yusuf bhai Bhopalwala',     'Banjara Hills', 7),
  ('10890123', 'Zainab ben Rangwala',       'Malakpet',      4),
  ('10901234', 'Ali Asgar bhai Dahodwala',  'Mehdipatnam',   5)
on conflict (its_id) do nothing;

-- B) REAL IMPORT — the valid-ITS list.
--    Easiest: Table Editor -> households -> Insert -> Import data from CSV
--    with columns:  its_id,name,family_size,sector   (sector may be blank)
--
--    Or re-runnable from SQL: load the CSV into a staging table, then upsert.
--    create table public._households_import (its_id text, name text, family_size int, sector text);
--    -- (import the CSV into _households_import with the Table Editor, then:)
--    insert into public.households (its_id, name, family_size, sector)
--    select btrim(its_id), btrim(name), family_size, nullif(btrim(sector), '')
--    from public._households_import
--    on conflict (its_id) do update
--      set name = excluded.name, family_size = excluded.family_size,
--          sector = excluded.sector, is_active = true;
--    drop table public._households_import;
--
--    People who leave the list: set is_active = false (keeps their past RSVPs):
--    update public.households set is_active = false where its_id = '10234567';

-- C) STAFF — admin / cook log in with their own ITS ID (no email account needed).
--    The admin panel login is ITS 30464909.
insert into public.staff (its_id, name, role) values
  ('30464909', 'Jamaat Admin', 'admin')
on conflict (its_id) do update set role = excluded.role, is_active = true;

--    Add the kitchen login whenever you have their ITS:
--    insert into public.staff (its_id, name, role) values ('XXXXXXXX', 'Kitchen', 'cook');
--    Remove access instantly (works on already-issued sessions too):
--    update public.staff set is_active = false where its_id = 'XXXXXXXX';