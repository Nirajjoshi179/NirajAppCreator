-- ============================================================
-- 002_functions.sql | Server-authoritative reward logic
-- Every function: SECURITY DEFINER, uses auth.uid(), server clock,
-- writes coin_transactions for every coin movement.
-- ============================================================

create or replace function public.cfg(k text) returns jsonb
language sql stable security definer set search_path = public as $$
  select value from public.remote_config where key = k $$;

-- ---------- internal helpers (not granted to clients) ----------
create or replace function public._uid() returns uuid language plpgsql stable as $$
declare u uuid := auth.uid();
begin if u is null then raise exception 'not_authenticated'; end if; return u; end $$;

-- Add (or spend, with negative) coins; dedupe via (user, reason, ref)
create or replace function public._coins(p_user uuid, p_amount bigint, p_reason text, p_ref text default null, p_multiplier boolean default false)
returns bigint language plpgsql security definer set search_path = public as $$
declare mult int := 1; bal bigint; amt bigint := p_amount;
begin
  if p_multiplier and p_amount > 0 then
    if exists (select 1 from player_profiles where user_id = p_user and is_premium and (premium_until is null or premium_until > now())) then
      mult := coalesce((cfg('rewards')->>'premium_multiplier')::int, 2);
    end if;
    amt := p_amount * mult;
  end if;
  insert into player_wallets(user_id) values (p_user) on conflict do nothing;
  update player_wallets set coins = coins + amt,
         lifetime_earned = lifetime_earned + greatest(amt,0), updated_at = now()
   where user_id = p_user returning coins into bal;   -- check constraint blocks negative balance
  insert into coin_transactions(user_id, amount, balance_after, reason, ref) values (p_user, amt, bal, p_reason, p_ref);
  return amt;
end $$;

create or replace function public._level_for(xp bigint) returns int
language sql immutable as $$ select 1 + floor(sqrt(xp / 50.0))::int $$;

create or replace function public._add_xp(p_user uuid, p_xp int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare old_lvl int; new_lvl int; total bigint; lvl_coins bigint := 0; l int; sp jsonb := cfg('season');
        sstart date := (date_trunc('day', now() at time zone 'Asia/Kolkata'))::date;
begin
  insert into player_xp(user_id) values (p_user) on conflict do nothing;
  select level into old_lvl from player_xp where user_id = p_user for update;
  update player_xp set xp = xp + p_xp where user_id = p_user returning xp into total;
  new_lvl := _level_for(total);
  if new_lvl > old_lvl then
    for l in old_lvl+1 .. new_lvl loop
      lvl_coins := lvl_coins + 50 + l * 10;
      perform _coins(p_user, 50 + l * 10, 'level_up', 'lvl'||l);
    end loop;
    update player_xp set level = new_lvl where user_id = p_user;
  end if;
  -- season xp
  insert into season_pass(user_id, season_start, xp)
    values (p_user, _season_start(), p_xp)
    on conflict (user_id, season_start) do update set xp = season_pass.xp + p_xp;
  return jsonb_build_object('xp', total, 'level', new_lvl, 'leveled_up', new_lvl > old_lvl, 'level_coins', lvl_coins);
end $$;

-- 30-day seasons anchored at 2026-01-01
create or replace function public._season_start() returns date
language sql stable as $$
  select date '2026-01-01' + (floor((public.game_day() - date '2026-01-01') / 30.0)::int * 30) $$;

create or replace function public._badge(p_user uuid, p_id text) returns boolean
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into achievements(user_id, badge_id) values (p_user, p_id) on conflict do nothing;
  get diagnostics n = row_count;
  if n > 0 then perform _coins(p_user, 100, 'badge', p_id); end if;
  return n > 0;
end $$;

create or replace function public._check_badges(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s game_statistics; st daily_streaks; x player_xp; ncol int;
begin
  select * into s from game_statistics where user_id = p_user;
  select * into st from daily_streaks where user_id = p_user;
  select * into x from player_xp where user_id = p_user;
  if s.total_games >= 1   then perform _badge(p_user,'first_game'); end if;
  if s.total_games >= 50  then perform _badge(p_user,'games_50'); end if;
  if s.wins >= 1          then perform _badge(p_user,'first_win'); end if;
  if s.wins >= 25         then perform _badge(p_user,'wins_25'); end if;
  if s.best_score >= 5000 then perform _badge(p_user,'score_5000'); end if;
  if st.best_streak >= 7  then perform _badge(p_user,'streak_7'); end if;
  if st.best_streak >= 30 then perform _badge(p_user,'streak_30'); end if;
  if x.level >= 5         then perform _badge(p_user,'level_5'); end if;
  if x.level >= 10        then perform _badge(p_user,'level_10'); end if;
  select count(*) into ncol from player_inventory where user_id = p_user;
  if ncol >= 5            then perform _badge(p_user,'collector_5'); end if;
end $$;

-- ---------- bootstrap: create rows, handle comeback ----------
create or replace function public.bootstrap_player(p_username text default null, p_ref_code text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); prof player_profiles; away int; cb jsonb := null; rc jsonb := cfg('rewards'); referrer uuid;
begin
  insert into player_profiles(user_id) values (u) on conflict do nothing;
  insert into player_wallets(user_id) values (u) on conflict do nothing;
  insert into daily_streaks(user_id) values (u) on conflict do nothing;
  insert into login_rewards(user_id) values (u) on conflict do nothing;
  insert into player_xp(user_id) values (u) on conflict do nothing;
  insert into reward_chests(user_id) values (u) on conflict do nothing;
  insert into game_statistics(user_id) values (u) on conflict do nothing;
  insert into player_settings(user_id) values (u) on conflict do nothing;
  -- starter free character
  insert into player_inventory(user_id,item_id,kind,source) values (u,'char_cat','character','default') on conflict do nothing;

  select * into prof from player_profiles where user_id = u for update;
  if p_username is not null and prof.username is null then
    begin update player_profiles set username = p_username where user_id = u;
    exception when unique_violation then raise exception 'username_taken'; end;
  end if;

  -- referral link (reward is paid later, after the referee actually plays: see _try_pay_referral)
  if p_ref_code is not null and prof.referred_by is null then
    select user_id into referrer from player_profiles where referral_code = upper(p_ref_code);
    if referrer is not null and referrer <> u and prof.first_seen_day = game_day() then
      update player_profiles set referred_by = referrer where user_id = u;
      insert into referrals(referrer_id, referee_id) values (referrer, u) on conflict do nothing;
    end if;
  end if;

  away := game_day() - prof.last_active_day;
  if away >= (rc->>'comeback_days')::int then
    perform _coins(u, (rc->>'comeback_coins')::bigint, 'comeback', game_day()::text);
    cb := jsonb_build_object('days_away', away, 'coins', (rc->>'comeback_coins')::bigint);
  end if;
  update player_profiles set last_active_day = game_day() where user_id = u;
  return jsonb_build_object('comeback', cb);
end $$;

-- ---------- state snapshot for the UI ----------
create or replace function public.get_state() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); rc jsonb := cfg('rewards'); out jsonb; ch timestamptz;
begin
  select last_claim_at into ch from reward_chests where user_id = u;
  select jsonb_build_object(
    'now', now(), 'day', game_day(),
    'profile', (select to_jsonb(p) - 'referred_by' from player_profiles p where user_id = u),
    'wallet', (select to_jsonb(w) from player_wallets w where user_id = u),
    'xp', (select to_jsonb(x) from player_xp x where user_id = u),
    'streak', (select to_jsonb(s) from daily_streaks s where user_id = u),
    'login', (select jsonb_build_object('cycle_day', l.cycle_day, 'last_claim_day', l.last_claim_day,
                'can_claim', l.last_claim_day is distinct from game_day(),
                'will_reset', l.last_claim_day is not null and game_day() - l.last_claim_day > 1) from login_rewards l where user_id = u),
    'stats', (select to_jsonb(g) from game_statistics g where user_id = u),
    'inventory', (select coalesce(jsonb_agg(to_jsonb(i)), '[]') from player_inventory i where user_id = u),
    'badges', (select coalesce(jsonb_agg(badge_id), '[]') from achievements where user_id = u),
    'missions', (select coalesce(jsonb_agg(to_jsonb(m) order by slot), '[]') from daily_missions m where user_id = u and day = game_day()),
    'chest_ready_at', coalesce(ch, 'epoch'::timestamptz) + make_interval(hours => (rc->>'chest_hours')::int),
    'ads_today', (select count(*) from ad_rewards where user_id = u and day = game_day() and purpose = 'coins' and status = 'claimed'),
    'shares_today', (select count(*) from share_events where user_id = u and day = game_day() and kind = 'share_earn'),
    'free_spin_available', not exists (select 1 from lucky_spins where user_id = u and day = game_day() and source = 'free'),
    'settings', (select to_jsonb(s) from player_settings s where user_id = u),
    'referrals', (select jsonb_build_object('total', count(*), 'rewarded', count(*) filter (where status = 'rewarded')) from referrals where referrer_id = u),
    'season', (select to_jsonb(sp) from season_pass sp where user_id = u and season_start = _season_start()),
    'season_start', _season_start(),
    'notifications', (select coalesce(jsonb_agg(to_jsonb(n) order by created_at desc), '[]') from (select * from notifications where user_id = u order by created_at desc limit 20) n)
  ) into out;
  return out;
end $$;

-- ---------- 1. match result: placements, stats, XP, streak, missions, referral ----------
create or replace function public.submit_game_result(
  p_place int, p_score int, p_popped int default 0, p_powerups int default 0, p_won boolean default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); rc jsonb := cfg('rewards'); won boolean := coalesce(p_won, p_place = 1);
        coins int := 0; xp int; xpres jsonb; st daily_streaks; gs game_statistics; gid text;
        every int := (rc->>'interstitial_every')::int; prof player_profiles; show_inter boolean := false; show_review boolean := false;
begin
  if p_score < 0 or p_score > 10000000 or p_place not between 0 and 8 or p_popped > 5000 then raise exception 'invalid_result'; end if;
  perform bootstrap_player();
  if p_place between 1 and 3 then coins := (rc->'place'->>(p_place-1))::int; end if;
  -- Per-game idempotency token: one reward claim per accepted result (timestamp-based)
  gid := extract(epoch from clock_timestamp())::bigint::text || '-' || u::text;
  -- rate limit: at most one result per 10 s
  if exists (select 1 from coin_transactions where user_id = u and reason = 'game_place' and created_at > now() - interval '10 seconds') then
    raise exception 'too_fast';
  end if;
  if coins > 0 then perform _coins(u, coins, 'game_place', gid, true); end if;

  update game_statistics set total_games = total_games + 1, wins = wins + case when won then 1 else 0 end,
         total_score = total_score + p_score, best_score = greatest(best_score, p_score),
         bubbles_popped = bubbles_popped + p_popped, powerups_used = powerups_used + p_powerups,
         games_today = case when games_today_day = game_day() then games_today + 1 else 1 end, games_today_day = game_day(),
         games_since_interstitial = games_since_interstitial + 1
   where user_id = u returning * into gs;

  -- streak (counts a day once)
  select * into st from daily_streaks where user_id = u for update;
  if st.last_play_day is distinct from game_day() then
    if st.last_play_day = game_day() - 1 then
      update daily_streaks set current_streak = current_streak + 1 where user_id = u;
    else
      update daily_streaks set current_streak = 1 where user_id = u;
    end if;
    update daily_streaks set last_play_day = game_day(), best_streak = greatest(best_streak, current_streak) where user_id = u returning * into st;
    perform _coins(u, least(st.current_streak, 7) * 20, 'streak_bonus', game_day()::text, true);
  end if;

  xp := (rc->>'xp_per_game')::int + case when won then (rc->>'xp_win_bonus')::int else 0 end;
  xpres := _add_xp(u, xp);

  perform _gen_missions(u);
  update daily_missions set progress = least(target, progress + case kind
      when 'play_games' then 1 when 'win_games' then case when won then 1 else 0 end
      when 'score_total' then p_score when 'pop_bubbles' then p_popped when 'use_powerup' then p_powerups else 0 end)
   where user_id = u and day = game_day() and not claimed;
  perform _event_progress(u, won, p_score);
  perform _check_badges(u);
  perform _try_pay_referral(u);

  select * into prof from player_profiles where user_id = u;
  if not prof.ads_removed and coalesce((cfg('ads')->>'interstitial_enabled')::boolean, true)
     and prof.first_seen_day < game_day() and gs.games_since_interstitial >= every then
    show_inter := true;
    update game_statistics set games_since_interstitial = 0 where user_id = u;
  end if;
  if prof.review_prompted_at is null and (gs.total_games >= (rc->>'review_after_games')::int or won) then
    show_review := true;
    update player_profiles set review_prompted_at = now() where user_id = u;
  end if;

  return jsonb_build_object('coins_awarded', coins, 'xp', xpres, 'streak', st.current_streak,
    'can_double', coins > 0 and not prof.ads_removed, 'double_ref', gid,
    'show_interstitial', show_inter, 'show_review_prompt', show_review);
end $$;

-- ---------- 2/3. login calendar ----------
create or replace function public.claim_login_reward() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); l login_rewards; nxt int; amt int; rc jsonb := cfg('rewards');
begin
  perform bootstrap_player();
  select * into l from login_rewards where user_id = u for update;
  if l.last_claim_day = game_day() then raise exception 'already_claimed'; end if;
  nxt := case when l.last_claim_day is null or game_day() - l.last_claim_day > 1 or l.cycle_day >= 7 then 1 else l.cycle_day + 1 end;
  amt := (rc->'login'->>(nxt-1))::int;
  update login_rewards set cycle_day = nxt, last_claim_day = game_day() where user_id = u;
  perform _coins(u, amt, 'login_reward', game_day()::text, true);
  return jsonb_build_object('day', nxt, 'coins', amt);
end $$;

-- ---------- 4. missions ----------
create or replace function public._gen_missions(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare kinds text[] := array['play_games','win_games','score_total','pop_bubbles','use_powerup'];
        targets int[] := array[3,1,3000,100,2]; rc int[]; k int[]; i int; pick int; seed double precision;
begin
  if exists (select 1 from daily_missions where user_id = p_user and day = game_day()) then return; end if;
  rc := array(select jsonb_array_elements_text(cfg('rewards')->'mission_coins')::int);
  seed := (extract(epoch from game_day()::timestamp)::bigint % 1000)::double precision / 1000.0;
  perform setseed(seed);
  k := array(select g from generate_series(1,5) g order by random() limit 3);
  for i in 1..3 loop
    insert into daily_missions(user_id, day, slot, kind, target, reward)
    values (p_user, game_day(), i, kinds[k[i]], targets[k[i]], rc[i]);
  end loop;
end $$;

create or replace function public.ensure_missions() returns void
language plpgsql security definer set search_path = public as $$
begin perform bootstrap_player(); perform _gen_missions(_uid()); end $$;

create or replace function public.claim_mission(p_slot int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); m daily_missions; amt bigint;
begin
  select * into m from daily_missions where user_id = u and day = game_day() and slot = p_slot for update;
  if not found then raise exception 'no_mission'; end if;
  if m.claimed then raise exception 'already_claimed'; end if;
  if m.progress < m.target then raise exception 'not_complete'; end if;
  update daily_missions set claimed = true where id = m.id;
  amt := _coins(u, m.reward, 'mission', m.id::text, true);
  perform _add_xp(u, 15);
  return jsonb_build_object('coins', amt);
end $$;

-- ---------- 5. shop + collection ----------
create or replace function public.buy_item(p_item_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); it jsonb; col text; cfgc jsonb := cfg('collections'); total int; owned int; bonus int := 0;
begin
  select e into it from jsonb_array_elements(cfg('shop')) e where e->>'id' = p_item_id;
  if it is null then raise exception 'unknown_item'; end if;
  if exists (select 1 from player_inventory where user_id = u and item_id = p_item_id) then raise exception 'already_owned'; end if;
  if (it->>'price')::int > 0 then perform _coins(u, -(it->>'price')::bigint, 'shop_buy', p_item_id); end if;
  insert into player_inventory(user_id,item_id,kind) values (u, p_item_id, it->>'kind');
  col := it->>'collection';
  select count(*) into total from jsonb_array_elements(cfg('shop')) e where e->>'collection' = col;
  select count(*) into owned from player_inventory i join jsonb_array_elements(cfg('shop')) e on e->>'id' = i.item_id
   where i.user_id = u and e->>'collection' = col;
  if owned = total then
    bonus := coalesce((cfgc->col->>'bonus')::int, 0);
    if bonus > 0 then perform _coins(u, bonus, 'collection_bonus', col); end if;
  end if;
  perform _check_badges(u);
  return jsonb_build_object('item', p_item_id, 'collection_complete', owned = total, 'bonus', bonus);
exception when check_violation then raise exception 'not_enough_coins';
end $$;

create or replace function public.equip_item(p_item_id text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); k text;
begin
  select kind into k from player_inventory where user_id = u and item_id = p_item_id;
  if k is null then raise exception 'not_owned'; end if;
  update player_inventory set equipped = (item_id = p_item_id) where user_id = u and kind = k;
end $$;

-- ---------- 6. rewarded ads: server-issued nonce -> verified by SSV callback -> claim ----------
create or replace function public.ad_request(p_purpose text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); rc jsonb := cfg('rewards'); n int; last_at timestamptz; nonce text;
begin
  perform bootstrap_player();
  if p_purpose not in ('coins','spin','freeze','double','help') then raise exception 'bad_purpose'; end if;
  if exists (select 1 from player_profiles where user_id = u and ads_removed) then raise exception 'ads_removed'; end if;
  select count(*), max(created_at) into n, last_at from ad_rewards where user_id = u and day = game_day() and status in ('verified','claimed');
  if n >= (rc->>'ad_daily_max')::int * 3 then raise exception 'ad_daily_limit'; end if;  -- global safety cap
  if p_purpose = 'coins' and (select count(*) from ad_rewards where user_id = u and day = game_day() and purpose = 'coins' and status in ('verified','claimed')) >= (rc->>'ad_daily_max')::int then
    raise exception 'ad_daily_limit'; end if;
  if last_at is not null and now() - last_at < make_interval(secs => (rc->>'ad_cooldown_s')::int) then raise exception 'ad_cooldown'; end if;
  update ad_rewards set status = 'expired' where user_id = u and status = 'pending' and created_at < now() - interval '15 minutes';
  nonce := encode(gen_random_bytes(16), 'hex');
  insert into ad_rewards(user_id, purpose, nonce) values (u, p_purpose, nonce);
  return jsonb_build_object('nonce', nonce, 'user_id', u);  -- pass as SSV custom_data / user_id to the ad SDK
end $$;

-- Called ONLY by the ad-verify Edge Function (service role) after the ad network's SSV signature check
create or replace function public.ad_mark_verified(p_nonce text, p_user uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update ad_rewards set status = 'verified', verified_at = now()
   where nonce = p_nonce and user_id = p_user and status = 'pending' and created_at > now() - interval '15 minutes';
  get diagnostics n = row_count; return n > 0;
end $$;

create or replace function public.ad_claim(p_nonce text, p_ref text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); a ad_rewards; rc jsonb := cfg('rewards'); amt bigint := 0; res jsonb := '{}'; base int;
begin
  select * into a from ad_rewards where nonce = p_nonce and user_id = u for update;
  if not found then raise exception 'unknown_ad'; end if;
  if a.status = 'claimed' then raise exception 'already_claimed'; end if;
  if a.status <> 'verified' then raise exception 'ad_not_verified'; end if;
  update ad_rewards set status = 'claimed', claimed_at = now() where id = a.id;
  if a.purpose = 'coins' then
    amt := _coins(u, (rc->>'ad_coins')::bigint, 'ad_coins', a.id::text, true);
    res := jsonb_build_object('coins', amt);
  elsif a.purpose = 'spin' then
    res := public._do_spin(u, 'ad');
  elsif a.purpose = 'freeze' then
    res := public._grant_freeze(u);
  elsif a.purpose = 'double' then
    -- doubles the placement coins of ONE specific game; ref is the double_ref from submit_game_result
    select amount into base from coin_transactions where user_id = u and reason = 'game_place' and ref = p_ref;
    if base is null then raise exception 'nothing_to_double'; end if;
    amt := _coins(u, base, 'ad_double', p_ref);   -- unique(user,reason,ref) => once per game
    res := jsonb_build_object('coins', amt);
  elsif a.purpose = 'help' then
    res := jsonb_build_object('help', true);       -- game grants hint/undo/continue locally; no coins
  end if;
  return res;
exception when unique_violation then raise exception 'already_claimed';
end $$;

-- ---------- 8/9. share & earn ----------
create or replace function public.claim_share_reward(p_kind text default 'share_earn') returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); rc jsonb := cfg('rewards'); n int; last_at timestamptz; amt bigint;
begin
  perform bootstrap_player();
  if p_kind = 'instagram_story' then
    if (select instagram_bonus_claimed from player_profiles where user_id = u for update) then raise exception 'already_claimed'; end if;
    update player_profiles set instagram_bonus_claimed = true where user_id = u;
    amt := _coins(u, (rc->>'story_bonus')::bigint, 'instagram_story', 'once', true);
    insert into share_events(user_id, kind) values (u, p_kind);
    return jsonb_build_object('coins', amt);
  end if;
  select count(*), max(created_at) into n, last_at from share_events where user_id = u and day = game_day() and kind = 'share_earn';
  if n >= (rc->>'share_daily_max')::int then raise exception 'share_daily_limit'; end if;
  if last_at is not null and now() - last_at < make_interval(secs => (rc->>'share_cooldown_s')::int) then raise exception 'share_cooldown'; end if;
  -- must have a real completed game today to share (blocks button-click farming)
  if not exists (select 1 from game_statistics where user_id = u and games_today_day = game_day() and games_today > n) then
    raise exception 'play_a_game_first'; end if;
  insert into share_events(user_id, kind) values (u, 'share_earn');
  amt := _coins(u, 50, 'share_earn', game_day()::text || '-' || (n+1), true);
  return jsonb_build_object('coins', amt);
end $$;

-- ---------- 10. referral payout (after referee has actually played >= 1 game) ----------
create or replace function public._try_pay_referral(p_referee uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r referrals; amt int := (cfg('rewards')->>'referral_coins')::int;
begin
  select * into r from referrals where referee_id = p_referee and status = 'pending' for update;
  if not found then return; end if;
  if (select total_games from game_statistics where user_id = p_referee) < 1 then return; end if;
  update referrals set status = 'rewarded', rewarded_at = now() where id = r.id;
  perform _coins(r.referrer_id, amt, 'referral', 'r'||r.id);
  perform _coins(r.referee_id,  amt, 'referral', 'r'||r.id);
end $$;

-- ---------- 17. streak freeze ----------
create or replace function public._grant_freeze(p_user uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare st daily_streaks; rc jsonb := cfg('rewards'); mon text := to_char(game_day(),'YYYY-MM');
begin
  select * into st from daily_streaks where user_id = p_user for update;
  if st.freeze_month is distinct from mon then
    update daily_streaks set freeze_month = mon, freezes_used_month = 0 where user_id = p_user;
    st.freezes_used_month := 0;
  end if;
  if st.freezes_used_month >= (rc->>'freeze_monthly_max')::int then raise exception 'freeze_limit'; end if;
  -- only useful when yesterday-before was missed: streak last played exactly 2 days ago
  if st.last_play_day is null or st.current_streak = 0 or game_day() - st.last_play_day <> 2 then raise exception 'freeze_not_needed'; end if;
  update daily_streaks set last_play_day = game_day() - 1, freezes_used_month = freezes_used_month + 1 where user_id = p_user;
  return jsonb_build_object('streak_saved', st.current_streak);
end $$;

create or replace function public.buy_streak_freeze() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); res jsonb;
begin
  res := _grant_freeze(u);   -- validates first; raises if not allowed
  begin perform _coins(u, -(cfg('rewards')->>'freeze_cost')::bigint, 'streak_freeze', game_day()::text);
  exception when check_violation then raise exception 'not_enough_coins'; end;
  return res;
end $$;

-- ---------- 18. free chest ----------
create or replace function public.claim_chest() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); rc jsonb := cfg('rewards'); c reward_chests; amt int; paid bigint;
begin
  perform bootstrap_player();
  select * into c from reward_chests where user_id = u for update;
  if c.last_claim_at is not null and now() < c.last_claim_at + make_interval(hours => (rc->>'chest_hours')::int) then
    raise exception 'chest_not_ready'; end if;
  amt := (rc->>'chest_min')::int + floor(random() * ((rc->>'chest_max')::int - (rc->>'chest_min')::int + 1))::int;
  update reward_chests set last_claim_at = now() where user_id = u;
  paid := _coins(u, amt, 'chest', extract(epoch from now())::bigint::text, true);
  return jsonb_build_object('coins', paid);
end $$;

-- ---------- 19. lucky spin ----------
create or replace function public._do_spin(p_user uuid, p_source text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare tbl jsonb := cfg('spin'); total int; r int; acc int := 0; e jsonb; res jsonb; idx int := 0; hit int := 0;
begin
  select sum((x->>'w')::int) into total from jsonb_array_elements(tbl) x;
  r := floor(random() * total)::int;
  for e in select * from jsonb_array_elements(tbl) loop
    acc := acc + (e->>'w')::int;
    if r < acc then res := e; hit := idx; exit; end if;
    idx := idx + 1;
  end loop;
  insert into lucky_spins(user_id, source, result) values (p_user, p_source, res);
  if res->>'type' = 'coins' then perform _coins(p_user, (res->>'amount')::bigint, 'spin', 'sp'||clock_timestamp()::text, true);
  elsif res->>'type' = 'xp' then perform _add_xp(p_user, (res->>'amount')::int);
  elsif res->>'type' = 'item' then
    insert into player_inventory(user_id,item_id,kind,source)
      values (p_user, res->>'item_id', coalesce((select e2->>'kind' from jsonb_array_elements(cfg('shop')) e2 where e2->>'id' = res->>'item_id'),'skin'), 'spin')
      on conflict do nothing;
  end if;
  return jsonb_build_object('result', res, 'index', hit);
exception when unique_violation then raise exception 'free_spin_used';
end $$;

create or replace function public.spin_free() returns jsonb
language plpgsql security definer set search_path = public as $$
begin perform bootstrap_player(); return _do_spin(_uid(), 'free'); end $$;

-- ---------- 16. daily challenge (same seed for everyone) ----------
create or replace function public.get_daily_challenge() returns jsonb
language plpgsql security definer set search_path = public as $$
declare d daily_challenges; u uuid := auth.uid();
begin
  insert into daily_challenges(day, seed, level_config)
  values (game_day(), (extract(epoch from game_day()::timestamp)::bigint % 2147483647),
          jsonb_build_object('rows', 6 + (extract(doy from game_day())::int % 3), 'colors', 4 + (extract(doy from game_day())::int % 3), 'moves', 25))
  on conflict do nothing;
  select * into d from daily_challenges where day = game_day();
  return jsonb_build_object('day', d.day, 'seed', d.seed, 'config', d.level_config,
    'done', u is not null and exists (select 1 from daily_challenge_scores where day = d.day and user_id = u),
    'leaderboard', (select coalesce(jsonb_agg(row_to_json(t)), '[]') from (
        select coalesce(p.username, 'Player') as username, s.score, s.stars
          from daily_challenge_scores s left join player_profiles p on p.user_id = s.user_id
         where s.day = d.day order by s.score desc limit 20) t));
end $$;

create or replace function public.submit_daily_challenge(p_score int, p_stars int default 0) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); st daily_streaks; amt bigint;
begin
  perform bootstrap_player(); perform get_daily_challenge();
  if p_score < 0 or p_score > 10000000 or p_stars not between 0 and 3 then raise exception 'invalid_result'; end if;
  insert into daily_challenge_scores(day, user_id, score, stars) values (game_day(), u, p_score, p_stars);  -- PK blocks 2nd try
  select * into st from daily_streaks where user_id = u for update;
  update daily_streaks set challenge_streak = case when last_challenge_day = game_day() - 1 then challenge_streak + 1 else 1 end,
         last_challenge_day = game_day() where user_id = u returning * into st;
  update daily_streaks set challenge_best = greatest(challenge_best, challenge_streak) where user_id = u;
  amt := _coins(u, 100 + p_stars * 50 + least(st.challenge_streak, 7) * 10, 'daily_challenge', game_day()::text, true);
  perform _add_xp(u, 40);
  return jsonb_build_object('coins', amt, 'streak', st.challenge_streak);
exception when unique_violation then raise exception 'already_done';
end $$;

-- ---------- 24. weekly events ----------
create or replace function public._event_progress(p_user uuid, p_won boolean, p_score int) returns void
language plpgsql security definer set search_path = public as $$
declare ev weekly_events;
begin
  for ev in select * from weekly_events where now() between starts_at and ends_at loop
    insert into weekly_event_progress(user_id, event_id, points) values (p_user, ev.id, 1 + case when p_won then 2 else 0 end + p_score / 1000)
    on conflict (user_id, event_id) do update set points = weekly_event_progress.points + excluded.points;
  end loop;
end $$;

create or replace function public.get_events() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('event', to_jsonb(e),
     'points', coalesce(p.points, 0), 'claimed', coalesce(p.claimed, '[]'),
     'leaderboard', (select coalesce(jsonb_agg(row_to_json(t)), '[]') from (
         select coalesce(pr.username,'Player') as username, wp.points from weekly_event_progress wp
           left join player_profiles pr on pr.user_id = wp.user_id where wp.event_id = e.id order by wp.points desc limit 20) t))), '[]')
  from weekly_events e left join weekly_event_progress p on p.event_id = e.id and p.user_id = auth.uid()
  where now() between e.starts_at and e.ends_at + interval '2 days' $$;

create or replace function public.claim_event_mission(p_event text, p_mission text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); ev weekly_events; m jsonb; pr weekly_event_progress; amt bigint;
begin
  select * into ev from weekly_events where id = p_event and now() between starts_at and ends_at;
  if not found then raise exception 'event_not_active'; end if;
  select e into m from jsonb_array_elements(ev.missions) e where e->>'id' = p_mission;
  if m is null then raise exception 'unknown_mission'; end if;
  select * into pr from weekly_event_progress where user_id = u and event_id = p_event for update;
  if not found or pr.points < (m->>'target')::int then raise exception 'not_complete'; end if;
  if pr.claimed ? p_mission then raise exception 'already_claimed'; end if;
  update weekly_event_progress set claimed = claimed || to_jsonb(p_mission) where user_id = u and event_id = p_event;
  amt := _coins(u, (m->>'reward')::bigint, 'event_mission', p_event||':'||p_mission, true);
  return jsonb_build_object('coins', amt);
end $$;

-- ---------- 31. season pass ----------
create or replace function public.claim_season_tier(p_tier int, p_track text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); sp season_pass; sc jsonb := cfg('season'); coins int; sstart date := _season_start();
begin
  if p_tier < 1 or p_tier > (sc->>'tiers')::int or p_track not in ('free','premium') then raise exception 'bad_tier'; end if;
  select * into sp from season_pass where user_id = u and season_start = sstart for update;
  if not found or sp.xp < p_tier * (sc->>'xp_per_tier')::int then raise exception 'tier_locked'; end if;
  if p_track = 'free' then
    if p_tier = any(sp.claimed_free) then raise exception 'already_claimed'; end if;
    coins := (sc->'free'->>'coins')::int;
    update season_pass set claimed_free = claimed_free || p_tier where user_id = u and season_start = sstart;
  else
    if not sp.has_premium then raise exception 'premium_required'; end if;
    if p_tier = any(sp.claimed_premium) then raise exception 'already_claimed'; end if;
    coins := (sc->'premium'->>'coins')::int;
    update season_pass set claimed_premium = claimed_premium || p_tier where user_id = u and season_start = sstart;
  end if;
  perform _coins(u, coins, 'season_'||p_track, sstart||':'||p_tier);
  return jsonb_build_object('coins', coins);
end $$;

-- ---------- 30. piggy bank ----------
create or replace function public.piggy_deposit(p_amount int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); cap bigint := (cfg('rewards')->>'piggy_cap')::bigint;
begin
  -- piggy fills from real gameplay: max 40 per accepted game, only if the player played in the last minute
  if p_amount < 1 or p_amount > 40 then raise exception 'invalid_amount'; end if;
  if not exists (select 1 from coin_transactions where user_id = u and reason = 'game_place' and created_at > now() - interval '2 minutes')
     and not exists (select 1 from game_statistics where user_id = u and games_today_day = game_day()) then
    raise exception 'no_recent_game'; end if;
  update player_wallets set piggy_coins = least(cap, piggy_coins + p_amount) where user_id = u;
  return jsonb_build_object('piggy', (select piggy_coins from player_wallets where user_id = u), 'cap', cap);
end $$;

-- ---------- settings / profile ----------
create or replace function public.set_profile(p_username text, p_avatar text, p_language text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform bootstrap_player();
  update player_profiles set username = coalesce(p_username, username), avatar = coalesce(p_avatar, avatar),
         language = coalesce(p_language, language) where user_id = _uid();
exception when unique_violation then raise exception 'username_taken';
end $$;

-- ---------- 25. smart notifications: max 2/day, respects prefs (cron-invoked) ----------
create or replace function public.queue_notifications() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; cnt int; rc jsonb := cfg('rewards');
begin
  for r in
    select s.*, st.last_play_day, st.current_streak, c.last_claim_at
      from player_settings s join daily_streaks st using (user_id) join reward_chests c using (user_id)
     where s.notifications_enabled
  loop
    select count(*) into cnt from notifications where user_id = r.user_id and day = game_day();
    continue when cnt >= 2;
    if r.notify_streak and r.current_streak > 0 and r.last_play_day = game_day() - 1 then
      insert into notifications(user_id, kind, title, body) values (r.user_id,'streak','Keep your streak!','Play today to keep your '||r.current_streak||'-day streak.'); n := n + 1; cnt := cnt + 1;
    end if;
    continue when cnt >= 2;
    if r.notify_chest and r.last_claim_at is not null and now() >= r.last_claim_at + make_interval(hours => (rc->>'chest_hours')::int)
       and not exists (select 1 from notifications where user_id = r.user_id and kind = 'chest' and created_at > r.last_claim_at) then
      insert into notifications(user_id, kind, title, body) values (r.user_id,'chest','Free chest ready','Open your free reward chest.'); n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- ---------- 33. challenge a friend ----------
create or replace function public.create_challenge(p_seed bigint, p_score int) returns text
language plpgsql security definer set search_path = public as $$
declare c text;
begin
  if p_score < 0 or p_score > 10000000 then raise exception 'invalid_result'; end if;
  insert into challenge_links(creator_id, level_seed, creator_score) values (_uid(), p_seed, p_score) returning code into c;
  return c;
end $$;

create or replace function public.get_challenge(p_code text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('code', c.code, 'seed', c.level_seed, 'creator', coalesce(p.username,'Player'), 'creator_score', c.creator_score,
    'results', (select coalesce(jsonb_agg(jsonb_build_object('username', coalesce(pp.username,'Player'), 'score', r.score) order by r.score desc), '[]')
                from challenge_results r left join player_profiles pp on pp.user_id = r.user_id where r.code = c.code))
  from challenge_links c left join player_profiles p on p.user_id = c.creator_id where c.code = p_code $$;

create or replace function public.submit_challenge_result(p_code text, p_score int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_score < 0 or p_score > 10000000 then raise exception 'invalid_result'; end if;
  insert into challenge_results(code, user_id, score) values (p_code, _uid(), p_score);
exception when unique_violation then raise exception 'already_done';
end $$;

-- ---------- 35. cloud save of non-reward preferences (rewards are already server-side) ----------
-- Coins/XP/levels/achievements/inventory live ONLY on the server, so they sync by construction.
-- Offline play: client queues results; replay them through submit_game_result when online.

-- ---------- leaderboard ----------
create or replace function public.get_leaderboard(p_kind text default 'wins') returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(row_to_json(t)), '[]') from (
    select coalesce(p.username,'Player') as username, p.avatar, g.wins, g.best_score, x.level
      from game_statistics g join player_profiles p using (user_id) join player_xp x using (user_id)
     where p.username is not null
     order by case when p_kind = 'score' then g.best_score else g.wins end desc limit 50) t $$;

-- ---------- grants ----------
revoke all on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.bootstrap_player(text,text), public.get_state(), public.submit_game_result(int,int,int,int,boolean),
  public.claim_login_reward(), public.ensure_missions(), public.claim_mission(int), public.buy_item(text),
  public.equip_item(text), public.ad_request(text), public.ad_claim(text,text), public.claim_share_reward(text),
  public.buy_streak_freeze(), public.claim_chest(), public.spin_free(), public.get_daily_challenge(),
  public.submit_daily_challenge(int,int), public.get_events(), public.claim_event_mission(text,text),
  public.claim_season_tier(int,text), public.piggy_deposit(int), public.set_profile(text,text,text),
  public.create_challenge(bigint,int), public.get_challenge(text), public.submit_challenge_result(text,int),
  public.get_leaderboard(text), public.game_day()
to authenticated;
grant execute on function public.get_daily_challenge(), public.get_challenge(text), public.game_day() to anon;
-- service-role only (Edge Functions / cron): ad_mark_verified, queue_notifications, plus the IAP grant in 003
grant execute on function public.ad_mark_verified(text,uuid), public.queue_notifications() to service_role;
