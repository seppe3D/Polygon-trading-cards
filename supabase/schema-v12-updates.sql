-- Polygon Trading Cards — uitbreiding v12: opdrachten, collectie-beloningen, nieuws, klassement,
-- kaarten opwaarderen, cosmetica en opruimen.
-- Voer dit volledige bestand in één keer uit in Supabase SQL Editor (ná v8 t/m v11).
-- Kies bij de waarschuwing "Run without RLS": het script zet RLS zelf aan. Veilig om opnieuw uit te voeren.

-- =====================================================================
-- 0. Opruimen: het oude gevechtssysteem (v6) mag niet meer gebruikt worden
--    (de tabel public.battles blijft bestaan voor de historiek in de ranglijst)
-- =====================================================================
drop function if exists public.create_battle(uuid, int[]);
drop function if exists public.respond_battle(bigint, text, int[]);
drop function if exists public.battle_leaderboard();
drop function if exists public._battle_run(int[], int[]);
drop function if exists public._battle_team_ok(uuid, int[]);
drop function if exists public._battle_state(int, int[], int, int[]);

-- Profielen: gebruikers mogen enkel hun naam en foto zelf aanpassen
-- (vriendencode en cosmetica kunnen zo niet vervalst worden)
alter table public.profiles add column if not exists equipped_frame text;
alter table public.profiles add column if not exists equipped_ring text;
alter table public.profiles add column if not exists equipped_title text;
revoke update on public.profiles from anon, authenticated;
grant update (display_name, avatar_url) on public.profiles to authenticated;

-- Hulpfunctie: polycoins bijschrijven + loggen
create or replace function public._give_coins(p_user uuid, p_amount int, p_kind text, p_detail jsonb default null) returns int
language plpgsql volatile security definer set search_path = public as $$
declare v int;
begin
  insert into public.user_wallet (user_id, polycoins) values (p_user, p_amount)
    on conflict (user_id) do update set polycoins = public.user_wallet.polycoins + excluded.polycoins
    returning polycoins into v;
  insert into public.shop_log (user_id, kind, amount, detail) values (p_user, p_kind, p_amount, p_detail);
  return v;
end $$;
revoke all on function public._give_coins(uuid, int, text, jsonb) from public, anon, authenticated;

create or replace function public._today() returns date
language sql stable as $$ select public._wordle_local()::date $$;

-- =====================================================================
-- 1. Nieuws (activiteitenfeed): enkel leesbaar via activity_feed()
-- =====================================================================
create table if not exists public.activity (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists activity_time_idx on public.activity (created_at desc);
alter table public.activity enable row level security;
-- Bewust GEEN policies: lezen via activity_feed() (enkel jezelf en je vrienden)

create or replace function public._log_activity(p_user uuid, p_kind text, p_data jsonb) returns void
language sql security definer set search_path = public as $$
  insert into public.activity (user_id, kind, data) values (p_user, p_kind, coalesce(p_data, '{}'::jsonb));
$$;
revoke all on function public._log_activity(uuid, text, jsonb) from public, anon, authenticated;

-- Eerste exemplaar van een legendary
create or replace function public._trg_legendary() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.cards where id = new.card_id and rarity = 'legendary')
     and (select count(*) from public.user_cards where user_id = new.user_id and card_id = new.card_id) = 1 then
    perform public._log_activity(new.user_id, 'legendary', jsonb_build_object('card', new.card_id));
  end if;
  return null;
end $$;
drop trigger if exists activity_legendary on public.user_cards;
create trigger activity_legendary after insert on public.user_cards for each row execute function public._trg_legendary();

-- Gewonnen battle tegen een vriend
create or replace function public._trg_battle_win() returns trigger
language plpgsql security definer set search_path = public as $$
declare w uuid; l uuid;
begin
  if new.mode = 'pvp' and new.status = 'done' and old.status is distinct from 'done' and new.winner is not null then
    w := case new.winner when 'A' then new.player_a else new.player_b end;
    l := case new.winner when 'A' then new.player_b else new.player_a end;
    perform public._log_activity(w, 'battle_win', jsonb_build_object('opponent', l, 'forfeit', new.forfeit));
  end if;
  return null;
end $$;
drop trigger if exists activity_battle_win on public.tbattles;
create trigger activity_battle_win after update on public.tbattles for each row execute function public._trg_battle_win();

create or replace function public.activity_feed() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x.created_at desc), '[]'::jsonb) from (
    select a.id, a.user_id, p.display_name, p.equipped_ring, a.kind, a.data, a.created_at, o.display_name as other_name
    from public.activity a join public.profiles p on p.id = a.user_id
    left join public.profiles o on o.id = (a.data->>'opponent')::uuid
    where a.user_id = auth.uid()
       or a.user_id in (select friend_id from public.friendships where user_id = auth.uid())
    order by a.created_at desc limit 40
  ) x;
$$;

-- =====================================================================
-- 2. Collectie-beloningen: pagina compleet = +100, volledig boek = +250 en titel
-- =====================================================================
create table if not exists public.collection_rewards (
  user_id uuid not null references auth.users(id) on delete cascade,
  person text not null,           -- naam van de collega, of '*BOOK*' voor het volledige boek
  claimed_at timestamptz not null default now(),
  primary key (user_id, person)
);
alter table public.collection_rewards enable row level security;
drop policy if exists "badges lezen" on public.collection_rewards;
create policy "badges lezen" on public.collection_rewards for select to authenticated using (true);

-- =====================================================================
-- 3. Cosmetica
-- =====================================================================
create or replace function public._cosmetics()
returns table (item_key text, kind text, name text, price int)
language sql immutable as $$
  values
    ('frame_gold',     'frame', 'Gouden kaartrand',        150),
    ('frame_neon',     'frame', 'Neon-kaartrand',          200),
    ('frame_holo',     'frame', 'Holografische kaartrand', 300),
    ('ring_green',     'ring',  'Groene profielring',       80),
    ('ring_gold',      'ring',  'Gouden profielring',      150),
    ('ring_rainbow',   'ring',  'Regenboogring',           250),
    ('title_coffee',   'title', 'Koffiebaas',              100),
    ('title_wizard',   'title', 'Wordle Wizard',           150),
    ('title_boss',     'title', 'Battle Boss',             150),
    ('title_collector','title', 'Meesterverzamelaar',      null)   -- enkel te verdienen met een volledig boek
$$;

create table if not exists public.cosmetics_owned (
  user_id uuid not null references auth.users(id) on delete cascade,
  item_key text not null,
  acquired_at timestamptz not null default now(),
  primary key (user_id, item_key)
);
alter table public.cosmetics_owned enable row level security;
drop policy if exists "eigen cosmetica lezen" on public.cosmetics_owned;
create policy "eigen cosmetica lezen" on public.cosmetics_owned for select to authenticated using (auth.uid() = user_id);

create or replace function public.cosmetics_state() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('key', c.item_key, 'kind', c.kind, 'name', c.name, 'price', c.price,
           'owned', exists (select 1 from public.cosmetics_owned o where o.user_id = auth.uid() and o.item_key = c.item_key))), '[]'::jsonb)
  from public._cosmetics() c;
$$;

create or replace function public.buy_cosmetic(p_key text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); c record; v int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select * into c from public._cosmetics() where item_key = p_key;
  if not found then raise exception 'Onbekend item.'; end if;
  if c.price is null then raise exception 'Dit item kan je niet kopen, enkel verdienen.'; end if;
  if exists (select 1 from public.cosmetics_owned where user_id = me and item_key = p_key) then
    raise exception 'Je hebt dit al.';
  end if;
  v := public._shop_spend(me, c.price, 'cosmetic', jsonb_build_object('item', p_key));
  insert into public.cosmetics_owned (user_id, item_key) values (me, p_key);
  return jsonb_build_object('wallet', v);
end $$;

create or replace function public.equip_cosmetic(p_kind text, p_key text default null) returns void
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if p_kind not in ('frame', 'ring', 'title') then raise exception 'Onbekend soort item.'; end if;
  if p_key is not null and not exists (
    select 1 from public.cosmetics_owned o join public._cosmetics() c on c.item_key = o.item_key
    where o.user_id = me and o.item_key = p_key and c.kind = p_kind) then
    raise exception 'Je hebt dit item niet.';
  end if;
  update public.profiles set
    equipped_frame = case when p_kind = 'frame' then p_key else equipped_frame end,
    equipped_ring  = case when p_kind = 'ring'  then p_key else equipped_ring end,
    equipped_title = case when p_kind = 'title' then p_key else equipped_title end
  where id = me;
end $$;

-- Collectie-beloningen ophalen (wordt automatisch aangeroepen door de site)
create or replace function public.claim_collection_rewards() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); r record; out_ jsonb := '[]'::jsonb;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  for r in
    select c.person from public.cards c
    group by c.person
    having count(*) = count(*) filter (where exists (select 1 from public.user_cards u where u.user_id = me and u.card_id = c.id))
  loop
    insert into public.collection_rewards (user_id, person) values (me, r.person) on conflict do nothing;
    if found then
      perform public._give_coins(me, 100, 'collection', jsonb_build_object('person', r.person));
      perform public._log_activity(me, 'page_complete', jsonb_build_object('person', r.person));
      out_ := out_ || jsonb_build_object('person', r.person, 'reward', 100);
    end if;
  end loop;
  -- Volledig boek: alle collega's (troostkatten niet nodig)
  if not exists (
    select 1 from public.cards c where c.rarity <> 'cat'
      and not exists (select 1 from public.user_cards u where u.user_id = me and u.card_id = c.id)
  ) and exists (select 1 from public.cards where rarity <> 'cat') then
    insert into public.collection_rewards (user_id, person) values (me, '*BOOK*') on conflict do nothing;
    if found then
      perform public._give_coins(me, 250, 'collection', jsonb_build_object('person', '*BOOK*'));
      insert into public.cosmetics_owned (user_id, item_key) values (me, 'title_collector') on conflict do nothing;
      perform public._log_activity(me, 'book_complete', '{}'::jsonb);
      out_ := out_ || jsonb_build_object('person', '*BOOK*', 'reward', 250);
    end if;
  end if;
  return out_;
end $$;

-- =====================================================================
-- 4. Kaarten opwaarderen: 2 dubbels → level +1 (max ★3), +10% HP/ATK/DEF per level in Battle
-- =====================================================================
create table if not exists public.card_levels (
  user_id uuid not null references auth.users(id) on delete cascade,
  card_id int not null references public.cards(id) on delete cascade,
  level int not null default 1 check (level between 1 and 3),
  primary key (user_id, card_id)
);
alter table public.card_levels enable row level security;
drop policy if exists "levels lezen" on public.card_levels;
create policy "levels lezen" on public.card_levels for select to authenticated using (true);

create or replace function public.upgrade_card(p_card_id int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); v_have int; v_level int; i int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select count(*) into v_have from public.user_cards where user_id = me and card_id = p_card_id;
  select coalesce((select level from public.card_levels where user_id = me and card_id = p_card_id), 1) into v_level;
  if v_level >= 3 then raise exception 'Deze kaart is al op het hoogste level (★3).'; end if;
  if v_have < 3 then raise exception 'Je hebt 2 dubbels nodig (je hebt er %).', greatest(v_have - 1, 0); end if;
  for i in 1..2 loop
    delete from public.user_cards where id = (select id from public.user_cards where user_id = me and card_id = p_card_id order by id desc limit 1);
  end loop;
  insert into public.card_levels (user_id, card_id, level) values (me, p_card_id, v_level + 1)
    on conflict (user_id, card_id) do update set level = excluded.level;
  insert into public.shop_log (user_id, kind, amount, detail) values (me, 'upgrade', 0, jsonb_build_object('card', p_card_id, 'level', v_level + 1));
  if v_level + 1 = 3 then
    perform public._log_activity(me, 'max_level', jsonb_build_object('card', p_card_id));
  end if;
  return jsonb_build_object('level', v_level + 1);
end $$;

-- Battle-kant met levels van de eigenaar (p_user null = computer, zonder levels)
create or replace function public._tb_side(p_cards int[], p_user uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'cards', jsonb_agg(c.id order by u.ord),
    'hp',  jsonb_agg(round(coalesce(c.hp, 50) * m.f)::int order by u.ord),
    'max', jsonb_agg(round(coalesce(c.hp, 50) * m.f)::int order by u.ord),
    'atk', jsonb_agg(round(coalesce(c.attack, 10) * m.f)::int order by u.ord),
    'def', jsonb_agg(round(coalesce(c.defense, 0) * m.f)::int order by u.ord),
    'sp',  jsonb_agg(coalesce(c.special_power, 0) order by u.ord),
    'lvl', jsonb_agg(m.lvl order by u.ord),
    'active', 0, 'energy', 1)
  from unnest(p_cards) with ordinality u(id, ord)
  join public.cards c on c.id = u.id
  cross join lateral (
    select coalesce((select l.level from public.card_levels l where l.user_id = p_user and l.card_id = c.id), 1) as lvl
  ) lv
  cross join lateral (select lv.lvl, 1 + 0.1 * (lv.lvl - 1) as f) m;
$$;
revoke all on function public._tb_side(int[], uuid) from public, anon, authenticated;

-- Gevechten starten met levels (zelfde functies als v9, enkel _tb_side met eigenaar)
create or replace function public.tb_start_pve(p_cards int[], p_difficulty text) returns bigint
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  opp int[] := '{}'; c int; rar text; v_id bigint;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if p_difficulty not in ('easy', 'normal', 'hard') then raise exception 'Onbekende moeilijkheid.'; end if;
  if not public._tb_team_ok(me, p_cards) then raise exception 'Kies 3 verschillende kaarten die je bezit.'; end if;
  -- Een eventueel vorig, onafgewerkt oefengevecht vervalt
  update public.tbattles set status = 'cancelled', updated_at = now()
    where player_a = me and mode = 'pve' and status = 'active';
  -- Tegenstander: per kaart een kaart van dezelfde zeldzaamheid (makkelijk: lager, moeilijk: hoger)
  foreach c in array p_cards loop
    select rarity into rar from public.cards where id = c;
    if rar = 'cat' then rar := 'common'; end if;
    rar := case p_difficulty
      when 'easy' then case rar when 'legendary' then 'epic' else 'common' end
      when 'hard' then case rar when 'common' then 'epic' else 'legendary' end
      else rar end;
    opp := opp || (select id from public.cards where rarity = rar and not (id = any(opp)) order by random() limit 1);
  end loop;
  insert into public.tbattles (mode, difficulty, player_a, status, state)
  values ('pve', p_difficulty, me, 'active',
          jsonb_build_object('A', public._tb_side(p_cards, me), 'B', public._tb_side(opp, null), 'events', '[]'::jsonb,
                             'moved', '{"A": false, "B": false}'::jsonb))
  returning id into v_id;
  insert into public.tbattle_hidden (battle_id, side) values (v_id, 'A'), (v_id, 'B');
  return v_id;
end $$;

create or replace function public.tb_respond(p_id bigint, p_action text, p_cards int[] default null) returns void
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); b public.tbattles; a_cards int[];
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select * into b from public.tbattles where id = p_id for update;
  if not found or b.mode <> 'pvp' then raise exception 'Battle niet gevonden.'; end if;
  if b.status <> 'pending' then raise exception 'Deze uitdaging is al afgehandeld.'; end if;
  if p_action = 'cancel' then
    if me <> b.player_a then raise exception 'Enkel de uitdager kan annuleren.'; end if;
    update public.tbattles set status = 'cancelled', updated_at = now() where id = p_id;
    return;
  end if;
  if me <> b.player_b then raise exception 'Deze uitdaging is niet aan jou gericht.'; end if;
  if p_action = 'decline' then
    update public.tbattles set status = 'declined', updated_at = now() where id = p_id;
    return;
  end if;
  if p_action <> 'accept' then raise exception 'Onbekende actie.'; end if;
  if not public._tb_team_ok(me, p_cards) then raise exception 'Kies 3 verschillende kaarten die je bezit.'; end if;
  select cards into a_cards from public.tbattle_hidden where battle_id = p_id and side = 'A';
  if not public._tb_team_ok(b.player_a, a_cards) then
    update public.tbattles set status = 'cancelled', updated_at = now() where id = p_id;
    return;
  end if;
  insert into public.tbattle_hidden (battle_id, side) values (p_id, 'B') on conflict do nothing;
  update public.tbattles set status = 'active', updated_at = now(),
    state = jsonb_build_object('A', public._tb_side(a_cards, b.player_a), 'B', public._tb_side(p_cards, me), 'events', '[]'::jsonb,
                               'moved', '{"A": false, "B": false}'::jsonb)
  where id = p_id;
end $$;

-- =====================================================================
-- 5. Dagelijkse opdrachten (voor iedereen dezelfde 3 per dag)
-- =====================================================================
create table if not exists public.quest_claims (
  user_id uuid not null references auth.users(id) on delete cascade,
  quest_date date not null,
  quest_key text not null,
  claimed_at timestamptz not null default now(),
  primary key (user_id, quest_date, quest_key)
);
alter table public.quest_claims enable row level security;
drop policy if exists "eigen opdrachten lezen" on public.quest_claims;
create policy "eigen opdrachten lezen" on public.quest_claims for select to authenticated using (auth.uid() = user_id);

create or replace function public._quests()
returns table (quest_key text, grp text, title text, target int, reward int)
language sql immutable as $$
  values
    ('wordle_solve4',     'wordle', 'Los een Wordle op in 4 pogingen of minder',             1, 20),
    ('wordle_both',       'wordle', 'Speel beide Wordles van vandaag',                       2, 25),
    ('battle_win_normal', 'battle', 'Win een battle tegen de computer op Normaal of Moeilijk', 1, 20),
    ('battle_win_friend', 'battle', 'Win een battle tegen een vriend',                       1, 30),
    ('battle_play3',      'battle', 'Speel 3 battles uit',                                   3, 20),
    ('friend_challenge',  'other',  'Daag een vriend uit voor een battle',                   1, 15),
    ('sell_dupe',         'other',  'Verkoop een dubbel in de Shop',                         1, 10),
    ('upgrade_card',      'other',  'Waardeer een kaart op met dubbels',                     1, 20),
    ('open_pack',         'other',  'Koop een pakje in de Shop',                             1, 15)
$$;

-- De 3 opdrachten van een dag: één Wordle, één Battle en één andere (vaste keuze per datum)
create or replace function public._quests_for(p_date date)
returns table (quest_key text, grp text, title text, target int, reward int)
language sql immutable as $$
  select distinct on (q.grp) q.*
  from public._quests() q
  order by q.grp, md5(p_date::text || q.quest_key)
$$;

create or replace function public._quest_progress(p_user uuid, p_key text, p_date date) returns int
language plpgsql stable security definer set search_path = public as $$
declare n int := 0;
begin
  if p_key = 'wordle_solve4' then
    select count(*) into n from public.wordle_games where user_id = p_user and round_date = p_date and status = 'won' and attempts <= 4;
  elsif p_key = 'wordle_both' then
    select count(*) into n from public.wordle_games where user_id = p_user and round_date = p_date and status <> 'playing';
  elsif p_key in ('battle_win_normal', 'battle_win_friend', 'battle_play3') then
    select count(*) into n from public.tbattles b
    where b.status = 'done' and (b.finished_at at time zone 'Europe/Brussels')::date = p_date
      and (b.player_a = p_user or b.player_b = p_user)
      and case p_key
        when 'battle_win_normal' then b.mode = 'pve' and b.difficulty in ('normal', 'hard') and b.winner = 'A'
        when 'battle_win_friend' then b.mode = 'pvp' and b.winner = case when b.player_a = p_user then 'A' else 'B' end
        else true end;
  elsif p_key = 'friend_challenge' then
    select count(*) into n from public.tbattles
    where mode = 'pvp' and player_a = p_user and (created_at at time zone 'Europe/Brussels')::date = p_date;
  else
    select count(*) into n from public.shop_log
    where user_id = p_user and (created_at at time zone 'Europe/Brussels')::date = p_date
      and case p_key when 'sell_dupe' then kind = 'sell_duplicate'
                     when 'upgrade_card' then kind = 'upgrade'
                     when 'open_pack' then kind like 'pack_%'
                     else false end;
  end if;
  return n;
end $$;
revoke all on function public._quest_progress(uuid, text, date) from public, anon, authenticated;

create or replace function public.quest_state() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'key', q.quest_key, 'title', q.title, 'reward', q.reward, 'target', q.target,
      'progress', least(q.target, public._quest_progress(auth.uid(), q.quest_key, public._today())),
      'claimed', exists (select 1 from public.quest_claims c where c.user_id = auth.uid() and c.quest_date = public._today() and c.quest_key = q.quest_key))
    order by case q.grp when 'wordle' then 1 when 'battle' then 2 else 3 end), '[]'::jsonb)
  from public._quests_for(public._today()) q
  where auth.uid() is not null;
$$;

create or replace function public.claim_quest(p_key text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); d date := public._today(); q record; v int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select * into q from public._quests_for(d) where quest_key = p_key;
  if not found then raise exception 'Deze opdracht hoort niet bij vandaag.'; end if;
  if public._quest_progress(me, p_key, d) < q.target then raise exception 'Deze opdracht is nog niet voltooid.'; end if;
  insert into public.quest_claims (user_id, quest_date, quest_key) values (me, d, p_key) on conflict do nothing;
  if not found then raise exception 'Je hebt deze beloning al opgehaald.'; end if;
  v := public._give_coins(me, q.reward, 'quest', jsonb_build_object('quest', p_key));
  return jsonb_build_object('reward', q.reward, 'wallet', v);
end $$;

-- =====================================================================
-- 6. Wordle-klassement van vandaag (jij + je vrienden, zonder het woord)
-- =====================================================================
create or replace function public.wordle_board_today() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('user_id', g.user_id, 'name', p.display_name, 'slot', g.slot,
           'status', g.status, 'attempts', g.attempts, 'max', 6 + case when g.extra_guess then 1 else 0 end)
         order by g.slot, g.status = 'won' desc, g.attempts nulls last, g.finished_at), '[]'::jsonb)
  from public.wordle_games g join public.profiles p on p.id = g.user_id
  where g.round_date = public._today() and g.status <> 'playing'
    and (g.user_id = auth.uid() or g.user_id in (select friend_id from public.friendships where user_id = auth.uid()));
$$;

grant execute on function public.activity_feed() to authenticated;
grant execute on function public.cosmetics_state() to authenticated;
grant execute on function public.buy_cosmetic(text) to authenticated;
grant execute on function public.equip_cosmetic(text, text) to authenticated;
grant execute on function public.claim_collection_rewards() to authenticated;
grant execute on function public.upgrade_card(int) to authenticated;
grant execute on function public.quest_state() to authenticated;
grant execute on function public.claim_quest(text) to authenticated;
grant execute on function public.wordle_board_today() to authenticated;
grant select on public.collection_rewards, public.card_levels, public.cosmetics_owned, public.quest_claims to authenticated;
