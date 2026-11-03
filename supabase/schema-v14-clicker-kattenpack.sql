-- Polygon Trading Cards — uitbreiding v14: Clicker-pagina en Kattenpack
-- Voer dit volledige bestand in één keer uit in Supabase SQL Editor (ná v13).
-- Kies bij de waarschuwing "Run without RLS": het script zet RLS zelf aan. Veilig om opnieuw uit te voeren.
--
-- Clicker: klik Poly's bij elkaar, koop upgrades die automatisch Poly's maken.
-- Elke 10 minuten verdient je kantoor polycoins (salaris): 1 🪙 + 1 per 10 gekochte upgrades,
-- max 6 uur opsparen en max 50 🪙 per dag. Alles wordt op de server berekend (geen valsspelen).

-- =====================================================================
-- 1. Kattenpack: 3 troostkatten voor 20 polycoins
-- =====================================================================
create or replace function public.shop_buy_pack(p_kind text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); v_wallet int; v_cards jsonb := '[]'::jsonb;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if p_kind = 'basic' then
    v_wallet := public._shop_spend(me, 60, 'pack_basic');
    v_cards := v_cards || public._shop_give(me, public._shop_roll(3, 22));
  elsif p_kind = 'epic' then
    v_wallet := public._shop_spend(me, 200, 'pack_epic');
    v_cards := v_cards || public._shop_give(me, public._shop_roll(3, 22));
    v_cards := v_cards || public._shop_give(me, public._shop_roll(3, 22));
    v_cards := v_cards || public._shop_give(me, public._shop_roll(15, 85));
  elsif p_kind = 'cat' then
    v_wallet := public._shop_spend(me, 20, 'pack_cat');
    v_cards := v_cards || public._shop_give(me, 'cat');
    v_cards := v_cards || public._shop_give(me, 'cat');
    v_cards := v_cards || public._shop_give(me, 'cat');
  else
    raise exception 'Onbekend pakje.';
  end if;
  update public.shop_log set detail = jsonb_build_object('cards', (select jsonb_agg(c->'id') from jsonb_array_elements(v_cards) c))
    where id = (select max(id) from public.shop_log where user_id = me);
  return jsonb_build_object('cards', v_cards, 'wallet', v_wallet);
end $$;
grant execute on function public.shop_buy_pack(text) to authenticated;

-- =====================================================================
-- 2. Clicker
-- =====================================================================
create table if not exists public.clicker (
  user_id uuid primary key references auth.users(id) on delete cascade,
  poly numeric not null default 0,            -- huidige Poly's
  total numeric not null default 0,           -- ooit verdiend
  clicks bigint not null default 0,
  upgrades jsonb not null default '{}'::jsonb, -- {"muis": 3, ...}
  last_sync timestamptz not null default now(),
  last_salary timestamptz not null default now(),
  last_golden timestamptz not null default now() - interval '1 hour',
  salary_day date,
  salary_today int not null default 0
);
alter table public.clicker enable row level security;
-- Bewust geen policies: lezen en schrijven enkel via de functies hieronder

-- Upgrades: basisprijs stijgt met 15% per gekocht exemplaar
create or replace function public._clicker_items()
returns table (item_key text, icon text, name text, descr text, base_cost numeric, per_click numeric, per_sec numeric)
language sql immutable as $$
  values
    ('muis',     '🖱️', 'Gamingmuis',      '+1 Poly per klik',          15,      1,  0),
    ('stagiair', '🧑‍💼', 'Stagiair',        '+1 Poly per seconde',       100,     0,  1),
    ('koffie',   '☕', 'Koffiemachine',    '+8 Poly per seconde',       1100,    0,  8),
    ('printer',  '🖨️', 'Turboprinter',     '+47 Poly per seconde',      12000,   0,  47),
    ('meeting',  '📊', 'Vergadermachine',  '+260 Poly per seconde',     130000,  0,  260),
    ('ceo',      '🤵', 'CEO',              '+1400 Poly per seconde',    1400000, 0,  1400)
$$;

create or replace function public._clicker_rates(p_up jsonb) returns jsonb
language sql immutable as $$
  select jsonb_build_object(
    'click', 1 + coalesce(sum(coalesce((p_up->>i.item_key)::int, 0) * i.per_click), 0),
    'sec', coalesce(sum(coalesce((p_up->>i.item_key)::int, 0) * i.per_sec), 0),
    'levels', coalesce(sum(coalesce((p_up->>i.item_key)::int, 0)), 0))
  from public._clicker_items() i;
$$;

create or replace function public._clicker_row(p_user uuid) returns public.clicker
language plpgsql volatile security definer set search_path = public as $$
declare c public.clicker;
begin
  insert into public.clicker (user_id) values (p_user) on conflict do nothing;
  select * into c from public.clicker where user_id = p_user for update;
  return c;
end $$;

-- Toestand voor de site
create or replace function public._clicker_view(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c public.clicker; r jsonb; ticks int; per_tick int; today_paid int; ready int;
begin
  select * into c from public.clicker where user_id = p_user;
  r := public._clicker_rates(c.upgrades);
  ticks := least(36, floor(extract(epoch from now() - c.last_salary) / 600)::int);
  per_tick := 1 + floor((r->>'levels')::int / 10)::int;
  today_paid := case when c.salary_day = public._today() then c.salary_today else 0 end;
  ready := least(ticks * per_tick, greatest(0, 50 - today_paid));
  return jsonb_build_object(
    'poly', floor(c.poly), 'total', floor(c.total), 'clicks', c.clicks,
    'per_click', (r->>'click')::numeric, 'per_sec', (r->>'sec')::numeric,
    'items', (select jsonb_agg(jsonb_build_object('key', i.item_key, 'icon', i.icon, 'name', i.name, 'desc', i.descr,
                'level', coalesce((c.upgrades->>i.item_key)::int, 0),
                'cost', round(i.base_cost * power(1.15, coalesce((c.upgrades->>i.item_key)::int, 0))))) from public._clicker_items() i),
    'salary', jsonb_build_object('ready', ready, 'per_tick', per_tick, 'today', today_paid, 'cap', 50,
                'next_in', 600 - floor(extract(epoch from now() - c.last_salary))::int % 600,
                'full', ticks >= 36),
    'golden_in', greatest(0, 120 - floor(extract(epoch from now() - c.last_golden))::int));
end $$;

-- Kliks doorgeven en automatische Poly's bijtellen (max 20 kliks per seconde, max 8 uur offline)
create or replace function public._clicker_apply(p_user uuid, p_clicks int) returns void
language plpgsql volatile security definer set search_path = public as $$
declare c public.clicker; r jsonb; secs numeric; n int; gain numeric;
begin
  c := public._clicker_row(p_user);
  r := public._clicker_rates(c.upgrades);
  secs := least(28800, greatest(0, extract(epoch from now() - c.last_sync)));
  n := greatest(0, least(coalesce(p_clicks, 0), ceil(secs * 20)::int + 20));
  gain := n * (r->>'click')::numeric + secs * (r->>'sec')::numeric;
  update public.clicker set poly = poly + gain, total = total + gain, clicks = clicks + n, last_sync = now()
    where user_id = p_user;
end $$;

create or replace function public.clicker_sync(p_clicks int default 0) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Niet ingelogd.'; end if;
  perform public._clicker_apply(auth.uid(), p_clicks);
  return public._clicker_view(auth.uid());
end $$;

create or replace function public.clicker_buy(p_key text, p_clicks int default 0) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); c public.clicker; it record; lvl int; cost numeric;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  perform public._clicker_apply(me, p_clicks);
  select * into it from public._clicker_items() where item_key = p_key;
  if not found then raise exception 'Onbekende upgrade.'; end if;
  select * into c from public.clicker where user_id = me for update;
  lvl := coalesce((c.upgrades->>p_key)::int, 0);
  cost := round(it.base_cost * power(1.15, lvl));
  if c.poly < cost then raise exception 'Niet genoeg Poly''s (% nodig).', cost; end if;
  update public.clicker set poly = poly - cost, upgrades = upgrades || jsonb_build_object(p_key, lvl + 1) where user_id = me;
  return public._clicker_view(me);
end $$;

-- Salaris ophalen: echte polycoins
create or replace function public.clicker_collect(p_clicks int default 0) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); c public.clicker; v jsonb; paid int; ticks int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  perform public._clicker_apply(me, p_clicks);
  v := public._clicker_view(me);
  paid := (v->'salary'->>'ready')::int;
  if paid <= 0 then raise exception 'Er is nog geen salaris om op te halen.'; end if;
  select * into c from public.clicker where user_id = me for update;
  ticks := least(36, floor(extract(epoch from now() - c.last_salary) / 600)::int);
  update public.clicker set
    last_salary = case when ticks >= 36 or paid < ticks * (v->'salary'->>'per_tick')::int then now() else last_salary + ticks * interval '10 minutes' end,
    salary_today = (case when salary_day = public._today() then salary_today else 0 end) + paid,
    salary_day = public._today()
  where user_id = me;
  perform public._give_coins(me, paid, 'clicker', null);
  return public._clicker_view(me) || jsonb_build_object('paid', paid,
    'wallet', (select polycoins from public.user_wallet where user_id = me));
end $$;

-- Gouden polygoon: hoogstens om de 2 minuten, levert 60 seconden productie (min. 30 kliks)
create or replace function public.clicker_golden(p_clicks int default 0) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); c public.clicker; r jsonb; bonus numeric;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  perform public._clicker_apply(me, p_clicks);
  select * into c from public.clicker where user_id = me for update;
  if now() - c.last_golden < interval '2 minutes' then raise exception 'De gouden polygoon is er nog niet.'; end if;
  r := public._clicker_rates(c.upgrades);
  bonus := greatest((r->>'sec')::numeric * 60, (r->>'click')::numeric * 30);
  update public.clicker set poly = poly + bonus, total = total + bonus, last_golden = now() where user_id = me;
  return public._clicker_view(me) || jsonb_build_object('bonus', floor(bonus));
end $$;

-- Rechten
do $$
declare f text;
begin
  foreach f in array array['public.clicker_sync(int)', 'public.clicker_buy(text, int)', 'public.clicker_collect(int)', 'public.clicker_golden(int)'] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
  foreach f in array array['public._clicker_row(uuid)', 'public._clicker_view(uuid)', 'public._clicker_apply(uuid, int)'] loop
    execute 'revoke all on function ' || f || ' from public, anon, authenticated';
  end loop;
end $$;
