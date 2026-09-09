-- ============================================================
-- Sweaty Sharpe's Survivor Fantasy — FULL RESET
-- This is the complete, current-state schema. Run this instead of
-- trying to figure out which old patches did or didn't apply.
-- Safe to run on a fresh project OR to reset an existing one --
-- the DROP block at the top clears everything first.
-- ============================================================

-- ---------- DROP EVERYTHING (safe if it doesn't exist yet) ----------
drop function if exists commissioner_grant_second_chance(uuid) cascade;
drop function if exists commissioner_finalize_week(int) cascade;
drop function if exists commissioner_set_player_approved(uuid, boolean) cascade;
drop function if exists commissioner_update_prize_settings(numeric, numeric, numeric, numeric, int) cascade;
drop function if exists commissioner_set_signup_deadline(timestamptz) cascade;
drop function if exists commissioner_update_weekly_threshold(numeric) cascade;
drop function if exists commissioner_set_score(uuid, numeric) cascade;
drop function if exists submit_slot_pick(int, text, text) cascade;
drop function if exists generate_season_weeks(date) cascade;
drop trigger if exists on_auth_user_created on auth.users;
drop function if exists handle_new_user() cascade;
drop table if exists picks cascade;
drop table if exists games cascade;
drop table if exists nfl_players cascade;
drop table if exists lineup_slots cascade;
drop table if exists weeks cascade;
drop table if exists league_settings cascade;
drop table if exists profiles cascade;

-- ---------- Profiles ----------
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  is_commissioner boolean not null default false,
  is_approved boolean not null default false,
  second_chance_used boolean not null default false,
  alive boolean not null default true,
  eliminated_week int,
  created_at timestamptz not null default now()
);

create function handle_new_user() returns trigger as $$
declare
  v_deadline timestamptz;
  v_display_name text;
  v_is_first boolean;
begin
  select signup_closes_at into v_deadline from public.league_settings where id = 1;
  if v_deadline is not null and now() > v_deadline then
    raise exception 'Signups for this league have closed.';
  end if;

  v_display_name := coalesce(
    nullif(trim(new.raw_user_meta_data->>'display_name'), ''),
    'Player-' || substr(new.id::text, 1, 6)
  );

  v_is_first := (select count(*) from public.profiles) = 0;

  insert into public.profiles (id, display_name, is_commissioner, is_approved)
  values (new.id, v_display_name, v_is_first, v_is_first);
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ---------- League settings ----------
create table league_settings (
  id smallint primary key default 1,
  weekly_threshold numeric not null default 100,
  signup_closes_at timestamptz,
  entry_fee numeric,
  organizer_pct numeric not null default 5,
  weekly_pct numeric not null default 15,
  grand_pct numeric not null default 80,
  weekly_prize_end_week int default 10
);
insert into league_settings (id) values (1);

-- ---------- Weeks ----------
create table weeks (
  week_number int primary key,
  opens_at timestamptz not null,
  closes_at timestamptz not null,
  is_finalized boolean not null default false
);

create function generate_season_weeks(season_first_wednesday date)
returns void as $$
begin
  insert into weeks (week_number, opens_at, closes_at)
  select
    n,
    (season_first_wednesday + (n-1)*7) ::timestamp at time zone 'America/Chicago' + interval '6 hours',
    (season_first_wednesday + (n-1)*7 + 4) ::timestamp at time zone 'America/Chicago' + interval '12 hours'
  from generate_series(1, 18) as n;
end;
$$ language plpgsql;

select generate_season_weeks('2026-09-09');

-- ---------- Lineup slots (1 QB, 2 RB, 3 WR, 1 TE) ----------
create table lineup_slots (
  slot text primary key,
  position text not null,
  sort_order int not null
);
insert into lineup_slots (slot, position, sort_order) values
  ('QB','QB',1), ('RB1','RB',2), ('RB2','RB',3),
  ('WR1','WR',4), ('WR2','WR',5), ('WR3','WR',6), ('TE','TE',7);

-- ---------- NFL players (roster reference data) ----------
create extension if not exists pg_trgm;

create table nfl_players (
  id text primary key,
  full_name text not null,
  position text not null,
  team text,
  active boolean not null default true
);
create index nfl_players_name_idx on nfl_players using gin (full_name gin_trgm_ops);

-- ---------- Games (real kickoff times per team per week) ----------
create table games (
  week_number int not null references weeks(week_number),
  team text not null,
  kickoff_at timestamptz not null,
  primary key (week_number, team)
);

-- ---------- Picks ----------
create table picks (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references profiles(id) on delete cascade,
  week_number int not null references weeks(week_number),
  slot text not null references lineup_slots(slot),
  nfl_player_id text not null references nfl_players(id),
  nfl_player_name text not null,
  position text not null,
  team text not null,
  score numeric,
  result text,
  locked_at timestamptz not null default now(),
  unique (player_id, week_number, slot)
);

-- ---------- Row Level Security ----------
alter table profiles enable row level security;
alter table league_settings enable row level security;
alter table weeks enable row level security;
alter table lineup_slots enable row level security;
alter table nfl_players enable row level security;
alter table games enable row level security;
alter table picks enable row level security;

create policy "read profiles" on profiles for select using (true);
create policy "read settings" on league_settings for select using (true);
create policy "read weeks" on weeks for select using (true);
create policy "read lineup_slots" on lineup_slots for select using (true);
create policy "read nfl_players" on nfl_players for select using (true);
create policy "read games" on games for select using (true);

create policy "read picks" on picks for select using (
  player_id = auth.uid()
  or coalesce(
       (select kickoff_at from games g where g.week_number = picks.week_number and g.team = picks.team),
       (select closes_at from weeks w where w.week_number = picks.week_number)
     ) < now()
);

-- No insert/update policies for players on any table -- all writes go
-- through the functions below.

-- ---------- Player actions ----------
create function submit_slot_pick(p_week int, p_slot text, p_player_ref text)
returns void as $$
declare
  v_alive boolean;
  v_approved boolean;
  v_opens timestamptz;
  v_closes timestamptz;
  v_existing int;
  v_expected_position text;
  v_name text;
  v_position text;
  v_team text;
  v_kickoff timestamptz;
  v_prior_use int;
begin
  select alive, is_approved into v_alive, v_approved from profiles where id = auth.uid();
  if v_alive is null or v_alive = false then
    raise exception 'You are not an active player in this league.';
  end if;
  if v_approved = false then
    raise exception 'Your entry hasn''t been approved yet — check with the commissioner.';
  end if;

  select opens_at, closes_at into v_opens, v_closes from weeks where week_number = p_week;
  if now() < v_opens or now() > v_closes then
    raise exception 'This week''s picks are not open right now.';
  end if;

  select position into v_expected_position from lineup_slots where slot = p_slot;
  if v_expected_position is null then
    raise exception 'Unrecognized roster slot: %', p_slot;
  end if;

  select count(*) into v_existing from picks
    where player_id = auth.uid() and week_number = p_week and slot = p_slot;
  if v_existing > 0 then
    raise exception 'You''ve already locked in your % pick for this week — it can''t be changed.', p_slot;
  end if;

  select full_name, position, team into v_name, v_position, v_team
    from nfl_players where id = p_player_ref and active = true;
  if v_name is null then
    raise exception 'That player isn''t in the current active list — try searching again.';
  end if;
  if v_position <> v_expected_position then
    raise exception '% must be a % — you picked a %.', p_slot, v_expected_position, v_position;
  end if;

  select kickoff_at into v_kickoff from games where week_number = p_week and team = v_team;
  if v_kickoff is null then
    raise exception '% is on a bye this week — pick someone else.', v_name;
  end if;
  if now() >= v_kickoff then
    raise exception '%''s game has already started — pick someone whose game hasn''t kicked off yet.', v_name;
  end if;

  select count(*) into v_prior_use from picks
    where player_id = auth.uid() and nfl_player_id = p_player_ref;
  if v_prior_use > 0 then
    raise exception 'You''ve already used % this season.', v_name;
  end if;

  insert into picks (player_id, week_number, slot, nfl_player_id, nfl_player_name, position, team)
  values (auth.uid(), p_week, p_slot, p_player_ref, v_name, v_position, v_team);
end;
$$ language plpgsql security definer;

-- ---------- Commissioner actions ----------
create function commissioner_set_score(p_pick_id uuid, p_score numeric)
returns void as $$
begin
  if not (select is_commissioner from profiles where id = auth.uid()) then
    raise exception 'Commissioner only.';
  end if;
  update picks set score = p_score where id = p_pick_id;
end;
$$ language plpgsql security definer;

create function commissioner_update_weekly_threshold(p_threshold numeric)
returns void as $$
begin
  if not (select is_commissioner from profiles where id = auth.uid()) then
    raise exception 'Commissioner only.';
  end if;
  update league_settings set weekly_threshold = p_threshold where id = 1;
end;
$$ language plpgsql security definer;

create function commissioner_set_signup_deadline(p_deadline timestamptz)
returns void as $$
begin
  if not (select is_commissioner from profiles where id = auth.uid()) then
    raise exception 'Commissioner only.';
  end if;
  update league_settings set signup_closes_at = p_deadline where id = 1;
end;
$$ language plpgsql security definer;

create function commissioner_update_prize_settings(
  p_entry_fee numeric, p_organizer_pct numeric, p_weekly_pct numeric,
  p_grand_pct numeric, p_weekly_prize_end_week int
)
returns void as $$
begin
  if not (select is_commissioner from profiles where id = auth.uid()) then
    raise exception 'Commissioner only.';
  end if;
  update league_settings set
    entry_fee = p_entry_fee, organizer_pct = p_organizer_pct, weekly_pct = p_weekly_pct,
    grand_pct = p_grand_pct, weekly_prize_end_week = p_weekly_prize_end_week
  where id = 1;
end;
$$ language plpgsql security definer;

create function commissioner_set_player_approved(p_player_id uuid, p_approved boolean)
returns void as $$
begin
  if not (select is_commissioner from profiles where id = auth.uid()) then
    raise exception 'Commissioner only.';
  end if;
  update profiles set is_approved = p_approved where id = p_player_id;
end;
$$ language plpgsql security definer;

-- Second-chance buy-in: only for players eliminated in week 5 or earlier,
-- one-time use, keeps all their previously-used players excluded going forward
create function commissioner_grant_second_chance(p_player_id uuid)
returns void as $$
declare
  v_week int;
  v_used boolean;
begin
  if not (select is_commissioner from profiles where id = auth.uid()) then
    raise exception 'Commissioner only.';
  end if;
  select eliminated_week, second_chance_used into v_week, v_used from profiles where id = p_player_id;
  if v_used then
    raise exception 'This player has already used their second chance.';
  end if;
  if v_week is null or v_week > 5 then
    raise exception 'Second chance is only available for players eliminated in week 5 or earlier.';
  end if;
  update profiles set alive = true, eliminated_week = null, second_chance_used = true
  where id = p_player_id;
end;
$$ language plpgsql security definer;

create function commissioner_finalize_week(p_week int)
returns void as $$
declare
  r record;
  v_threshold numeric;
  v_incomplete text;
begin
  if not (select is_commissioner from profiles where id = auth.uid()) then
    raise exception 'Commissioner only.';
  end if;

  select weekly_threshold into v_threshold from league_settings where id = 1;

  update profiles set alive = false, eliminated_week = p_week
  where alive = true
  and is_approved = true
  and (
    select count(*) from picks where player_id = profiles.id and week_number = p_week
  ) < (select count(*) from lineup_slots);

  select string_agg(p.display_name, ', ') into v_incomplete
  from profiles p
  where p.alive = true
  and exists (
    select 1 from picks where player_id = p.id and week_number = p_week and score is null
  );

  if v_incomplete is not null then
    raise exception 'Not ready to finalize -- scores still missing for: %', v_incomplete;
  end if;

  for r in
    select player_id, sum(score) as total
    from picks
    where week_number = p_week
    group by player_id
  loop
    if r.total >= v_threshold then
      update picks set result = 'pass' where player_id = r.player_id and week_number = p_week;
      update profiles set alive = true, eliminated_week = null
        where id = r.player_id and eliminated_week = p_week;
    else
      update picks set result = 'fail' where player_id = r.player_id and week_number = p_week;
      update profiles set alive = false, eliminated_week = p_week where id = r.player_id;
    end if;
  end loop;

  update weeks set is_finalized = true where week_number = p_week;
end;
$$ language plpgsql security definer;
