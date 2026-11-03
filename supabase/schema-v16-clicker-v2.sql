-- Polygon Trading Cards — uitbreiding v16: Clicker 2.0
-- Voer dit volledige bestand in één keer uit in Supabase SQL Editor (ná v14).
-- Kies bij de waarschuwing "Run without RLS". Veilig om opnieuw uit te voeren.
--
-- - Alles duurder (prijs stijgt 20% per gekocht exemplaar) en 2 nieuwe upgrades
-- - Kopen per 1, 10 of het maximum dat je kan betalen
-- - Gouden polygoon: ofwel een bonus, ofwel 30 seconden FRENZY (×7 per klik)
-- - Max 12 kliks per seconde (vasthouden of autoclickers helpen niet)
-- - Salaris: 1 🪙 per 10 minuten + 1 per 15 upgrades (max 50 per dag, zoals voorheen)

alter table public.clicker add column if not exists frenzy_until timestamptz;

create or replace function public._clicker_items()
returns table (item_key text, icon text, name text, descr text, base_cost numeric, per_click numeric, per_sec numeric)
language sql immutable as $$
  values
    ('muis',     '🖱️', 'Gamingmuis',       '+1 Poly per klik',            50,         1,  0),
    ('stagiair', '🧑‍💼', 'Stagiair',         '+1 Poly per seconde',         300,        0,  1),
    ('koffie',   '☕', 'Koffiemachine',     '+8 Poly per seconde',         3500,       0,  8),
    ('printer',  '🖨️', 'Turboprinter',      '+47 Poly per seconde',        40000,      0,  47),
    ('meeting',  '📊', 'Vergadermachine',   '+260 Poly per seconde',       450000,     0,  260),
    ('ceo',      '🤵', 'CEO',               '+1.400 Poly per seconde',     5000000,    0,  1400),
    ('robot',    '🤖', 'Robotleger',        '+8.000 Poly per seconde',     60000000,   0,  8000),
    ('portaal',  '🌀', 'Dimensieportaal',   '+50.000 Poly per seconde',    800000000,  0,  50000)
$$;

create or replace function public._clicker_cost(p_base numeric, p_level int, p_count int) returns numeric
language sql immutable as $$
  -- som van p_count opeenvolgende prijzen (meetkundige reeks, factor 1,2)
  select round(p_base * power(1.2, p_level) * (power(1.2, p_count) - 1) / 0.2);
$$;

create or replace function public._clicker_view(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c public.clicker; r jsonb; ticks int; per_tick int; today_paid int; ready int;
begin
  select * into c from public.clicker where user_id = p_user;
  r := public._clicker_rates(c.upgrades);
  ticks := least(36, floor(extract(epoch from now() - c.last_salary) / 600)::int);
  per_tick := 1 + floor((r->>'levels')::int / 15)::int;
  today_paid := case when c.salary_day = public._today() then c.salary_today else 0 end;
  ready := least(ticks * per_tick, greatest(0, 50 - today_paid));
  return jsonb_build_object(
    'poly', floor(c.poly), 'total', floor(c.total), 'clicks', c.clicks,
    'per_click', (r->>'click')::numeric, 'per_sec', (r->>'sec')::numeric, 'levels', (r->>'levels')::int,
    'frenzy_left', greatest(0, floor(extract(epoch from coalesce(c.frenzy_until, now()) - now())))::int,
    'items', (select jsonb_agg(jsonb_build_object('key', i.item_key, 'icon', i.icon, 'name', i.name, 'desc', i.descr,
                'level', coalesce((c.upgrades->>i.item_key)::int, 0),
                'cost', public._clicker_cost(i.base_cost, coalesce((c.upgrades->>i.item_key)::int, 0), 1),
                'cost10', public._clicker_cost(i.base_cost, coalesce((c.upgrades->>i.item_key)::int, 0), 10))) from public._clicker_items() i),
    'salary', jsonb_build_object('ready', ready, 'per_tick', per_tick, 'today', today_paid, 'cap', 50,
                'next_in', 600 - floor(extract(epoch from now() - c.last_salary))::int % 600,
                'full', ticks >= 36),
    'golden_in', greatest(0, 120 - floor(extract(epoch from now() - c.last_golden))::int));
end $$;

-- Kliks verwerken: max 12 per seconde; tijdens FRENZY ×7 per klik
create or replace function public._clicker_apply(p_user uuid, p_clicks int) returns void
language plpgsql volatile security definer set search_path = public as $$
declare c public.clicker; r jsonb; secs numeric; n int; gain numeric; mult int := 1;
begin
  c := public._clicker_row(p_user);
  r := public._clicker_rates(c.upgrades);
  secs := least(28800, greatest(0, extract(epoch from now() - c.last_sync)));
  n := greatest(0, least(coalesce(p_clicks, 0), ceil(secs * 12)::int + 12));
  if c.frenzy_until is not null and c.frenzy_until > c.last_sync then mult := 7; end if;
  gain := n * (r->>'click')::numeric * mult + secs * (r->>'sec')::numeric;
  update public.clicker set poly = poly + gain, total = total + gain, clicks = clicks + n, last_sync = now()
    where user_id = p_user;
end $$;

-- Kopen: p_count = 1, 10 of -1 (zoveel als je kan betalen, max 100)
drop function if exists public.clicker_buy(text, int);
create or replace function public.clicker_buy(p_key text, p_clicks int default 0, p_count int default 1) returns jsonb
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
  if c.poly < cost then raise exception 'Niet genoeg Poly''s (% nodig).', cost; end if;
  update public.clicker set poly = poly - cost, upgrades = upgrades || jsonb_build_object(p_key, lvl + n) where user_id = me;
  return public._clicker_view(me) || jsonb_build_object('bought', n);
end $$;

-- Gouden polygoon: 50% kans op een bonus (90 s productie), 50% op 30 s FRENZY
create or replace function public.clicker_golden(p_clicks int default 0) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); c public.clicker; r jsonb; bonus numeric := 0; kind text;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  perform public._clicker_apply(me, p_clicks);
  select * into c from public.clicker where user_id = me for update;
  if now() - c.last_golden < interval '2 minutes' then raise exception 'De gouden polygoon is er nog niet.'; end if;
  r := public._clicker_rates(c.upgrades);
  if random() < .5 then
    kind := 'bonus';
    bonus := greatest((r->>'sec')::numeric * 90, (r->>'click')::numeric * 50);
    update public.clicker set poly = poly + bonus, total = total + bonus, last_golden = now() where user_id = me;
  else
    kind := 'frenzy';
    update public.clicker set frenzy_until = now() + interval '30 seconds', last_golden = now() where user_id = me;
  end if;
  return public._clicker_view(me) || jsonb_build_object('kind', kind, 'bonus', floor(bonus));
end $$;

do $$
declare f text;
begin
  foreach f in array array['public.clicker_buy(text, int, int)', 'public.clicker_golden(int)', 'public.clicker_sync(int)', 'public.clicker_collect(int)'] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
  execute 'revoke all on function public._clicker_view(uuid) from public, anon, authenticated';
  execute 'revoke all on function public._clicker_apply(uuid, int) from public, anon, authenticated';
end $$;
