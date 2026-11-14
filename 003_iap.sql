-- 003_iap.sql | Purchase grants. Callable ONLY by the verify-purchase Edge Function (service role),
-- after Google Play Developer API confirms the purchase token.

create or replace function public.iap_grant(p_user uuid, p_sku text, p_token text, p_order text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare it jsonb; coins bigint := 0; itm text; sstart date := public._season_start();
begin
  select e into it from jsonb_array_elements(public.cfg('iap')) e where e->>'sku' = p_sku;
  if it is null then raise exception 'unknown_sku'; end if;
  insert into iap_purchases(user_id, sku, purchase_token, order_id) values (p_user, p_sku, p_token, p_order);  -- unique token => no double grant
  insert into player_wallets(user_id) values (p_user) on conflict do nothing;

  case it->>'type'
    when 'remove_ads' then update player_profiles set ads_removed = true where user_id = p_user;
    when 'coins' then coins := public._coins(p_user, (it->>'coins')::bigint, 'iap_coins', p_token);
    when 'starter' then
      if (select starter_pack_bought from player_profiles where user_id = p_user for update) then raise exception 'starter_already_bought'; end if;
      update player_profiles set starter_pack_bought = true where user_id = p_user;
      coins := public._coins(p_user, (it->>'coins')::bigint, 'iap_starter', p_token);
      for itm in select jsonb_array_elements_text(it->'items') loop
        insert into player_inventory(user_id,item_id,kind,source)
          values (p_user, itm, coalesce((select e2->>'kind' from jsonb_array_elements(public.cfg('shop')) e2 where e2->>'id' = itm),'skin'), 'iap') on conflict do nothing;
      end loop;
    when 'piggy' then
      select piggy_coins into coins from player_wallets where user_id = p_user for update;
      update player_wallets set piggy_coins = 0 where user_id = p_user;
      if coins > 0 then perform public._coins(p_user, coins, 'piggy_unlock', p_token); end if;
    when 'premium' then
      update player_profiles set is_premium = true, ads_removed = true,
             premium_until = greatest(coalesce(premium_until, now()), now()) + make_interval(days => (it->>'days')::int)
       where user_id = p_user;
    when 'season_premium' then
      insert into season_pass(user_id, season_start, has_premium) values (p_user, sstart, true)
      on conflict (user_id, season_start) do update set has_premium = true;
  end case;
  return jsonb_build_object('sku', p_sku, 'coins', coins);
end $$;

revoke all on function public.iap_grant(uuid,text,text,text) from public, anon, authenticated;
grant execute on function public.iap_grant(uuid,text,text,text) to service_role;

-- Schedule smart notifications hourly (requires pg_cron enabled in Supabase dashboard)
-- select cron.schedule('queue-notifications', '0 * * * *', $$select public.queue_notifications()$$);
