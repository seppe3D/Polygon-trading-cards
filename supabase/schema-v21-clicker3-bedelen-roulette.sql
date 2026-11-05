-- Polygon Trading Cards — uitbreiding v21: Clicker 3.0, Bedelhoek en Roulette
-- Voer dit volledige bestand in één keer uit in Supabase SQL Editor (ná v20).
-- Kies bij de waarschuwing "Run without RLS". Veilig om opnieuw uit te voeren.
-- Niemand verliest iets: Poly's, upgrades en "ooit verdiend" blijven gewoon staan.
--
-- CLICKER 3.0
-- - 12 upgrades (4 nieuwe: Tijdmachine, Zwart gat, Multiversum, Poly-god)
-- - Onderzoek: per upgrade 4 verbeteringen (×2) die vrijkomen bij 10/25/50/75 stuks
-- - Trofeeën: 25 stuks, elk +2% productie
-- - Promotie: begin opnieuw en krijg Aandelen (+10% productie per aandeel, voor altijd).
--   Aandelen = derdemachtswortel van (ooit verdiend / 10 miljard)
-- - Gouden polygoon: bonus, FRENZY (×7 per klik) of OVERUREN (×5 productie, 45 s)
-- - Salaris trager: 1 🪙 per 20 minuten, spaarpot max 4 uur,
--   dagplafond 10 🪙 (+5 per promotie, max 40)
-- - Klassement van de beste klikkers
--
-- BEDELHOEK: vraag om coins (enkel als je < 100 🪙 hebt), anderen kunnen geven uit hun eigen portemonnee.
-- ROULETTE: Europese roulette (0-36) in het casino.

-- =====================================================================
-- 1. Clicker 3.0
-- =====================================================================
alter table public.clicker add column if not exists research jsonb not null default '{}'::jsonb;
alter table public.clicker add column if not exists aandelen int not null default 0;
alter table public.clicker add column if not exists promotions int not null default 0;
alter table public.clicker add column if not exists run_total numeric not null default 0;
alter table public.clicker add column if not exists golden_count int not null default 0;
alter table public.clicker add column if not exists rush_until timestamptz;

create or replace function public._clicker_items()
returns table (item_key text, icon text, name text, descr text, base_cost numeric, per_click numeric, per_sec numeric)
language sql immutable as $$
  values
    ('muis',      '🖱️', 'Gamingmuis',       '+1 Poly per klik',                50,              1,  0),
    ('stagiair',  '🧑‍💼', 'Stagiair',         '+1 Poly per seconde',             300,             0,  1),
    ('koffie',    '☕', 'Koffiemachine',     '+8 Poly per seconde',             3500,            0,  8),
    ('printer',   '🖨️', 'Turboprinter',      '+47 Poly per seconde',            40000,           0,  47),
    ('meeting',   '📊', 'Vergadermachine',   '+260 Poly per seconde',           450000,          0,  260),
    ('ceo',       '🤵', 'CEO',               '+1.400 Poly per seconde',         5000000,         0,  1400),
    ('robot',     '🤖', 'Robotleger',        '+8.000 Poly per seconde',         60000000,        0,  8000),
    ('portaal',   '🌀', 'Dimensieportaal',   '+50.000 Poly per seconde',        800000000,       0,  50000),
    ('tijd',      '⏳', 'Tijdmachine',       '+300.000 Poly per seconde',       12000000000,     0,  300000),
    ('zwartgat',  '🕳️', 'Zwart gat',         '+2 mln Poly per seconde',         200000000000,    0,  2000000),
    ('multi',     '🪐', 'Multiversum',       '+15 mln Poly per seconde',        3500000000000,   0,  15000000),
    ('polygod',   '👁️', 'Poly-god',          '+120 mln Poly per seconde',       60000000000000,  0,  120000000)
$$;

-- Onderzoek: 4 trappen per upgrade. Trap n komt vrij bij [10,25,50,75] stuks en verdubbelt die upgrade.
-- Gamingmuis: trap 1-2 verdubbelen je klik, trap 3-4 geven elk +1% van je Poly/sec per klik.
create or replace function public._clicker_research()
returns table (rkey text, item_key text, tier int, need int, cost numeric, icon text, name text, descr text)
language sql immutable as $$
  select i.item_key || ':' || t.tier, i.item_key, t.tier, t.need, i.base_cost * t.mult, i.icon,
    case when i.item_key = 'muis' then (array['Ergonomische muis', 'Muis met turbo', 'Gouden muis', 'Muis van de goden'])[t.tier]
         else (array['Beter ', 'Super-', 'Mega-', 'Ultra-'])[t.tier] || lower(i.name) end,
    case when i.item_key = 'muis' and t.tier >= 3 then 'Elke klik geeft +1% van je Poly/sec'
         when i.item_key = 'muis' then 'Klikken levert ×2 op'
         else i.name || ' produceert ×2' end
  from public._clicker_items() i
  cross join (values (1, 10, 15::numeric), (2, 25, 300), (3, 50, 20000), (4, 75, 2000000)) as t(tier, need, mult);
$$;

-- Trofeeën (berekend uit je gegevens, elk +2% productie)
create or replace function public._clicker_trophies(c public.clicker) returns jsonb
language plpgsql stable set search_path = public as $$
declare lv int := 0; owned int := 0; min_lv int := 1000000; nres int; k text; v int; out_ jsonb := '[]'::jsonb; t record;
begin
  for k in select item_key from public._clicker_items() loop
    v := coalesce((c.upgrades->>k)::int, 0);
    lv := lv + v; if v > 0 then owned := owned + 1; end if; min_lv := least(min_lv, v);
  end loop;
  select count(*) into nres from jsonb_object_keys(c.research);
  for t in select * from (values
      ('t1', '🌱', 'Eerste stapjes', '1.000 Poly''s verdiend', c.total >= 1e3),
      ('t2', '💰', 'Miljonair', '1 miljoen Poly''s verdiend', c.total >= 1e6),
      ('t3', '🏦', 'Miljardair', '1 miljard Poly''s verdiend', c.total >= 1e9),
      ('t4', '🌋', 'Biljonair', '1 biljoen Poly''s verdiend', c.total >= 1e12),
      ('t5', '🌌', 'Onmetelijk rijk', '1 biljard Poly''s verdiend', c.total >= 1e15),
      ('c1', '👆', 'Vingeroefening', '100 keer geklikt', c.clicks >= 100),
      ('c2', '✌️', 'Klikvinger', '1.000 keer geklikt', c.clicks >= 1000),
      ('c3', '🦾', 'Pees van staal', '10.000 keer geklikt', c.clicks >= 10000),
      ('c4', '⚡', 'Bliksemvinger', '50.000 keer geklikt', c.clicks >= 50000),
      ('l1', '📦', 'Inkoper', '50 upgrades in bezit', lv >= 50),
      ('l2', '🏗️', 'Bouwheer', '150 upgrades in bezit', lv >= 150),
      ('l3', '🏙️', 'Imperium', '300 upgrades in bezit', lv >= 300),
      ('l4', '🗿', 'Monument', '500 upgrades in bezit', lv >= 500),
      ('a1', '🧩', 'Van alles wat', 'Van elke upgrade minstens 1', owned = 12),
      ('a2', '🎯', 'Perfectionist', 'Van elke upgrade minstens 50', min_lv >= 50),
      ('g1', '✨', 'Goudzoeker', '1 gouden polygoon gevangen', c.golden_count >= 1),
      ('g2', '🌟', 'Goudkoorts', '10 gouden polygonen gevangen', c.golden_count >= 10),
      ('g3', '👑', 'Goudmijn', '50 gouden polygonen gevangen', c.golden_count >= 50),
      ('g4', '🐉', 'Drakenschat', '150 gouden polygonen gevangen', c.golden_count >= 150),
      ('p1', '📈', 'Promotie!', '1 keer promotie gemaakt', c.promotions >= 1),
      ('p2', '🎩', 'Carrièretijger', '3 keer promotie gemaakt', c.promotions >= 3),
      ('p3', '🏛️', 'Raad van bestuur', '10 keer promotie gemaakt', c.promotions >= 10),
      ('r1', '🔬', 'Onderzoeker', '10 onderzoeken voltooid', nres >= 10),
      ('r2', '🧪', 'Professor', '25 onderzoeken voltooid', nres >= 25),
      ('r3', '🧬', 'Nobelprijs', 'Alle 48 onderzoeken voltooid', nres >= 48)) as x(key, icon, name, descr, got) loop
    out_ := out_ || jsonb_build_object('key', t.key, 'icon', t.icon, 'name', t.name, 'desc', t.descr, 'got', t.got);
  end loop;
  return out_;
end $$;

-- Productie: per upgrade ×2 per onderzoekstrap, alles × aandelen × trofeeën
create or replace function public._clicker_rates3(c public.clicker) returns jsonb
language plpgsql stable set search_path = public as $$
declare i record; n int; tiers int; sec numeric := 0; clk numeric := 1; lv int := 0; mult numeric; troph int; mtiers int := 0; per jsonb := '{}'::jsonb;
begin
  select count(*) filter (where (x->>'got')::boolean) into troph from jsonb_array_elements(public._clicker_trophies(c)) x;
  mult := (1 + 0.10 * c.aandelen) * (1 + 0.02 * troph);
  for i in select * from public._clicker_items() loop
    n := coalesce((c.upgrades->>i.item_key)::int, 0); lv := lv + n;
    select count(*) into tiers from jsonb_object_keys(c.research) k where k like i.item_key || ':%';
    if i.item_key = 'muis' then
      mtiers := tiers;
      clk := clk + n * i.per_click * power(2, least(tiers, 2));
    else
      sec := sec + n * i.per_sec * power(2, tiers);
      per := per || jsonb_build_object(i.item_key, i.per_sec * power(2, tiers) * mult);
    end if;
  end loop;
  sec := sec * mult;
  clk := clk * mult + sec * (0.01 * greatest(0, mtiers - 2));
  return jsonb_build_object('click', clk, 'sec', sec, 'levels', lv, 'mult', mult, 'trophies', troph, 'per', per);
end $$;

-- Aandelen die je in totaal verdiend hebt (ooit verdiend, ook vóór v21)
create or replace function public._clicker_shares(p_total numeric) returns int
language sql immutable as $$ select floor(power(greatest(p_total, 0) / 1e10, 1.0 / 3))::int $$;

create or replace function public._clicker_view(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c public.clicker; r jsonb; ticks int; per_tick int; today_paid int; ready int; cap int; shares int;
begin
  select * into c from public.clicker where user_id = p_user;
  r := public._clicker_rates3(c);
  ticks := least(12, floor(extract(epoch from now() - c.last_salary) / 1200)::int);
  per_tick := 1;
  cap := least(40, 10 + 5 * c.promotions);
  today_paid := case when c.salary_day = public._today() then c.salary_today else 0 end;
  ready := least(ticks * per_tick, greatest(0, cap - today_paid));
  shares := public._clicker_shares(c.total);
  return jsonb_build_object(
    'poly', floor(c.poly), 'total', floor(c.total), 'run_total', floor(c.run_total), 'clicks', c.clicks,
    'per_click', (r->>'click')::numeric, 'per_sec', (r->>'sec')::numeric, 'levels', (r->>'levels')::int,
    'mult', (r->>'mult')::numeric,
    'frenzy_left', greatest(0, floor(extract(epoch from coalesce(c.frenzy_until, now()) - now())))::int,
    'rush_left', greatest(0, floor(extract(epoch from coalesce(c.rush_until, now()) - now())))::int,
    'items', (select jsonb_agg(jsonb_build_object('key', i.item_key, 'icon', i.icon, 'name', i.name, 'desc', i.descr,
                'level', coalesce((c.upgrades->>i.item_key)::int, 0),
                'each', coalesce(r->'per'->>i.item_key, '0')::numeric,
                'tiers', (select count(*) from jsonb_object_keys(c.research) k where k like i.item_key || ':%'),
                'cost', public._clicker_cost(i.base_cost, coalesce((c.upgrades->>i.item_key)::int, 0), 1),
                'cost10', public._clicker_cost(i.base_cost, coalesce((c.upgrades->>i.item_key)::int, 0), 10))) from public._clicker_items() i),
    'research', (select jsonb_agg(jsonb_build_object('key', x.rkey, 'item', x.item_key, 'tier', x.tier, 'need', x.need, 'cost', x.cost,
                'icon', x.icon, 'name', x.name, 'desc', x.descr, 'done', c.research ? x.rkey,
                'have', coalesce((c.upgrades->>x.item_key)::int, 0)) order by x.cost) from public._clicker_research() x),
    'trophies', public._clicker_trophies(c),
    'shares', jsonb_build_object('have', c.aandelen, 'total', shares, 'gain', greatest(0, shares - c.aandelen),
                'promotions', c.promotions,
                'next_at', 1e10 * power(greatest(shares, c.aandelen) + 1, 3)),
    'salary', jsonb_build_object('ready', ready, 'per_tick', per_tick, 'today', today_paid, 'cap', cap, 'interval', 1200,
                'next_in', 1200 - floor(extract(epoch from now() - c.last_salary))::int % 1200,
                'full', ticks >= 12),
    'golden_in', greatest(0, 120 - floor(extract(epoch from now() - c.last_golden))::int));
end $$;

-- Kliks verwerken: max 12 per seconde over de laatste 30 seconden; FRENZY ×7 per klik, OVERUREN ×5 productie
create or replace function public._clicker_apply(p_user uuid, p_clicks int) returns void
language plpgsql volatile security definer set search_path = public as $$
declare c public.clicker; r jsonb; secs numeric; n int; gain numeric; mult int := 1; rush numeric := 0;
begin
  c := public._clicker_row(p_user);
  r := public._clicker_rates3(c);
  secs := least(28800, greatest(0, extract(epoch from now() - c.last_sync)));
  n := greatest(0, least(coalesce(p_clicks, 0), ceil(least(secs, 30) * 12)::int + 12));
  if c.frenzy_until is not null and c.frenzy_until > c.last_sync then mult := 7; end if;
  -- Overuren enkel voor het deel van de tijd dat ze echt liepen
  if c.rush_until is not null and c.rush_until > c.last_sync then
    rush := least(secs, extract(epoch from least(now(), c.rush_until) - c.last_sync));
  end if;
  gain := n * (r->>'click')::numeric * mult + (secs + 4 * rush) * (r->>'sec')::numeric;
  update public.clicker set poly = poly + gain, total = total + gain, run_total = run_total + gain,
    clicks = clicks + n, last_sync = now()
    where user_id = p_user;
end $$;
revoke all on function public._clicker_apply(uuid, int) from public, anon, authenticated;

-- Wie al speelde vóór v21: "deze ronde" = wat je nu hebt aan upgrades waard is, ruwweg je totaal
update public.clicker set run_total = total where run_total = 0 and total > 0 and promotions = 0;

create or replace function public.clicker2_sync(p_clicks int default 0) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Niet ingelogd.'; end if;
  perform public._clicker_apply(auth.uid(), p_clicks);
  return public._clicker_view(auth.uid());
end $$;

create or replace function public.clicker2_buy(p_key text, p_clicks int default 0, p_count int default 1) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); c public.clicker; it record; lvl int; n int; cost numeric;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  perform public._clicker_apply(me, p_clicks);
  select * into it from public._clicker_items() where item_key = p_key;
  if not found then raise exception 'Onbekende upgrade.'; end if;
  select * into c from public.clicker where user_id = me for update;
  lvl := coalesce((c.upgrades->>p_key)::int, 0);
  if p_count = -1 then
    n := 0;
    while n < 100 and public._clicker_cost(it.base_cost, lvl, n + 1) <= c.poly loop n := n + 1; end loop;
    if n = 0 then n := 1; end if;
  else
    n := greatest(1, least(100, coalesce(p_count, 1)));
  end if;
  cost := public._clicker_cost(it.base_cost, lvl, n);
  if c.poly < cost then raise exception 'Niet genoeg Poly''s.'; end if;
  update public.clicker set poly = poly - cost, upgrades = upgrades || jsonb_build_object(p_key, lvl + n) where user_id = me;
  return public._clicker_view(me) || jsonb_build_object('bought', n);
end $$;

create or replace function public.clicker2_research(p_key text, p_clicks int default 0) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); c public.clicker; x record;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  perform public._clicker_apply(me, p_clicks);
  select * into x from public._clicker_research() where rkey = p_key;
  if not found then raise exception 'Onbekend onderzoek.'; end if;
  select * into c from public.clicker where user_id = me for update;
  if c.research ? p_key then raise exception 'Dit onderzoek heb je al.'; end if;
  if x.tier > 1 and not c.research ? (x.item_key || ':' || (x.tier - 1)) then raise exception 'Doe eerst het vorige onderzoek.'; end if;
  if coalesce((c.upgrades->>x.item_key)::int, 0) < x.need then raise exception 'Je hebt minstens % stuks nodig.', x.need; end if;
  if c.poly < x.cost then raise exception 'Niet genoeg Poly''s.'; end if;
  update public.clicker set poly = poly - x.cost, research = research || jsonb_build_object(p_key, true) where user_id = me;
  return public._clicker_view(me);
end $$;

-- Promotie: alles van deze ronde weg (Poly's, upgrades, onderzoek), Aandelen erbij. Trofeeën en "ooit verdiend" blijven.
create or replace function public.clicker2_promote(p_clicks int default 0) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); c public.clicker; s int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  perform public._clicker_apply(me, p_clicks);
  select * into c from public.clicker where user_id = me for update;
  s := public._clicker_shares(c.total);
  if s <= c.aandelen then raise exception 'Je hebt nog geen nieuwe aandelen. Verdien eerst meer Poly''s.'; end if;
  update public.clicker set aandelen = s, promotions = promotions + 1, poly = 0, run_total = 0,
    upgrades = '{}'::jsonb, research = '{}'::jsonb, frenzy_until = null, rush_until = null
  where user_id = me;
  perform public._log_activity(me, 'clicker_promo', jsonb_build_object('shares', s));
  return public._clicker_view(me) || jsonb_build_object('gained', s - c.aandelen);
end $$;

create or replace function public.clicker2_collect(p_clicks int default 0) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); c public.clicker; v jsonb; paid int; ticks int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  perform public._clicker_apply(me, p_clicks);
  v := public._clicker_view(me);
  paid := (v->'salary'->>'ready')::int;
  if paid <= 0 then raise exception 'Er is nog geen salaris om op te halen.'; end if;
  select * into c from public.clicker where user_id = me for update;
  ticks := least(12, floor(extract(epoch from now() - c.last_salary) / 1200)::int);
  update public.clicker set
    last_salary = case when ticks >= 12 or paid < ticks then now() else last_salary + ticks * interval '20 minutes' end,
    salary_today = (case when salary_day = public._today() then salary_today else 0 end) + paid,
    salary_day = public._today()
  where user_id = me;
  perform public._give_coins(me, paid, 'clicker', null);
  return public._clicker_view(me) || jsonb_build_object('paid', paid,
    'wallet', (select polycoins from public.user_wallet where user_id = me));
end $$;

-- Gouden polygoon: 40% bonus (90 s productie), 30% FRENZY (30 s ×7 per klik), 30% OVERUREN (45 s ×5 productie)
create or replace function public.clicker2_golden(p_clicks int default 0) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); c public.clicker; r jsonb; bonus numeric := 0; kind text; x float8 := random();
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  perform public._clicker_apply(me, p_clicks);
  select * into c from public.clicker where user_id = me for update;
  if now() - c.last_golden < interval '2 minutes' then raise exception 'De gouden polygoon is er nog niet.'; end if;
  r := public._clicker_rates3(c);
  if x < .4 then
    kind := 'bonus';
    bonus := greatest((r->>'sec')::numeric * 90, (r->>'click')::numeric * 50);
    update public.clicker set poly = poly + bonus, total = total + bonus, run_total = run_total + bonus,
      last_golden = now(), golden_count = golden_count + 1 where user_id = me;
  elsif x < .7 then
    kind := 'frenzy';
    update public.clicker set frenzy_until = now() + interval '30 seconds', last_golden = now(), golden_count = golden_count + 1 where user_id = me;
  else
    kind := 'rush';
    update public.clicker set rush_until = now() + interval '45 seconds', last_golden = now(), golden_count = golden_count + 1 where user_id = me;
  end if;
  return public._clicker_view(me) || jsonb_build_object('kind', kind, 'bonus', floor(bonus));
end $$;

-- Klassement: top 10 op "ooit verdiend"
create or replace function public.clicker2_top() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x.total desc), '[]'::jsonb) from (
    select p.id, p.display_name as name, p.avatar_url, p.equipped_ring as ring, floor(c.total) as total,
      c.aandelen, c.promotions, c.user_id = auth.uid() as me
    from public.clicker c join public.profiles p on p.id = c.user_id
    where c.total > 0 order by c.total desc limit 10) x;
$$;

-- =====================================================================
-- 2. Bedelhoek
-- =====================================================================
create table if not exists public.beg_requests (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  amount int not null check (amount between 5 and 100),
  reason text not null check (char_length(reason) between 3 and 140),
  raised int not null default 0,
  status text not null default 'open' check (status in ('open', 'done', 'closed')),
  created_at timestamptz not null default now(),
  closed_at timestamptz
);
create index if not exists beg_requests_status_idx on public.beg_requests (status, created_at desc);
create table if not exists public.beg_gifts (
  id bigserial primary key,
  request_id bigint not null references public.beg_requests(id) on delete cascade,
  giver_id uuid not null references auth.users(id) on delete cascade,
  amount int not null check (amount > 0),
  created_at timestamptz not null default now()
);
create index if not exists beg_gifts_req_idx on public.beg_gifts (request_id);
alter table public.beg_requests enable row level security;
alter table public.beg_gifts enable row level security;
-- Geen policies: lezen en schrijven enkel via de functies hieronder

create or replace function public._beg_json(r public.beg_requests) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', r.id, 'user_id', r.user_id, 'amount', r.amount, 'reason', r.reason, 'raised', r.raised,
    'status', r.status, 'at', r.created_at, 'mine', r.user_id = auth.uid(),
    'name', p.display_name, 'avatar_url', p.avatar_url, 'ring', p.equipped_ring,
    'gifts', coalesce((select jsonb_agg(jsonb_build_object('name', gp.display_name, 'amount', g.amount, 'me', g.giver_id = auth.uid()) order by g.created_at)
              from public.beg_gifts g join public.profiles gp on gp.id = g.giver_id where g.request_id = r.id), '[]'::jsonb))
  from public.profiles p where p.id = r.user_id;
$$;

create or replace function public.beg_list() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  -- Oude oproepen (ouder dan 3 dagen) sluiten
  update public.beg_requests set status = 'closed', closed_at = now() where status = 'open' and created_at < now() - interval '3 days';
  return jsonb_build_object(
    'open', coalesce((select jsonb_agg(public._beg_json(r) order by r.created_at desc) from public.beg_requests r where r.status = 'open'), '[]'::jsonb),
    'done', coalesce((select jsonb_agg(public._beg_json(r) order by r.closed_at desc) from (
               select * from public.beg_requests where status <> 'open' and raised > 0 order by closed_at desc limit 8) r), '[]'::jsonb),
    'wallet', (select polycoins from public.user_wallet where user_id = me),
    'can_beg', not exists (select 1 from public.beg_requests where user_id = me and (status = 'open'
                   or (created_at at time zone 'Europe/Brussels')::date = public._today())),
    'given_today', coalesce((select sum(g.amount) from public.beg_gifts g where g.giver_id = me
                   and (g.created_at at time zone 'Europe/Brussels')::date = public._today()), 0));
end $$;

create or replace function public.beg_create(p_amount int, p_reason text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); w int; r public.beg_requests;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select polycoins into w from public.user_wallet where user_id = me;
  if coalesce(w, 0) >= 100 then raise exception 'Je hebt al % 🪙. Bedelen mag enkel met minder dan 100 🪙.', w; end if;
  if p_amount is null or p_amount < 5 or p_amount > 100 then raise exception 'Vraag tussen 5 en 100 🪙.'; end if;
  if char_length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Vertel waarom je het nodig hebt (minstens 3 tekens).'; end if;
  if exists (select 1 from public.beg_requests where user_id = me and status = 'open') then raise exception 'Je bedelt al. Sluit eerst je vorige oproep.'; end if;
  if exists (select 1 from public.beg_requests where user_id = me and (created_at at time zone 'Europe/Brussels')::date = public._today()) then
    raise exception 'Je mag maar één keer per dag bedelen. Morgen opnieuw!'; end if;
  insert into public.beg_requests (user_id, amount, reason) values (me, p_amount, left(trim(p_reason), 140)) returning * into r;
  return public._beg_json(r);
end $$;

create or replace function public.beg_give(p_id bigint, p_amount int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); r public.beg_requests; amt int; w int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select * into r from public.beg_requests where id = p_id for update;
  if not found or r.status <> 'open' then raise exception 'Deze oproep is al gesloten.'; end if;
  if r.user_id = me then raise exception 'Je kan jezelf niets geven 😄'; end if;
  if p_amount is null or p_amount < 1 or p_amount > 50 then raise exception 'Geef tussen 1 en 50 🪙.'; end if;
  amt := least(p_amount, r.amount - r.raised);
  w := public._shop_spend(me, amt, 'beg_give', jsonb_build_object('request', r.id));
  perform public._give_coins(r.user_id, amt, 'beg_receive', jsonb_build_object('request', r.id, 'from', me));
  insert into public.beg_gifts (request_id, giver_id, amount) values (r.id, me, amt);
  update public.beg_requests set raised = raised + amt,
    status = case when raised + amt >= amount then 'done' else status end,
    closed_at = case when raised + amt >= amount then now() else closed_at end
  where id = r.id returning * into r;
  return jsonb_build_object('given', amt, 'wallet', w, 'request', public._beg_json(r));
end $$;

create or replace function public.beg_close(p_id bigint) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  update public.beg_requests set status = 'closed', closed_at = now() where id = p_id and user_id = auth.uid() and status = 'open';
  if not found then raise exception 'Oproep niet gevonden.'; end if;
end $$;

-- =====================================================================
-- 3. Roulette (Europees, 0-36)
-- Inzetten: [{"t":"num","v":17,"a":10}, {"t":"red","a":25}, ...]
-- num ×36 · red/black/even/odd/low/high ×2 · dozen/col (v 1-3) ×3. Totaal max 200 🪙.
-- =====================================================================
create or replace function public.casino_roulette(p_bets jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid(); b jsonb; total int := 0; win int := 0; n int; t text; v int; a int; hit boolean; mult int; w int;
  reds int[] := array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36];
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if jsonb_typeof(p_bets) <> 'array' or jsonb_array_length(p_bets) = 0 then raise exception 'Leg eerst fiches op de tafel.'; end if;
  if jsonb_array_length(p_bets) > 40 then raise exception 'Te veel inzetten.'; end if;
  for b in select * from jsonb_array_elements(p_bets) loop
    t := b->>'t'; v := coalesce((b->>'v')::int, 0); a := (b->>'a')::int;
    if a is null or a < 1 then raise exception 'Ongeldige inzet.'; end if;
    if t not in ('num', 'red', 'black', 'even', 'odd', 'low', 'high', 'dozen', 'col') then raise exception 'Onbekende inzet.'; end if;
    if t = 'num' and (v < 0 or v > 36) then raise exception 'Ongeldig getal.'; end if;
    if t in ('dozen', 'col') and (v < 1 or v > 3) then raise exception 'Ongeldige inzet.'; end if;
    total := total + a;
  end loop;
  if total > 200 then raise exception 'Je kan maximaal 200 🪙 per draai inzetten.'; end if;
  w := public._shop_spend(me, total, 'casino_roulette');
  n := floor(random() * 37)::int;
  for b in select * from jsonb_array_elements(p_bets) loop
    t := b->>'t'; v := coalesce((b->>'v')::int, 0); a := (b->>'a')::int;
    hit := case t
      when 'num' then n = v
      when 'red' then n = any(reds)
      when 'black' then n > 0 and not n = any(reds)
      when 'even' then n > 0 and n % 2 = 0
      when 'odd' then n % 2 = 1
      when 'low' then n between 1 and 18
      when 'high' then n between 19 and 36
      when 'dozen' then n between (v - 1) * 12 + 1 and v * 12
      when 'col' then n > 0 and (n - 1) % 3 = v - 1 end;
    mult := case when t = 'num' then 36 when t in ('dozen', 'col') then 3 else 2 end;
    if hit then win := win + a * mult; end if;
  end loop;
  if win > 0 then perform public._tb_pay(me, win); w := w + win; end if;
  insert into public.casino_log (user_id, game, bet, win, detail) values (me, 'roulette', total, win, jsonb_build_object('n', n, 'bets', p_bets));
  if win >= 500 then perform public._log_activity(me, 'roulette_win', jsonb_build_object('win', win, 'n', n)); end if;
  return jsonb_build_object('n', n, 'bet', total, 'win', win, 'wallet', w);
end $$;

-- Rechten
do $$
declare f text;
begin
  foreach f in array array['public.clicker2_sync(int)', 'public.clicker2_buy(text, int, int)', 'public.clicker2_collect(int)',
                           'public.clicker2_golden(int)', 'public.clicker2_research(text, int)', 'public.clicker2_promote(int)',
                           'public.clicker2_top()', 'public.beg_list()', 'public.beg_create(int, text)', 'public.beg_give(bigint, int)',
                           'public.beg_close(bigint)', 'public.casino_roulette(jsonb)'] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
  foreach f in array array['public._clicker_view(uuid)', 'public._clicker_rates3(public.clicker)', 'public._clicker_trophies(public.clicker)',
                           'public._beg_json(public.beg_requests)'] loop
    execute 'revoke all on function ' || f || ' from public, anon, authenticated';
  end loop;
end $$;
