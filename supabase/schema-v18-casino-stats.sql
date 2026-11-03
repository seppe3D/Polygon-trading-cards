-- Polygon Trading Cards — uitbreiding v18: casinostatistieken voor iedereen
-- Voer dit volledige bestand in één keer uit in Supabase SQL Editor (ná v13). Kies "Run without RLS". Veilig om opnieuw uit te voeren.
--
-- Toont per speler hoeveel er ingezet en gewonnen werd (fruitautomaat, blackjack, krasbiljet)
-- en wat het gratis rad opleverde. Enkel totalen, geen afzonderlijke spelletjes.
-- p_days = null: altijd · 7: laatste 7 dagen · 1: vandaag

create or replace function public.casino_stats(p_days int default null) returns jsonb
language sql stable security definer set search_path = public as $$
  with log as (
    select * from public.casino_log
    where p_days is null
       or (created_at at time zone 'Europe/Brussels')::date > public._today() - p_days
  ), per_game as (
    select user_id, game, count(*) as n, sum(bet) as bet, sum(win) as win, max(win - bet) as best,
           count(*) filter (where win > bet) as wins, count(*) filter (where win < bet) as losses
    from log group by user_id, game
  ), per_user as (
    select user_id,
      sum(n) filter (where game <> 'wheel') as games,
      coalesce(sum(bet) filter (where game <> 'wheel'), 0) as bet,
      coalesce(sum(win) filter (where game <> 'wheel'), 0) as win,
      coalesce(max(best) filter (where game <> 'wheel'), 0) as best,
      coalesce(sum(wins) filter (where game <> 'wheel'), 0) as wins,
      coalesce(sum(losses) filter (where game <> 'wheel'), 0) as losses,
      jsonb_object_agg(game, jsonb_build_object('n', n, 'bet', bet, 'win', win, 'best', best, 'wins', wins, 'losses', losses)) as games_detail
    from per_game group by user_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'user_id', u.user_id, 'name', p.display_name, 'avatar_url', p.avatar_url, 'ring', p.equipped_ring,
      'games', coalesce(u.games, 0), 'bet', u.bet, 'win', u.win, 'net', u.win - u.bet,
      'rtp', case when u.bet > 0 then round(u.win::numeric / u.bet * 100) end,
      'best', u.best, 'wins', u.wins, 'losses', u.losses,
      'jackpots', (select count(*) from log l where l.user_id = u.user_id and l.game = 'slots' and (l.detail->>'jackpot')::boolean),
      'detail', u.games_detail)
    order by u.win - u.bet desc), '[]'::jsonb)
  from per_user u join public.profiles p on p.id = u.user_id
  where auth.uid() is not null;
$$;
revoke all on function public.casino_stats(int) from public, anon;
grant execute on function public.casino_stats(int) to authenticated;
