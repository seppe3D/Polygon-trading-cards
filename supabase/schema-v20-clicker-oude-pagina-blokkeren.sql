-- v20: Clicker beveiligen tegen oude, niet-vernieuwde pagina's
-- 1) De echte clicker-functies krijgen een nieuwe naam (clicker2_...). De nieuwe site gebruikt die.
-- 2) De oude namen (clicker_...) geven enkel nog de melding "vernieuw de pagina".
--    Wie de oude pagina open laat staan, kan dus niets meer verdienen tot hij of zij vernieuwt.
-- 3) Kliks tellen nog maar mee over de laatste 30 seconden (max 12 per seconde).
--    Vroeger kon je kliks "opsparen" over uren en ze in één keer doorsturen.
-- Veilig om meerdere keren uit te voeren. Uitvoeren met "Run without RLS".
-- Let op: voer schema-v14 of schema-v16 hierna NIET opnieuw uit (dan komen de oude namen terug).

do $$
declare pair text[];
begin
  foreach pair slice 1 in array array[
    ['clicker_sync(integer)', 'clicker2_sync'],
    ['clicker_buy(text, integer, integer)', 'clicker2_buy'],
    ['clicker_collect(integer)', 'clicker2_collect'],
    ['clicker_golden(integer)', 'clicker2_golden']] loop
    -- Enkel hernoemen als de nieuwe naam nog niet bestaat (zo kan je dit script opnieuw uitvoeren)
    if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.proname = pair[2]) then
      execute format('alter function public.%s rename to %I', pair[1], pair[2]);
    end if;
  end loop;
end $$;

-- Oude namen: blokkeren met een duidelijke melding
create or replace function public.clicker_sync(p_clicks int default 0) returns jsonb
language plpgsql security definer set search_path = public as $$
begin raise exception 'Er is een nieuwe versie van de site. Vernieuw de pagina (🔄 of F5) om verder te spelen.'; end $$;
create or replace function public.clicker_buy(p_key text, p_clicks int default 0, p_count int default 1) returns jsonb
language plpgsql security definer set search_path = public as $$
begin raise exception 'Er is een nieuwe versie van de site. Vernieuw de pagina (🔄 of F5) om verder te spelen.'; end $$;
create or replace function public.clicker_collect(p_clicks int default 0) returns jsonb
language plpgsql security definer set search_path = public as $$
begin raise exception 'Er is een nieuwe versie van de site. Vernieuw de pagina (🔄 of F5) om verder te spelen.'; end $$;
create or replace function public.clicker_golden(p_clicks int default 0) returns jsonb
language plpgsql security definer set search_path = public as $$
begin raise exception 'Er is een nieuwe versie van de site. Vernieuw de pagina (🔄 of F5) om verder te spelen.'; end $$;

-- Kliks: max 12 per seconde, en enkel over de laatste 30 seconden (geen opgespaarde kliks meer)
create or replace function public._clicker_apply(p_user uuid, p_clicks int) returns void
language plpgsql volatile security definer set search_path = public as $$
declare c public.clicker; r jsonb; secs numeric; n int; gain numeric; mult int := 1;
begin
  c := public._clicker_row(p_user);
  r := public._clicker_rates(c.upgrades);
  secs := least(28800, greatest(0, extract(epoch from now() - c.last_sync)));
  n := greatest(0, least(coalesce(p_clicks, 0), ceil(least(secs, 30) * 12)::int + 12));
  if c.frenzy_until is not null and c.frenzy_until > c.last_sync then mult := 7; end if;
  gain := n * (r->>'click')::numeric * mult + secs * (r->>'sec')::numeric;
  update public.clicker set poly = poly + gain, total = total + gain, clicks = clicks + n, last_sync = now()
    where user_id = p_user;
end $$;

do $$
declare f text;
begin
  foreach f in array array['public.clicker_sync(int)', 'public.clicker_buy(text, int, int)', 'public.clicker_collect(int)', 'public.clicker_golden(int)',
                           'public.clicker2_sync(int)', 'public.clicker2_buy(text, int, int)', 'public.clicker2_collect(int)', 'public.clicker2_golden(int)'] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
  execute 'revoke all on function public._clicker_apply(uuid, int) from public, anon, authenticated';
end $$;

-- Wie heeft het meest? (enkel om te bekijken)
-- select p.display_name, floor(c.total) as ooit_verdiend, c.clicks, c.salary_today
--   from public.clicker c join public.profiles p on p.id = c.user_id order by c.total desc;
