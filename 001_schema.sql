-- ============================================================
-- 001_schema.sql  |  Bubble Pop rewards module: tables + RLS
-- Run in Supabase SQL editor (or `supabase db push`).
-- Money-like tables are READ-ONLY for clients; all writes go
-- through SECURITY DEFINER functions in 002_functions.sql.
-- ============================================================

create extension if not exists pgcrypto;

-- ---------- helpers ----------
-- Server-authoritative "game day" (IST-based reset at 00:00 Asia/Kolkata)
create or replace function public.game_day() returns date
language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

-- ---------- remote config (feature 35) ----------
create table if not exists public.remote_config (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);
insert into public.remote_config(key, value) values
  ('rewards',  '{"place":[100,50,25],"login":[50,100,150,200,300,400,500],"ad_coins":500,"ad_daily_max":5,"ad_cooldown_s":60,"share_daily_max":3,"share_cooldown_s":600,"story_bonus":200,"referral_coins":500,"freeze_cost":300,"freeze_monthly_max":3,"chest_hours":4,"chest_min":20,"chest_max":120,"comeback_days":3,"comeback_coins":300,"interstitial_every":3,"review_after_games":3,"piggy_cap":2000,"piggy_price_inr":99,"season_days":30,"xp_per_game":20,"xp_win_bonus":30,"premium_multiplier":2,"mission_coins":[60,80,120]}'),
  ('spin',     '[{"type":"coins","amount":50,"w":30},{"type":"coins","amount":100,"w":25},{"type":"coins","amount":200,"w":15},{"type":"coins","amount":500,"w":5},{"type":"xp","amount":50,"w":15},{"type":"item","item_id":"skin_gold","w":2},{"type":"coins","amount":25,"w":8}]'),
  ('shop',     '[{"id":"char_cat","kind":"character","name":"Cat","price":0,"collection":"animals"},{"id":"char_dog","kind":"character","name":"Dog","price":500,"collection":"animals"},{"id":"char_fox","kind":"character","name":"Fox","price":800,"collection":"animals"},{"id":"char_panda","kind":"character","name":"Panda","price":1200,"collection":"animals"},{"id":"skin_gold","kind":"skin","name":"Golden Bubbles","price":1500,"collection":"skins"},{"id":"skin_neon","kind":"skin","name":"Neon Bubbles","price":900,"collection":"skins"},{"id":"skin_candy","kind":"skin","name":"Candy Bubbles","price":700,"collection":"skins"},{"id":"theme_night","kind":"theme","name":"Night Sky","price":600,"collection":"themes"},{"id":"theme_ocean","kind":"theme","name":"Ocean","price":600,"collection":"themes"}]'),
  ('collections','{"animals":{"bonus":500},"skins":{"bonus":800},"themes":{"bonus":400}}'),
  ('iap',      '[{"sku":"remove_ads","type":"remove_ads"},{"sku":"coins_small","type":"coins","coins":1000},{"sku":"coins_medium","type":"coins","coins":3000},{"sku":"coins_large","type":"coins","coins":8000},{"sku":"starter_pack","type":"starter","coins":2500,"items":["skin_neon"]},{"sku":"piggy_unlock","type":"piggy"},{"sku":"premium_monthly","type":"premium","days":30},{"sku":"season_premium","type":"season_premium"}]'),
  ('season',   '{"xp_per_tier":100,"tiers":30,"free":{"every":1,"coins":50},"premium":{"every":1,"coins":150}}'),
  ('more_games','[]'),
  ('ads',      '{"enabled":true,"interstitial_enabled":true}'),
  ('privacy_url','"https://example.com/privacy"'),
  ('min_app_version','"1.0.0"')
on conflict (key) do nothing;

-- ---------- core tables ----------
create table if not exists public.player_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  username text unique check (username ~ '^[A-Za-z0-9_]{3,20}$'),
  avatar text not null default 'cat',
  referral_code text unique not null default upper(substr(encode(gen_random_bytes(6),'hex'),1,8)),
  referred_by uuid references auth.users(id),
  language text not null default 'en' check (language in ('en','hi')),
  is_premium boolean not null default false,
  premium_until timestamptz,
  ads_removed boolean not null default false,
  first_seen_day date not null default public.game_day(),
  last_active_day date not null default public.game_day(),
  instagram_bonus_claimed boolean not null default false,
  starter_pack_bought boolean not null default false,
  review_prompted_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.player_wallets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  coins bigint not null default 0 check (coins >= 0),
  piggy_coins bigint not null default 0 check (piggy_coins >= 0),
  lifetime_earned bigint not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists public.coin_transactions (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  amount bigint not null,
  balance_after bigint not null,
  reason text not null,
  ref text,
  created_at timestamptz not null default now()
);
create unique index if not exists coin_tx_dedupe on public.coin_transactions(user_id, reason, ref) where ref is not null;
create index if not exists coin_tx_user_time on public.coin_transactions(user_id, created_at desc);

create table if not exists public.daily_streaks (
  user_id uuid primary key references auth.users(id) on delete cascade,
  current_streak int not null default 0,
  best_streak int not null default 0,
  last_play_day date,
  freezes_used_month int not null default 0,
  freeze_month text,
  challenge_streak int not null default 0,
  challenge_best int not null default 0,
  last_challenge_day date
);

create table if not exists public.login_rewards (
  user_id uuid primary key references auth.users(id) on delete cascade,
  cycle_day int not null default 0 check (cycle_day between 0 and 7),
  last_claim_day date
);

create table if not exists public.daily_missions (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  slot int not null check (slot between 1 and 3),
  kind text not null,            -- play_games | win_games | score_total | pop_bubbles | use_powerup
  target int not null,
  progress int not null default 0,
  reward int not null,
  claimed boolean not null default false,
  unique (user_id, day, slot)
);

create table if not exists public.player_inventory (
  user_id uuid not null references auth.users(id) on delete cascade,
  item_id text not null,
  kind text not null,
  equipped boolean not null default false,
  acquired_at timestamptz not null default now(),
  source text not null default 'shop',
  primary key (user_id, item_id)
);

create table if not exists public.ad_rewards (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  purpose text not null,                 -- coins | spin | freeze | double | help
  nonce text not null unique,            -- server-issued; echoed by ad network SSV callback
  status text not null default 'pending' check (status in ('pending','verified','claimed','expired')),
  created_at timestamptz not null default now(),
  verified_at timestamptz,
  claimed_at timestamptz,
  day date not null default public.game_day()
);
create index if not exists ad_rewards_user_day on public.ad_rewards(user_id, day);

create table if not exists public.referrals (
  id bigint generated always as identity primary key,
  referrer_id uuid not null references auth.users(id) on delete cascade,
  referee_id uuid not null unique references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','rewarded','rejected')),
  created_at timestamptz not null default now(),
  rewarded_at timestamptz,
  check (referrer_id <> referee_id)
);

create table if not exists public.achievements (
  user_id uuid not null references auth.users(id) on delete cascade,
  badge_id text not null,
  unlocked_at timestamptz not null default now(),
  primary key (user_id, badge_id)
);

create table if not exists public.player_xp (
  user_id uuid primary key references auth.users(id) on delete cascade,
  xp bigint not null default 0,
  level int not null default 1
);

create table if not exists public.daily_challenges (
  day date primary key,
  seed bigint not null,
  level_config jsonb not null
);
create table if not exists public.daily_challenge_scores (
  day date not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  score int not null,
  stars int not null default 0,
  created_at timestamptz not null default now(),
  primary key (day, user_id)
);

create table if not exists public.reward_chests (
  user_id uuid primary key references auth.users(id) on delete cascade,
  last_claim_at timestamptz,
  notified_for timestamptz
);

create table if not exists public.lucky_spins (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null default public.game_day(),
  source text not null check (source in ('free','ad')),
  result jsonb not null,
  created_at timestamptz not null default now()
);
create unique index if not exists one_free_spin_per_day on public.lucky_spins(user_id, day) where source = 'free';

create table if not exists public.weekly_events (
  id text primary key,
  title text not null,
  theme_id text,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  missions jsonb not null default '[]',    -- [{id,kind,target,reward}]
  final_reward int not null default 500
);
create table if not exists public.weekly_event_progress (
  user_id uuid not null references auth.users(id) on delete cascade,
  event_id text not null references public.weekly_events(id) on delete cascade,
  points int not null default 0,
  claimed jsonb not null default '[]',
  primary key (user_id, event_id)
);

create table if not exists public.season_pass (
  user_id uuid not null references auth.users(id) on delete cascade,
  season_start date not null,
  xp int not null default 0,
  has_premium boolean not null default false,
  claimed_free int[] not null default '{}',
  claimed_premium int[] not null default '{}',
  primary key (user_id, season_start)
);

create table if not exists public.player_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  sound boolean not null default true,
  vibration boolean not null default true,
  notifications_enabled boolean not null default true,
  reminder_time time not null default '19:00',
  notify_streak boolean not null default true,
  notify_chest boolean not null default true,
  notify_challenge boolean not null default true,
  analytics_opt_in boolean not null default false,
  updated_at timestamptz not null default now()
);

create table if not exists public.notifications (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,                    -- streak | chest | challenge
  title text not null,
  body text,
  day date not null default public.game_day(),
  created_at timestamptz not null default now(),
  read boolean not null default false
);
create index if not exists notif_user_day on public.notifications(user_id, day);

create table if not exists public.game_statistics (
  user_id uuid primary key references auth.users(id) on delete cascade,
  total_games int not null default 0,
  wins int not null default 0,
  total_score bigint not null default 0,
  best_score int not null default 0,
  bubbles_popped bigint not null default 0,
  powerups_used int not null default 0,
  games_today int not null default 0,
  games_today_day date,
  games_since_interstitial int not null default 0,
  shares_total int not null default 0
);

create table if not exists public.share_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null default public.game_day(),
  kind text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.iap_purchases (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  sku text not null,
  purchase_token text not null unique,
  order_id text,
  created_at timestamptz not null default now()
);

create table if not exists public.challenge_links (
  code text primary key default encode(gen_random_bytes(5),'hex'),
  creator_id uuid not null references auth.users(id) on delete cascade,
  level_seed bigint not null,
  creator_score int not null,
  created_at timestamptz not null default now()
);
create table if not exists public.challenge_results (
  code text not null references public.challenge_links(code) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  score int not null,
  created_at timestamptz not null default now(),
  primary key (code, user_id)
);

-- ---------- RLS ----------
do $$
declare t text;
begin
  foreach t in array array[
    'remote_config','player_profiles','player_wallets','coin_transactions','daily_streaks','login_rewards',
    'daily_missions','player_inventory','ad_rewards','referrals','achievements','player_xp','daily_challenges',
    'daily_challenge_scores','reward_chests','lucky_spins','weekly_events','weekly_event_progress','season_pass',
    'player_settings','notifications','game_statistics','share_events','iap_purchases','challenge_links','challenge_results']
  loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- Public read-only
create policy cfg_read   on public.remote_config     for select using (true);
create policy dc_read    on public.daily_challenges  for select using (true);
create policy we_read    on public.weekly_events     for select using (true);
create policy cl_read    on public.challenge_links   for select using (true);

-- Own-row read-only (writes only via SECURITY DEFINER functions)
do $$
declare t text;
begin
  foreach t in array array[
    'player_wallets','coin_transactions','daily_streaks','login_rewards','daily_missions','player_inventory',
    'ad_rewards','achievements','player_xp','reward_chests','lucky_spins','weekly_event_progress','season_pass',
    'notifications','game_statistics','share_events','iap_purchases']
  loop
    execute format('create policy %I on public.%I for select using (user_id = auth.uid())', t||'_own_read', t);
  end loop;
end $$;

create policy ref_own_read on public.referrals for select using (referrer_id = auth.uid() or referee_id = auth.uid());
create policy dcs_read     on public.daily_challenge_scores for select using (true);   -- leaderboard
create policy cr_read      on public.challenge_results for select using (true);

-- Profiles: public read of non-sensitive columns through a view; owner reads own row
create policy prof_own_read on public.player_profiles for select using (user_id = auth.uid());
create or replace view public.public_profiles with (security_invoker = false) as
  select user_id, username, avatar from public.player_profiles where username is not null;
grant select on public.public_profiles to authenticated;

-- Settings: user may edit own non-reward settings directly
create policy settings_own_read   on public.player_settings for select using (user_id = auth.uid());
create policy settings_own_update on public.player_settings for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy settings_own_insert on public.player_settings for insert with check (user_id = auth.uid());

-- Lock down: clients can never write money/progress tables
revoke insert, update, delete on all tables in schema public from anon, authenticated;
grant insert, update on public.player_settings to authenticated;
grant select on all tables in schema public to authenticated;
grant select on public.remote_config, public.daily_challenges, public.weekly_events to anon;
