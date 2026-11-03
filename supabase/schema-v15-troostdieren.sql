-- Polygon Trading Cards — uitbreiding v15: troostkatten heten voortaan troostdieren
-- Voer dit volledige bestand in één keer uit in Supabase SQL Editor (ná v14).
-- Kies bij de waarschuwing "Run without RLS". Veilig om opnieuw uit te voeren.

-- 1. De pagina "Katten" wordt "Troostdieren" (nieuwe dieren komen ook op deze pagina)
update public.cards set person = 'Troostdieren' where rarity = 'cat' and person <> 'Troostdieren';

-- Wie de kattenpagina al vol had, houdt zijn medaille (geen tweede beloning)
update public.collection_rewards c set person = 'Troostdieren'
where c.person = 'Katten'
  and not exists (select 1 from public.collection_rewards x where x.user_id = c.user_id and x.person = 'Troostdieren');
delete from public.collection_rewards where person = 'Katten';

-- 2. Troostdierenpack: 3 troostdieren voor 50 polycoins (was 20)
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
    v_wallet := public._shop_spend(me, 50, 'pack_cat');
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

-- Controle
select person, count(*) from public.cards where rarity = 'cat' group by person;
