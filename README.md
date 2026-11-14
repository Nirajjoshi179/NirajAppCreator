# Bubble Pop – Rewards & Gamification Module

```
supabase/migrations/001_schema.sql     tables (all 19 required + support), RLS, remote_config seed
supabase/migrations/002_functions.sql  server-authoritative reward functions (RPC)
supabase/migrations/003_iap.sql        purchase grants (service role only) + cron note
supabase/functions/ad-verify/          AdMob rewarded-ad SSV callback (signature verified)
supabase/functions/verify-purchase/    Google Play Developer API verification -> iap_grant
rewards/index.html                     15-screen mobile-first UI (EN/HI), game API
```

## Setup
1. Supabase: run 001 → 002 → 003 in the SQL editor. Auth → Providers → enable **Anonymous sign-ins**.
2. Edit `CONFIG` at the top of `rewards/index.html` (URL + **anon** key only; never the service-role key). Set `GAME_URL` to your game's `index.html`.
3. Deploy functions: `supabase functions deploy ad-verify --no-verify-jwt` and `supabase functions deploy verify-purchase`.
   Secrets: `PLAY_PACKAGE_NAME`, `GOOGLE_SERVICE_ACCOUNT_JSON`. In AdMob, set the SSV callback to the `ad-verify` URL.
4. Optional: enable `pg_cron` and schedule `queue_notifications()` hourly (see 003).
5. Add rows to `weekly_events` and `remote_config.more_games` to populate those screens.

## Game integration
From the game (same page or iframe):
```js
BubbleRewards.submitResult({place:1, score:4200, popped:80, powerups:1, won:true});
BubbleRewards.submitDaily(score, stars);           // daily challenge (once per day)
BubbleRewards.rewardedHelp();                      // ad-gated hint/undo/continue
// iframe: parent.postMessage({type:'bp_result', place, score, popped, powerups, won}, '*')
```

## Feature status (35 features)
**Fully implemented in backend + UI (web, no extra keys):** 1 coins/history, 2 streak, 3 login calendar, 4 missions, 5 shop, 7 share cards, 8 share & earn (3/day, 10 min, needs a game played), 9 story bonus, 10 referrals, 11 profile, 12 reminder time setting, 14 review prompt trigger (never rewarded), 15 settings/EN-HI/privacy/update check, 16 daily challenge, 17 streak freeze (coins), 18 chest, 19 free spin, 20 comeback, 21 XP/levels, 22 badges, 23 collections, 24 weekly events, 25 notification queue (max 2/day, prefs respected), 28 interstitial *trigger logic*, 31 season pass (free track), 32 emoji results, 33 challenge links, 34 more games, 35 remote config + server-side sync of progress + offline queue.

**Server logic complete, but needs the Android app wrapper / third-party keys to actually run (UI shows disabled state, never fakes it):**
- 6, 13 (partly), 17 (ad route), 19 (extra spins), 26, 27: **rewarded ads** — need AdMob SDK in the wrapper exposing `AndroidAds.showRewarded(nonce,userId)` and calling `onRewardedAdComplete(nonce)`; coins are paid only after the SSV callback marks the nonce verified.
- 13, 29, 30, 31 (premium track): **Google Play Billing** — wrapper exposes `AndroidBilling.purchase(sku)` and calls `onPurchaseComplete(sku, token)`; `verify-purchase` checks the token with Google before granting.
- 12, 25: **background push** — needs FCM in the wrapper (web only reminds while open).
- 14: Play in-app review needs `AndroidReview.request()`.
- 35: Google Play Games Services sign-in needs the wrapper; progress already lives server-side.

## Honest limitations
- **Not run against a live Supabase project.** No Postgres server or network was available here: SQL was not executed and the Edge Functions were not deployed. Frontend JS passed a syntax check only. Expect to fix small errors on first run, then test each RPC.
- Existing Bubble Pop file and Supabase project weren't in the chat, so nothing was inspected or merged; this is a standalone module.
- The server can't prove a game was actually played fairly. Results are range-checked and rate-limited (10 s), but for stronger anti-cheat have the game request a server-issued session before play.
- Referral payout happens after the invitee plays one game; stronger fake-account protection (device/phone checks) is not included.
- `more_games` is empty by default; add your NirajAppBuild links yourself.
