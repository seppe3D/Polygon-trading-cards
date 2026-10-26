-- Polygon Trading Cards — uitbreiding v13: de grote update
--   Battle: types, vaardigheden, statuseffecten, synergie en rankings met seizoenen
--   Extra: wekelijkse events, prestaties, profiel, casino, puzzels, stickers, bureau en huisdier
-- Voer dit volledige bestand in één keer uit in Supabase SQL Editor (ná v8 t/m v12).
-- Kies bij de waarschuwing "Run without RLS": het script zet RLS zelf aan. Veilig om opnieuw uit te voeren.

-- =====================================================================
-- 0. Wekelijks event (wisselt elke maandag, voor iedereen hetzelfde)
-- =====================================================================
create or replace function public._week_event(p_date date default null) returns text
language sql stable as $$
  select (array['double_battle', 'lucky_draw', 'puzzle_bonus', 'lucky_wheel', 'sticker_bonus'])
    [1 + (floor((coalesce(p_date, public._today()) - date '2026-01-05') / 7)::int % 5 + 5) % 5];
$$;

create or replace function public.week_event() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('key', e, 'ends', (date_trunc('week', public._today()::timestamp) + interval '7 days')::date,
    'title', case e when 'double_battle' then '⚔️ Dubbele battle-week'
                    when 'lucky_draw' then '🍀 Geluksweek'
                    when 'puzzle_bonus' then '🧩 Puzzelweek'
                    when 'lucky_wheel' then '🎡 Rad-week'
                    else '🏷️ Stickerweek' end,
    'desc', case e when 'double_battle' then 'Alle polycoins uit battles zijn deze week dubbel.'
                   when 'lucky_draw' then 'Je Wordle-pakje telt alsof je 1 poging minder nodig had: meer kans op epics en legendaries.'
                   when 'puzzle_bonus' then 'Puzzels leveren deze week dubbel zoveel polycoins op.'
                   when 'lucky_wheel' then 'Je mag het rad van fortuin deze week 2 keer per dag gratis draaien.'
                   else 'Je krijgt deze week dubbel zoveel stickers uit puzzels.' end)
  from (select public._week_event() e) x;
$$;

-- =====================================================================
-- 1. Types per collega: ☕ koffie > ⏰ deadline > 📊 meeting > ☕ koffie
-- =====================================================================
create table if not exists public.person_types (
  person text primary key,
  ptype text not null check (ptype in ('koffie', 'deadline', 'meeting'))
);
alter table public.person_types enable row level security;
drop policy if exists "types lezen" on public.person_types;
create policy "types lezen" on public.person_types for select to authenticated using (true);
grant select on public.person_types to authenticated;

-- Collega's zonder vaste keuze krijgen automatisch een type (altijd hetzelfde voor dezelfde naam).
-- Aanpassen kan met: insert into public.person_types values ('Naam', 'koffie') on conflict (person) do update set ptype = excluded.ptype;
create or replace function public._person_type(p_person text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select ptype from public.person_types where person = p_person),
                  (array['koffie', 'deadline', 'meeting'])[1 + abs(hashtext(coalesce(p_person, ''))) % 3]);
$$;

create or replace function public.card_types() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(person, case when all_cat then 'none' else public._person_type(person) end), '{}'::jsonb)
  from (select person, bool_and(rarity = 'cat') as all_cat from public.cards group by person) c;
$$;

-- Typevoordeel: 1,5× sterk, 0,75× zwak, anders 1
create or replace function public._tb_eff(p_att text, p_def text) returns float8
language sql immutable as $$
  select case
    when (p_att, p_def) in (('koffie', 'deadline'), ('deadline', 'meeting'), ('meeting', 'koffie')) then 1.5
    when (p_def, p_att) in (('koffie', 'deadline'), ('deadline', 'meeting'), ('meeting', 'koffie')) then 0.75
    else 1 end;
$$;

-- =====================================================================
-- 2. Eén kant van het speelveld: levels, synergie, type, vaardigheid, statussen
-- =====================================================================
create or replace function public._tb_side(p_cards int[], p_user uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with t as (
    select u.ord, c.id, c.rarity, c.hp, c.attack, c.defense, c.special_power, c.person,
      coalesce((select l.level from public.card_levels l where l.user_id = p_user and l.card_id = c.id), 1) as lvl,
      count(*) over (partition by c.person) as same
    from unnest(p_cards) with ordinality u(id, ord) join public.cards c on c.id = u.id
  ), m as (
    select t.*, (same >= 2 and rarity <> 'cat') as syn,
      (1 + 0.1 * (lvl - 1)) * (case when same >= 2 and rarity <> 'cat' then 1.1 else 1 end) as f
    from t
  )
  select jsonb_build_object(
    'cards',  jsonb_agg(id order by ord),
    'hp',     jsonb_agg(round(coalesce(hp, 50) * f)::int order by ord),
    'max',    jsonb_agg(round(coalesce(hp, 50) * f)::int order by ord),
    'atk',    jsonb_agg(round(coalesce(attack, 10) * f)::int order by ord),
    'def',    jsonb_agg(round(coalesce(defense, 0) * f)::int order by ord),
    'sp',     jsonb_agg(case when rarity = 'legendary' then coalesce(nullif(special_power, 0), round(coalesce(attack, 10) * 1.6)::int) else 0 end order by ord),
    'lvl',    jsonb_agg(lvl order by ord),
    'type',   jsonb_agg(case when rarity = 'cat' then 'none' else public._person_type(person) end order by ord),
    'ab',     jsonb_agg(case when rarity in ('epic', 'legendary') then rarity end order by ord),
    'syn',    jsonb_agg(syn order by ord),
    'burn',   jsonb_agg(0 order by ord),
    'stun',   jsonb_agg(0 order by ord),
    'shield', jsonb_agg(0 order by ord),
    'active', 0, 'energy', 1)
  from m;
$$;
revoke all on function public._tb_side(int[], uuid) from public, anon, authenticated;

-- Kleine hulpfunctie: geheel getal uit een array in de toestand (ontbreekt = 0, voor oude gevechten)
create or replace function public._tb_n(p_st jsonb, p_s text, p_k text, p_i int) returns int
language sql immutable as $$ select coalesce((p_st->p_s->p_k->>p_i)::int, 0) $$;

create or replace function public._tb_set(p_st jsonb, p_s text, p_k text, p_i int, p_v int) returns jsonb
language plpgsql immutable as $$
declare n int := jsonb_array_length(p_st->p_s->'hp');
begin
  if p_st->p_s->p_k is null then
    p_st := jsonb_set(p_st, array[p_s, p_k], (select jsonb_agg(0) from generate_series(1, n)));
  end if;
  return jsonb_set(p_st, array[p_s, p_k, p_i::text], to_jsonb(p_v));
end $$;

-- Wat kost de vaardigheid van een kaart? (null = geen vaardigheid)
create or replace function public._tb_ab_cost(p_st jsonb, p_s text, p_i int) returns int
language sql immutable as $$
  select case coalesce(p_st->p_s->'ab'->>p_i, case when public._tb_n(p_st, p_s, 'sp', p_i) > 0 then 'legendary' end)
    when 'epic' then 3 when 'legendary' then 4 end;
$$;

-- =====================================================================
-- 3. Zet van de computer
-- =====================================================================
drop function if exists public._tb_ai(jsonb, text, text);
create or replace function public._tb_ai(p_state jsonb, p_side text, p_diff text, p_round int) returns jsonb
language plpgsql volatile as $$
declare
  o_ text := case p_side when 'A' then 'B' else 'A' end;
  me jsonb := p_state -> p_side;
  op jsonb := p_state -> o_;
  a int := (me->>'active')::int;
  o int := (op->>'active')::int;
  en int := (me->>'energy')::int;
  cost int := public._tb_ab_cost(p_state, p_side, a);
  ty text := coalesce(me->'type'->>a, 'none');
  oty text := coalesce(op->'type'->>o, 'none');
  hp_pct float8 := (me->'hp'->>a)::float8 / greatest(1, (me->'max'->>a)::float8);
  stunned boolean := public._tb_n(p_state, p_side, 'stun', a) = p_round;
  best int; best_pct float8 := 0; i int; r float8 := random();
begin
  if stunned then return '{"a":"guard"}'; end if;
  if p_diff = 'easy' then
    if cost is not null and en >= cost and r < .5 then return '{"a":"special"}'; end if;
    if en >= 2 and r < .2 then return '{"a":"power"}'; end if;
    if r < .35 then return '{"a":"guard"}'; end if;
    return '{"a":"attack"}';
  end if;
  -- Vaardigheid: koffie (schild) enkel als het nodig is, de rest zo snel mogelijk
  if cost is not null and en >= cost then
    if not (me->'ab'->>a = 'epic' and ty = 'koffie') or hp_pct < .6 then return '{"a":"special"}'; end if;
  end if;
  for i in 0..jsonb_array_length(me->'hp') - 1 loop
    if i <> a and (me->'hp'->>i)::int > 0
       and (me->'hp'->>i)::float8 / (me->'max'->>i)::float8 > best_pct then
      best := i; best_pct := (me->'hp'->>i)::float8 / (me->'max'->>i)::float8;
    end if;
  end loop;
  -- Slecht type tegen de tegenstander of bijna uitgeschakeld: wisselen naar een betere kaart
  if best is not null and best_pct > .5 then
    if hp_pct < .3 and random() < (case p_diff when 'hard' then .6 else .35 end) then
      return jsonb_build_object('a', 'switch', 't', best);
    end if;
    if p_diff = 'hard' and public._tb_eff(ty, oty) < 1
       and public._tb_eff(coalesce(me->'type'->>best, 'none'), oty) > 1 and random() < .5 then
      return jsonb_build_object('a', 'switch', 't', best);
    end if;
  end if;
  if public._tb_ab_cost(p_state, o_, o) is not null and (op->>'energy')::int >= 4
     and random() < (case p_diff when 'hard' then .6 else .35 end) then
    return '{"a":"guard"}';
  end if;
  if en >= 2 and random() < .6 then return '{"a":"power"}'; end if;
  if p_diff = 'hard' and en < 2 and random() < .2 then return '{"a":"guard"}'; end if;
  return '{"a":"attack"}';
end $$;

-- =====================================================================
-- 4. Eén ronde afwikkelen
--   Vaardigheid (epic 3 ⚡, legendary 4 ⚡), afhankelijk van het type:
--     ☕ koffie   epic: 🛡️ schild (35% HP) + 15% genezen    legendary: zware klap + 🛡️ schild (30% HP)
--     ⏰ deadline epic: aanval + 🔥 brand (3 rondes)         legendary: zware klap + 🔥 brand
--     📊 meeting  epic: lichte aanval + 💫 verdoofd          legendary: zware klap + 💫 verdoofd
--   🔥 brand: 8% van de max HP per ronde · 💫 verdoofd: volgende ronde niet aanvallen
--   🛡️ schild: vangt schade op tot het op is · legendary-klap gaat door verdedigen heen
-- =====================================================================
create or replace function public._tb_resolve(p_id bigint) returns void
language plpgsql volatile security definer set search_path = public as $$
declare
  b public.tbattles;
  st jsonb; ev jsonb; r int;
  act jsonb;
  s text; d text; kind text; ab text; ty text; dty text;
  order_ text[]; dmg int; base float8; crit boolean; guarded boolean; eff float8; absorbed int; sh int; v int;
  ai int; di int; nxt int; i int; w text; mx int;
  v_ca int := 0; v_cb int := 0; reward int; mult int := 1;
begin
  select * into b from public.tbattles where id = p_id for update;
  st := b.state || '{"_act": {}}'::jsonb; ev := coalesce(st->'events', '[]'::jsonb); r := b.round + 1;
  for s in select unnest(array['A', 'B']) loop
    select jsonb_build_object('a', h.action, 't', h.target) into act from public.tbattle_hidden h where h.battle_id = p_id and h.side = s;
    st := jsonb_set(st, array['_act', s], coalesce(act, '{"a": "attack"}'::jsonb));
  end loop;

  for s in select unnest(array['A', 'B']) loop
    if st->'_act'->s->>'a' = 'forfeit' then
      w := case s when 'A' then 'B' else 'A' end;
      ev := ev || jsonb_build_object('r', r, 't', 'forfeit', 's', s);
    end if;
  end loop;

  if w is null then
    -- 1. Wissels en verdedigen
    for s in select unnest(array['A', 'B']) loop
      if st->'_act'->s->>'a' = 'switch' then
        st := jsonb_set(st, array[s, 'active'], to_jsonb((st->'_act'->s->>'t')::int));
        ev := ev || jsonb_build_object('r', r, 't', 'switch', 's', s, 'i', (st->'_act'->s->>'t')::int);
      elsif st->'_act'->s->>'a' = 'guard' then
        ev := ev || jsonb_build_object('r', r, 't', 'guard', 's', s);
      end if;
    end loop;
    -- 2. Energie betalen
    for s in select unnest(array['A', 'B']) loop
      ai := (st->s->>'active')::int;
      if st->'_act'->s->>'a' = 'power' then
        st := jsonb_set(st, array[s, 'energy'], to_jsonb((st->s->>'energy')::int - 2));
      elsif st->'_act'->s->>'a' = 'special' then
        st := jsonb_set(st, array[s, 'energy'], to_jsonb(greatest(0, (st->s->>'energy')::int - coalesce(public._tb_ab_cost(st, s, ai), 4))));
      end if;
    end loop;
    -- 3. Aanvallen: hoogste ATK eerst
    order_ := case
      when (st->'A'->'atk'->>((st->'A'->>'active')::int))::int + random() * .5 >=
           (st->'B'->'atk'->>((st->'B'->>'active')::int))::int + random() * .5
      then array['A', 'B'] else array['B', 'A'] end;
    foreach s in array order_ loop
      kind := st->'_act'->s->>'a';
      if kind not in ('attack', 'power', 'special') then continue; end if;
      d := case s when 'A' then 'B' else 'A' end;
      ai := (st->s->>'active')::int; di := (st->d->>'active')::int;
      if (st->s->'hp'->>ai)::int = 0 then continue; end if;
      if public._tb_n(st, s, 'stun', ai) = r then
        ev := ev || jsonb_build_object('r', r, 't', 'stunned', 's', s, 'i', ai);
        continue;
      end if;
      ab := case when kind = 'special' then coalesce(st->s->'ab'->>ai, 'legendary') end;
      ty := coalesce(st->s->'type'->>ai, 'none'); dty := coalesce(st->d->'type'->>di, 'none');
      mx := (st->s->'max'->>ai)::int;
      -- Koffie-epic: geen aanval, wel schild en genezing
      if ab = 'epic' and ty = 'koffie' then
        v := least(mx - (st->s->'hp'->>ai)::int, round(mx * .15)::int);
        st := jsonb_set(st, array[s, 'hp', ai::text], to_jsonb((st->s->'hp'->>ai)::int + v));
        sh := greatest(public._tb_n(st, s, 'shield', ai), round(mx * .35)::int);
        st := public._tb_set(st, s, 'shield', ai, sh);
        ev := ev || jsonb_build_object('r', r, 't', 'ability', 's', s, 'i', ai, 'ty', ty, 'heal', v, 'shield', sh, 'hp', (st->s->'hp'->>ai)::int);
        continue;
      end if;
      eff := public._tb_eff(ty, dty);
      crit := false; guarded := false;
      if ab = 'legendary' then
        dmg := greatest(1, round(public._tb_n(st, s, 'sp', ai) * eff))::int;
      else
        base := greatest((st->s->'atk'->>ai)::int * .25,
                         (st->s->'atk'->>ai)::int * (.85 + random() * .3) - (st->d->'def'->>di)::int * .5);
        if kind = 'power' then base := base * 1.7; end if;
        if ab = 'epic' and ty = 'meeting' then base := base * .8; end if;
        base := base * eff;
        if random() < .1 then base := base * 1.5; crit := true; end if;
        if st->'_act'->d->>'a' = 'guard' then base := base * .5; guarded := true; end if;
        dmg := greatest(1, round(base))::int;
      end if;
      -- Schild vangt eerst op
      sh := public._tb_n(st, d, 'shield', di);
      absorbed := least(sh, dmg);
      if absorbed > 0 then st := public._tb_set(st, d, 'shield', di, sh - absorbed); end if;
      st := jsonb_set(st, array[d, 'hp', di::text], to_jsonb(greatest(0, (st->d->'hp'->>di)::int - (dmg - absorbed))));
      ev := ev || jsonb_build_object('r', r, 't', 'atk', 's', s, 'k', kind, 'd', dmg, 'crit', crit, 'guarded', guarded,
                                     'ai', ai, 'di', di, 'hp', (st->d->'hp'->>di)::int,
                                     'eff', case when eff > 1 then 1 when eff < 1 then -1 else 0 end, 'abs', absorbed);
      -- Effect van de vaardigheid
      if ab is not null then
        if ty = 'koffie' then
          sh := greatest(public._tb_n(st, s, 'shield', ai), round(mx * .3)::int);
          st := public._tb_set(st, s, 'shield', ai, sh);
          ev := ev || jsonb_build_object('r', r, 't', 'shield', 's', s, 'i', ai, 'v', sh);
        elsif ty = 'deadline' and (st->d->'hp'->>di)::int > 0 then
          st := public._tb_set(st, d, 'burn', di, 3);
          ev := ev || jsonb_build_object('r', r, 't', 'burn', 's', d, 'i', di);
        elsif ty = 'meeting' and (st->d->'hp'->>di)::int > 0 then
          st := public._tb_set(st, d, 'stun', di, r + 1);
          ev := ev || jsonb_build_object('r', r, 't', 'stun', 's', d, 'i', di);
        end if;
      end if;
      if (st->d->'hp'->>di)::int = 0 then
        ev := ev || jsonb_build_object('r', r, 't', 'ko', 's', d, 'i', di);
      end if;
    end loop;
    -- 4. Brandwonden
    for s in select unnest(array['A', 'B']) loop
      for i in 0..jsonb_array_length(st->s->'hp') - 1 loop
        if public._tb_n(st, s, 'burn', i) > 0 and (st->s->'hp'->>i)::int > 0 then
          dmg := greatest(3, round((st->s->'max'->>i)::int * .08))::int;
          st := jsonb_set(st, array[s, 'hp', i::text], to_jsonb(greatest(0, (st->s->'hp'->>i)::int - dmg)));
          st := public._tb_set(st, s, 'burn', i, public._tb_n(st, s, 'burn', i) - 1);
          ev := ev || jsonb_build_object('r', r, 't', 'burnt', 's', s, 'i', i, 'd', dmg, 'hp', (st->s->'hp'->>i)::int);
          if (st->s->'hp'->>i)::int = 0 then
            ev := ev || jsonb_build_object('r', r, 't', 'ko', 's', s, 'i', i);
          end if;
        end if;
      end loop;
    end loop;
    -- 5. Energie bijtanken
    for s in select unnest(array['A', 'B']) loop
      st := jsonb_set(st, array[s, 'energy'], to_jsonb(least(5,
        (st->s->>'energy')::int + case st->'_act'->s->>'a' when 'guard' then 2 when 'attack' then 1 when 'switch' then 1 else 0 end)));
    end loop;
    -- 6. Uitgeschakelde kaarten vervangen, of einde
    for s in select unnest(array['A', 'B']) loop
      ai := (st->s->>'active')::int;
      if (st->s->'hp'->>ai)::int = 0 then
        nxt := null;
        for i in 0..jsonb_array_length(st->s->'hp') - 1 loop
          if (st->s->'hp'->>i)::int > 0 then nxt := i; exit; end if;
        end loop;
        if nxt is null then
          w := coalesce(w, case s when 'A' then 'B' else 'A' end);
        else
          st := jsonb_set(st, array[s, 'active'], to_jsonb(nxt));
          ev := ev || jsonb_build_object('r', r, 't', 'enter', 's', s, 'i', nxt);
        end if;
      end if;
    end loop;
    if w is null and r >= 60 then
      w := case when (select sum((h.v)::float8 / m.v::float8) from jsonb_array_elements_text(st->'A'->'hp') with ordinality h(v, n)
                        join jsonb_array_elements_text(st->'A'->'max') with ordinality m(v, n) using (n))
                  >= (select sum((h.v)::float8 / m.v::float8) from jsonb_array_elements_text(st->'B'->'hp') with ordinality h(v, n)
                        join jsonb_array_elements_text(st->'B'->'max') with ordinality m(v, n) using (n))
               then 'A' else 'B' end;
    end if;
  end if;

  st := st - '_act';
  st := jsonb_set(st, '{moved}', '{"A": false, "B": false}');
  update public.tbattle_hidden set action = null, target = null where battle_id = p_id;

  if w is not null then
    ev := ev || jsonb_build_object('r', r, 't', 'end', 'w', w);
    if public._week_event() = 'double_battle' then mult := 2; end if;
    if b.mode = 'pve' then
      if w = 'A' and public._tb_rewarded_today(b.player_a, 'pve') < 5 then
        v_ca := case b.difficulty when 'easy' then 5 when 'hard' then 20 else 10 end;
      end if;
    else
      reward := 25;
      if w = 'A' then
        if public._tb_rewarded_today(b.player_a, 'pvp') < 3 then v_ca := reward; end if;
        if public._tb_rewarded_today(b.player_b, 'pvp') < 3 and not exists (select 1 from jsonb_array_elements(ev) e where e->>'t' = 'forfeit') then v_cb := 5; end if;
      else
        if public._tb_rewarded_today(b.player_b, 'pvp') < 3 then v_cb := reward; end if;
        if public._tb_rewarded_today(b.player_a, 'pvp') < 3 and not exists (select 1 from jsonb_array_elements(ev) e where e->>'t' = 'forfeit') then v_ca := 5; end if;
      end if;
      if exists (select 1 from jsonb_array_elements(ev) e where e->>'t' = 'forfeit') and r < 3 then v_ca := 0; v_cb := 0; end if;
    end if;
    v_ca := v_ca * mult; v_cb := v_cb * mult;
    if v_ca > 0 then perform public._tb_pay(b.player_a, v_ca); end if;
    if v_cb > 0 and b.player_b is not null then perform public._tb_pay(b.player_b, v_cb); end if;
    st := jsonb_set(st, '{events}', ev);
    update public.tbattles set state = st, round = r, status = 'done', winner = w,
      forfeit = exists (select 1 from jsonb_array_elements(ev) e where e->>'t' = 'forfeit'),
      coins_a = v_ca, coins_b = v_cb, updated_at = now(), finished_at = now()
    where id = p_id;
  else
    st := jsonb_set(st, '{events}', ev);
    update public.tbattles set state = st, round = r, updated_at = now() where id = p_id;
  end if;
end $$;
revoke all on function public._tb_resolve(bigint) from public, anon, authenticated;

-- =====================================================================
-- 5. Een zet doen (vaardigheid en verdoofd)
-- =====================================================================
create or replace function public.tb_act(p_id bigint, p_action text, p_target int default null) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  b public.tbattles; s text; o text; v_side jsonb; a int; ai jsonb; cost int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select * into b from public.tbattles where id = p_id for update;
  if not found then raise exception 'Battle niet gevonden.'; end if;
  if b.status <> 'active' then raise exception 'Deze battle is niet (meer) bezig.'; end if;
  s := case when me = b.player_a then 'A' when me = b.player_b then 'B' end;
  if s is null then raise exception 'Dit is niet jouw battle.'; end if;
  o := case s when 'A' then 'B' else 'A' end;
  if p_action <> 'forfeit' and (b.state->'moved'->>s)::boolean then
    raise exception 'Je hebt deze ronde al gekozen. Wacht op je tegenstander.';
  end if;
  if p_action not in ('attack', 'power', 'guard', 'special', 'switch', 'forfeit') then raise exception 'Onbekende zet.'; end if;

  v_side := b.state->s; a := (v_side->>'active')::int;
  if p_action in ('attack', 'power', 'special') and public._tb_n(b.state, s, 'stun', a) = b.round + 1 then
    raise exception 'Je kaart is verdoofd en kan deze ronde niet aanvallen. Verdedig of wissel.';
  end if;
  if p_action = 'power' and (v_side->>'energy')::int < 2 then raise exception 'Niet genoeg energie (2 nodig).'; end if;
  if p_action = 'special' then
    cost := public._tb_ab_cost(b.state, s, a);
    if cost is null then raise exception 'Deze kaart heeft geen vaardigheid.'; end if;
    if (v_side->>'energy')::int < cost then raise exception 'Niet genoeg energie (% nodig).', cost; end if;
  end if;
  if p_action = 'switch' then
    if p_target is null or p_target < 0 or p_target >= jsonb_array_length(v_side->'hp') or p_target = a
       or (v_side->'hp'->>p_target)::int <= 0 then
      raise exception 'Kies een andere kaart die nog kan vechten.';
    end if;
  end if;

  update public.tbattle_hidden h set action = p_action, target = case when p_action = 'switch' then p_target end
    where h.battle_id = p_id and h.side = s;
  update public.tbattles set state = jsonb_set(state, array['moved', s], 'true'), updated_at = now() where id = p_id;

  if b.mode = 'pve' then
    ai := public._tb_ai(b.state, o, b.difficulty, b.round + 1);
    update public.tbattle_hidden h set action = ai->>'a', target = (ai->>'t')::int where h.battle_id = p_id and h.side = o;
    perform public._tb_resolve(p_id);
  elsif p_action = 'forfeit' or (b.state->'moved'->>o)::boolean then
    perform public._tb_resolve(p_id);
  end if;

  select * into b from public.tbattles where id = p_id;
  return to_jsonb(b);
end $$;

-- =====================================================================
-- 6. Rankings: punten tegen vrienden per seizoen (= kalendermaand)
--    Iedereen start op 1000. 🥉 Brons < 1100 ≤ 🥈 Zilver < 1200 ≤ 🥇 Goud < 1350 ≤ 💠 Platina < 1500 ≤ 💎 Diamant
-- =====================================================================
create table if not exists public.tb_ratings (
  user_id uuid not null references auth.users(id) on delete cascade,
  season text not null,                -- bv. '2026-11'
  points int not null default 1000,
  best int not null default 1000,
  wins int not null default 0,
  losses int not null default 0,
  primary key (user_id, season)
);
alter table public.tb_ratings enable row level security;
drop policy if exists "rankings lezen" on public.tb_ratings;
create policy "rankings lezen" on public.tb_ratings for select to authenticated using (true);
grant select on public.tb_ratings to authenticated;
revoke insert, update, delete on public.tb_ratings from anon, authenticated;

create or replace function public._season(p_ts timestamptz default now()) returns text
language sql stable as $$ select to_char(p_ts at time zone 'Europe/Brussels', 'YYYY-MM') $$;

create or replace function public._rank(p_points int) returns text
language sql immutable as $$
  select case when p_points >= 1500 then 'diamant' when p_points >= 1350 then 'platina'
              when p_points >= 1200 then 'goud' when p_points >= 1100 then 'zilver' else 'brons' end;
$$;

-- Na een afgelopen gevecht tegen een vriend: punten volgens Elo (K = 32).
-- Opgeven vóór ronde 3 telt niet mee.
create or replace function public._trg_tb_rating() returns trigger
language plpgsql security definer set search_path = public as $$
declare w uuid; l uuid; se text; pw int; pl int; ex float8; delta int;
begin
  if new.mode <> 'pvp' or new.status <> 'done' or old.status = 'done' or new.winner is null then return null; end if;
  if new.forfeit and new.round < 3 then return null; end if;
  w := case new.winner when 'A' then new.player_a else new.player_b end;
  l := case new.winner when 'A' then new.player_b else new.player_a end;
  se := public._season(coalesce(new.finished_at, now()));
  insert into public.tb_ratings (user_id, season) values (w, se), (l, se) on conflict do nothing;
  select points into pw from public.tb_ratings where user_id = w and season = se;
  select points into pl from public.tb_ratings where user_id = l and season = se;
  ex := 1 / (1 + power(10, (pl - pw) / 400.0));
  delta := greatest(5, round(32 * (1 - ex)))::int;
  update public.tb_ratings set points = points + delta, best = greatest(best, points + delta), wins = wins + 1
    where user_id = w and season = se;
  update public.tb_ratings set points = greatest(0, points - delta), losses = losses + 1
    where user_id = l and season = se;
  return null;
end $$;
drop trigger if exists tb_rating on public.tbattles;
create trigger tb_rating after update on public.tbattles for each row execute function public._trg_tb_rating();

-- Ranglijst: jij en je vrienden, met punten van dit seizoen
drop function if exists public.tb_leaderboard();
create or replace function public.tb_leaderboard()
returns table (user_id uuid, display_name text, avatar_url text, wins bigint, losses bigint,
               points int, rank text, season_wins int, season_losses int)
language sql stable security definer set search_path = public as $$
  with people as (
    select auth.uid() as id
    union select f.friend_id from public.friendships f where f.user_id = auth.uid()
  ), results as (
    select case winner when 'A' then player_a else player_b end as winner, player_a as p1, player_b as p2
    from public.tbattles where mode = 'pvp' and status = 'done'
  )
  select p.id, pr.display_name, pr.avatar_url,
    (select count(*) from results r where r.winner = p.id),
    (select count(*) from results r where (r.p1 = p.id or r.p2 = p.id) and r.winner <> p.id),
    coalesce(t.points, 1000), public._rank(coalesce(t.points, 1000)), coalesce(t.wins, 0), coalesce(t.losses, 0)
  from people p join public.profiles pr on pr.id = p.id
  left join public.tb_ratings t on t.user_id = p.id and t.season = public._season()
  where auth.uid() is not null
  order by 6 desc, 4 desc, 2;
$$;
grant execute on function public.tb_leaderboard() to authenticated;
grant execute on function public.week_event() to authenticated;
grant execute on function public.card_types() to authenticated;

-- =====================================================================
-- 7. Stickers: 6 thema's van 8 stickers (5 gewoon, 2 zeldzaam, 1 episch)
-- =====================================================================
create or replace function public._stickers()
returns table (sticker_key text, theme text, emoji text, name text, rarity text, anim text)
language sql immutable as $$
  values
    ('of_clip','kantoor','📎','Paperclip Pete','common','wobble'),
    ('of_mug','kantoor','☕','Koffiekop','common','float'),
    ('of_pin','kantoor','📌','Punaise','common','bounce'),
    ('of_folder','kantoor','🗂️','Mappenmonster','common','jelly'),
    ('of_keys','kantoor','⌨️','Tik-tak-toetsenbord','common','shake'),
    ('of_printer','kantoor','🖨️','Printer van Doom','rare','shake'),
    ('of_case','kantoor','💼','Baas-aktetas','rare','swing'),
    ('of_trophy','kantoor','🏆','Werknemer van de maand','epic','spin'),
    ('fd_pizza','eten','🍕','Pizzapunt','common','wobble'),
    ('fd_donut','eten','🍩','Donut','common','spin'),
    ('fd_taco','eten','🌮','Taco Tuesday','common','bounce'),
    ('fd_croissant','eten','🥐','Croissant','common','float'),
    ('fd_cupcake','eten','🧁','Cupcake','common','jelly'),
    ('fd_sushi','eten','🍣','Sushi','rare','swing'),
    ('fd_melon','eten','🍉','Watermeloen','rare','wobble'),
    ('fd_burger','eten','🍔','Mega-burger','epic','bounce'),
    ('an_cat','dieren','🐱','Kantoorkat','common','wobble'),
    ('an_dog','dieren','🐶','Hond','common','bounce'),
    ('an_frog','dieren','🐸','Kikker','common','jelly'),
    ('an_fox','dieren','🦊','Vos','common','swing'),
    ('an_panda','dieren','🐼','Panda','common','float'),
    ('an_owl','dieren','🦉','Uil','rare','wobble'),
    ('an_octo','dieren','🐙','Octopus','rare','jelly'),
    ('an_unicorn','dieren','🦄','Eenhoorn','epic','float'),
    ('sp_rocket','ruimte','🚀','Raket','common','float'),
    ('sp_moon','ruimte','🌙','Maan','common','swing'),
    ('sp_star','ruimte','⭐','Ster','common','spin'),
    ('sp_planet','ruimte','🪐','Planeet','common','float'),
    ('sp_comet','ruimte','☄️','Komeet','common','shake'),
    ('sp_alien','ruimte','👽','Alien','rare','wobble'),
    ('sp_ufo','ruimte','🛸','Ufo','rare','float'),
    ('sp_galaxy','ruimte','🌌','Melkweg','epic','spin'),
    ('pa_party','feest','🎉','Confetti','common','shake'),
    ('pa_balloon','feest','🎈','Ballon','common','float'),
    ('pa_cake','feest','🎂','Taart','common','bounce'),
    ('pa_gift','feest','🎁','Cadeau','common','jelly'),
    ('pa_guitar','feest','🎸','Gitaar','common','swing'),
    ('pa_disco','feest','🪩','Discobal','rare','spin'),
    ('pa_face','feest','🥳','Feestneus','rare','wobble'),
    ('pa_fireworks','feest','🎆','Vuurwerk','epic','shake'),
    ('spo_ball','sport','⚽','Voetbal','common','bounce'),
    ('spo_bike','sport','🚴','Fietser','common','swing'),
    ('spo_basket','sport','🏀','Basketbal','common','bounce'),
    ('spo_tennis','sport','🎾','Tennisbal','common','wobble'),
    ('spo_pingpong','sport','🏓','Pingpong','common','shake'),
    ('spo_lift','sport','🏋️','Krachtpatser','rare','jelly'),
    ('spo_skate','sport','🛹','Skateboard','rare','swing'),
    ('spo_medal','sport','🥇','Gouden medaille','epic','spin')
$$;

create table if not exists public.user_stickers (
  user_id uuid not null references auth.users(id) on delete cascade,
  sticker_key text not null,
  count int not null default 1,
  first_at timestamptz not null default now(),
  primary key (user_id, sticker_key)
);
alter table public.user_stickers enable row level security;
drop policy if exists "stickers lezen" on public.user_stickers;
create policy "stickers lezen" on public.user_stickers for select to authenticated using (true);
grant select on public.user_stickers to authenticated;
revoke insert, update, delete on public.user_stickers from anon, authenticated;

-- Willekeurige sticker geven (gewoon 70%, zeldzaam 25%, episch 5%)
create or replace function public._give_sticker(p_user uuid, p_min_rarity text default null) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r float8 := random() * 100; v_rar text; s record; v_new boolean;
begin
  v_rar := case when r < 5 then 'epic' when r < 30 then 'rare' else 'common' end;
  if p_min_rarity = 'rare' and v_rar = 'common' then v_rar := 'rare'; end if;
  if p_min_rarity = 'epic' then v_rar := 'epic'; end if;
  select * into s from public._stickers() where rarity = v_rar order by random() limit 1;
  v_new := not exists (select 1 from public.user_stickers where user_id = p_user and sticker_key = s.sticker_key);
  insert into public.user_stickers (user_id, sticker_key) values (p_user, s.sticker_key)
    on conflict (user_id, sticker_key) do update set count = public.user_stickers.count + 1;
  return jsonb_build_object('key', s.sticker_key, 'emoji', s.emoji, 'name', s.name, 'rarity', s.rarity, 'anim', s.anim, 'new', v_new);
end $$;
revoke all on function public._give_sticker(uuid, text) from public, anon, authenticated;

create or replace function public.sticker_catalog() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_agg(jsonb_build_object('key', s.sticker_key, 'theme', s.theme, 'rarity', s.rarity, 'anim', s.anim,
    'count', coalesce(u.count, 0),
    -- Stickers die je nog niet hebt blijven geheim
    'emoji', case when u.count > 0 then s.emoji end, 'name', case when u.count > 0 then s.name end))
  from public._stickers() s
  left join public.user_stickers u on u.user_id = auth.uid() and u.sticker_key = s.sticker_key;
$$;

-- Stickerpakje in de Shop: 3 stickers voor 40 polycoins
create or replace function public.buy_sticker_pack() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); v int; out_ jsonb := '[]'::jsonb; i int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  v := public._shop_spend(me, 40, 'sticker_pack');
  for i in 1..3 loop out_ := out_ || public._give_sticker(me); end loop;
  return jsonb_build_object('stickers', out_, 'wallet', v);
end $$;

-- Volledig thema = 75 polycoins + een themaposter voor je bureau
create table if not exists public.sticker_theme_claims (
  user_id uuid not null references auth.users(id) on delete cascade,
  theme text not null,
  claimed_at timestamptz not null default now(),
  primary key (user_id, theme)
);
alter table public.sticker_theme_claims enable row level security;
drop policy if exists "thema's lezen" on public.sticker_theme_claims;
create policy "thema's lezen" on public.sticker_theme_claims for select to authenticated using (true);
grant select on public.sticker_theme_claims to authenticated;

-- =====================================================================
-- 8. Bureau: inrichten met spullen uit de Shop of uit beloningen
-- =====================================================================
create or replace function public._bureau_items()
returns table (item_key text, slot text, emoji text, name text, price int)
language sql immutable as $$
  values
    -- price 0 = iedereen heeft het, null = enkel te verdienen
    ('wall_none','wall','','Lege muur',0),
    ('wall_art','wall','🖼️','Kunstwerk',60),
    ('wall_clock','wall','🕰️','Oude klok',80),
    ('wall_map','wall','🗺️','Wereldkaart',100),
    ('wall_cat','wall','😺','"Hang in there"-poster',120),
    ('poster_kantoor','wall','🏆','Poster: Kantoor',null),
    ('poster_eten','wall','🍕','Poster: Eten',null),
    ('poster_dieren','wall','🦄','Poster: Dieren',null),
    ('poster_ruimte','wall','🪐','Poster: Ruimte',null),
    ('poster_feest','wall','🪩','Poster: Feest',null),
    ('poster_sport','wall','🥇','Poster: Sport',null),
    ('win_city','window','🌆','Stad',0),
    ('win_beach','window','🏝️','Strand',150),
    ('win_mountain','window','🏔️','Bergen',150),
    ('win_space','window','🌌','Sterrenhemel',250),
    ('plant_none','plant','','Geen plant',0),
    ('plant_pot','plant','🪴','Kamerplant',40),
    ('plant_cactus','plant','🌵','Cactus',50),
    ('plant_sun','plant','🌻','Zonnebloem',70),
    ('plant_bamboo','plant','🎍','Bamboe',90),
    ('pc_laptop','computer','💻','Laptop',0),
    ('pc_big','computer','🖥️','Groot scherm',150),
    ('pc_game','computer','🎮','Gamesetup',220),
    ('drink_coffee','drink','☕','Koffie',0),
    ('drink_tea','drink','🍵','Thee',40),
    ('drink_soda','drink','🥤','Frisdrank',40),
    ('drink_boba','drink','🧋','Bubbletea',60),
    ('lamp_none','lamp','','Geen lamp',0),
    ('lamp_bulb','lamp','💡','Bureaulamp',50),
    ('lamp_candle','lamp','🕯️','Kaars',40),
    ('lamp_oil','lamp','🪔','Olielamp',90),
    ('lamp_orb','lamp','🔮','Kristallen bol',200),
    ('floor_chair','floor','🪑','Stoel',0),
    ('floor_bear','floor','🧸','Knuffelbeer',70),
    ('floor_guitar','floor','🎸','Gitaar',160),
    ('floor_sofa','floor','🛋️','Zetel',180)
$$;

create table if not exists public.bureau_owned (
  user_id uuid not null references auth.users(id) on delete cascade,
  item_key text not null,
  primary key (user_id, item_key)
);
alter table public.bureau_owned enable row level security;
drop policy if exists "bureau lezen" on public.bureau_owned;
create policy "bureau lezen" on public.bureau_owned for select to authenticated using (auth.uid() = user_id);
grant select on public.bureau_owned to authenticated;

alter table public.profiles add column if not exists bureau jsonb not null default '{}'::jsonb;
alter table public.profiles add column if not exists showcase int[] not null default '{}';

create or replace function public.bureau_state() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'items', (select jsonb_agg(jsonb_build_object('key', b.item_key, 'slot', b.slot, 'emoji', b.emoji, 'name', b.name, 'price', b.price,
               'owned', b.price = 0 or exists (select 1 from public.bureau_owned o where o.user_id = auth.uid() and o.item_key = b.item_key)))
             from public._bureau_items() b),
    'equipped', (select bureau from public.profiles where id = auth.uid()));
$$;

create or replace function public.buy_bureau_item(p_key text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); it record; v int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select * into it from public._bureau_items() where item_key = p_key;
  if not found then raise exception 'Onbekend item.'; end if;
  if it.price is null then raise exception 'Dit item kan je enkel verdienen (vervolledig het stickerthema).'; end if;
  if it.price = 0 or exists (select 1 from public.bureau_owned where user_id = me and item_key = p_key) then
    raise exception 'Je hebt dit al.';
  end if;
  v := public._shop_spend(me, it.price, 'bureau', jsonb_build_object('item', p_key));
  insert into public.bureau_owned values (me, p_key);
  update public.profiles set bureau = bureau || jsonb_build_object(it.slot, p_key) where id = me;
  return jsonb_build_object('wallet', v);
end $$;

create or replace function public.equip_bureau_item(p_key text) returns void
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); it record;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select * into it from public._bureau_items() where item_key = p_key;
  if not found then raise exception 'Onbekend item.'; end if;
  if it.price <> 0 or it.price is null then
    if not exists (select 1 from public.bureau_owned where user_id = me and item_key = p_key) then
      raise exception 'Je hebt dit item niet.';
    end if;
  end if;
  update public.profiles set bureau = bureau || jsonb_build_object(it.slot, p_key) where id = me;
end $$;

-- Stickerthema's controleren en belonen (wordt automatisch door de site aangeroepen)
create or replace function public.claim_sticker_rewards() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); t record; out_ jsonb := '[]'::jsonb;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  for t in
    select s.theme from public._stickers() s
    left join public.user_stickers u on u.user_id = me and u.sticker_key = s.sticker_key
    group by s.theme having count(*) = count(u.sticker_key)
  loop
    insert into public.sticker_theme_claims (user_id, theme) values (me, t.theme) on conflict do nothing;
    if found then
      perform public._give_coins(me, 75, 'sticker_theme', jsonb_build_object('theme', t.theme));
      insert into public.bureau_owned values (me, 'poster_' || t.theme) on conflict do nothing;
      perform public._log_activity(me, 'sticker_theme', jsonb_build_object('theme', t.theme));
      out_ := out_ || jsonb_build_object('theme', t.theme, 'reward', 75);
    end if;
  end loop;
  return out_;
end $$;

-- =====================================================================
-- 10. Casino (enkel polycoins). Alles wordt op de server getrokken.
-- =====================================================================
create table if not exists public.casino_log (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  game text not null,
  bet int not null default 0,
  win int not null default 0,
  detail jsonb,
  created_at timestamptz not null default now()
);
create index if not exists casino_log_user_idx on public.casino_log (user_id, game, created_at desc);
alter table public.casino_log enable row level security;
drop policy if exists "eigen casino lezen" on public.casino_log;
create policy "eigen casino lezen" on public.casino_log for select to authenticated using (auth.uid() = user_id);
grant select on public.casino_log to authenticated;
revoke insert, update, delete on public.casino_log from anon, authenticated;

-- --- Rad van fortuin: 1 gratis draai per dag (2 tijdens de rad-week) ---
-- Vakjes (in volgorde op het rad): 0 10🪙 · 1 sticker · 2 20🪙 · 3 Basic Pack · 4 30🪙 · 5 100🪙 · 6 50🪙 · 7 Epic Pack
create or replace function public.casino_wheel_state() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('left', greatest(0,
    (case when public._week_event() = 'lucky_wheel' then 2 else 1 end) -
    (select count(*) from public.casino_log where user_id = auth.uid() and game = 'wheel'
       and (created_at at time zone 'Europe/Brussels')::date = public._today())::int));
$$;

create or replace function public.casino_spin() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); r float8 := random() * 100; seg int; coins int := 0; v_cards jsonb := '[]'::jsonb; v_sticker jsonb;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if (public.casino_wheel_state()->>'left')::int <= 0 then raise exception 'Je hebt vandaag al gedraaid. Kom morgen terug!'; end if;
  seg := case when r < 24 then 0 when r < 38 then 1 when r < 58 then 2 when r < 66 then 3
              when r < 81 then 4 when r < 86 then 5 when r < 98 then 6 else 7 end;
  coins := case seg when 0 then 10 when 2 then 20 when 4 then 30 when 5 then 100 when 6 then 50 else 0 end;
  if coins > 0 then perform public._tb_pay(me, coins); end if;
  if seg = 1 then v_sticker := public._give_sticker(me); end if;
  if seg = 3 then v_cards := v_cards || public._shop_give(me, public._shop_roll(3, 22)); end if;
  if seg = 7 then
    v_cards := v_cards || public._shop_give(me, public._shop_roll(3, 22));
    v_cards := v_cards || public._shop_give(me, public._shop_roll(3, 22));
    v_cards := v_cards || public._shop_give(me, public._shop_roll(15, 85));
  end if;
  insert into public.casino_log (user_id, game, win, detail) values (me, 'wheel', coins, jsonb_build_object('seg', seg));
  return jsonb_build_object('seg', seg, 'coins', coins, 'cards', v_cards, 'sticker', v_sticker,
    'wallet', (select polycoins from public.user_wallet where user_id = me),
    'left', (public.casino_wheel_state()->>'left')::int);
end $$;

-- --- Fruitautomaat: inzet 10/25/50/100. 3 dezelfde = vermenigvuldiger, 2 dezelfde = inzet terug ---
create or replace function public.casino_slots(p_bet int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  syms text[] := array['🍒', '☕', '📎', '🎴', '⭐', '💎'];
  wts int[] := array[30, 25, 20, 12, 8, 5];
  mults int[] := array[5, 8, 12, 25, 50, 100];
  reels int[] := '{}'; i int; j int; acc int; r int; win int := 0; v int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if p_bet not in (10, 25, 50, 100) then raise exception 'Kies een inzet van 10, 25, 50 of 100.'; end if;
  v := public._shop_spend(me, p_bet, 'casino_slots');
  for i in 1..3 loop
    r := floor(random() * 100)::int; acc := 0;
    for j in 1..6 loop acc := acc + wts[j]; if r < acc then reels := reels || j; exit; end if; end loop;
  end loop;
  if reels[1] = reels[2] and reels[2] = reels[3] then win := p_bet * mults[reels[1]];
  elsif reels[1] = reels[2] or reels[2] = reels[3] or reels[1] = reels[3] then win := p_bet;
  end if;
  if win > 0 then perform public._tb_pay(me, win); v := v + win; end if;
  insert into public.casino_log (user_id, game, bet, win, detail)
    values (me, 'slots', p_bet, win, jsonb_build_object('reels', reels, 'jackpot', reels[1] = 6 and win > p_bet));
  if reels[1] = 6 and win > p_bet then
    perform public._log_activity(me, 'jackpot', jsonb_build_object('win', win));
  end if;
  return jsonb_build_object('reels', (select jsonb_agg(syms[x]) from unnest(reels) x), 'win', win, 'wallet', v);
end $$;

-- --- Blackjack: dealer past vanaf 17, blackjack betaalt 3:2, verdubbelen met 2 kaarten ---
create table if not exists public.casino_bj (
  user_id uuid primary key references auth.users(id) on delete cascade,
  bet int not null,
  deck int[] not null,
  player int[] not null,
  dealer int[] not null,
  status text not null default 'playing',   -- playing / won / lost / push / blackjack
  payout int not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.casino_bj enable row level security;
-- Bewust geen policies: het kaartspel en de verborgen dealerkaart blijven geheim

create or replace function public._bj_value(p_cards int[]) returns int
language sql immutable as $$
  select case when sum(v) + 10 <= 21 and bool_or(c % 13 = 0) then sum(v) + 10 else sum(v) end::int
  from (select c, case when c % 13 = 0 then 1 when c % 13 >= 9 then 10 else c % 13 + 1 end as v from unnest(p_cards) c) x;
$$;

create or replace function public._bj_view(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare g public.casino_bj;
begin
  select * into g from public.casino_bj where user_id = p_user;
  if not found then return jsonb_build_object('status', 'none'); end if;
  return jsonb_build_object('status', g.status, 'bet', g.bet, 'payout', g.payout,
    'player', to_jsonb(g.player), 'ptotal', public._bj_value(g.player),
    'dealer', case when g.status = 'playing' then jsonb_build_array(g.dealer[1], -1) else to_jsonb(g.dealer) end,
    'dtotal', case when g.status = 'playing' then public._bj_value(array[g.dealer[1]]) else public._bj_value(g.dealer) end,
    'can_double', g.status = 'playing' and array_length(g.player, 1) = 2,
    'wallet', (select polycoins from public.user_wallet where user_id = p_user));
end $$;
revoke all on function public._bj_view(uuid) from public, anon, authenticated;

-- Hand afrekenen (dealer speelt verder als dat nodig is)
create or replace function public._bj_settle(p_user uuid, p_dealer_plays boolean) returns void
language plpgsql volatile security definer set search_path = public as $$
declare g public.casino_bj; p int; d int; st text; pay int;
begin
  select * into g from public.casino_bj where user_id = p_user for update;
  p := public._bj_value(g.player);
  if p_dealer_plays and p <= 21 then
    while public._bj_value(g.dealer) < 17 loop
      g.dealer := g.dealer || g.deck[1]; g.deck := g.deck[2:];
    end loop;
  end if;
  d := public._bj_value(g.dealer);
  if p > 21 then st := 'lost'; pay := 0;
  elsif array_length(g.player, 1) = 2 and p = 21 and not (array_length(g.dealer, 1) = 2 and d = 21) then st := 'blackjack'; pay := round(g.bet * 2.5)::int;
  elsif d > 21 or p > d then st := 'won'; pay := g.bet * 2;
  elsif p = d then st := 'push'; pay := g.bet;
  else st := 'lost'; pay := 0;
  end if;
  if pay > 0 then perform public._tb_pay(p_user, pay); end if;
  update public.casino_bj set dealer = g.dealer, deck = g.deck, status = st, payout = pay, updated_at = now() where user_id = p_user;
  insert into public.casino_log (user_id, game, bet, win, detail) values (p_user, 'blackjack', g.bet, pay, jsonb_build_object('result', st));
end $$;
revoke all on function public._bj_settle(uuid, boolean) from public, anon, authenticated;

create or replace function public.bj_state() returns jsonb
language sql stable security definer set search_path = public as $$ select public._bj_view(auth.uid()) $$;

create or replace function public.bj_start(p_bet int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); dk int[];
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if p_bet < 10 or p_bet > 200 then raise exception 'Zet tussen 10 en 200 polycoins in.'; end if;
  if exists (select 1 from public.casino_bj where user_id = me and status = 'playing') then
    raise exception 'Speel eerst je huidige hand uit.';
  end if;
  perform public._shop_spend(me, p_bet, 'casino_blackjack');
  select array_agg(c order by random()) into dk from generate_series(0, 51) c;
  insert into public.casino_bj (user_id, bet, deck, player, dealer, status, payout)
    values (me, p_bet, dk[5:], array[dk[1], dk[3]], array[dk[2], dk[4]], 'playing', 0)
    on conflict (user_id) do update set bet = excluded.bet, deck = excluded.deck, player = excluded.player,
      dealer = excluded.dealer, status = 'playing', payout = 0, updated_at = now();
  -- Blackjack meteen (speler of dealer) wordt direct afgerekend
  if public._bj_value(array[dk[1], dk[3]]) = 21 or public._bj_value(array[dk[2], dk[4]]) = 21 then
    perform public._bj_settle(me, false);
  end if;
  return public._bj_view(me);
end $$;

create or replace function public.bj_action(p_action text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); g public.casino_bj;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select * into g from public.casino_bj where user_id = me for update;
  if not found or g.status <> 'playing' then raise exception 'Er is geen hand bezig.'; end if;
  if p_action = 'hit' then
    update public.casino_bj set player = player || deck[1], deck = deck[2:], updated_at = now() where user_id = me;
    if public._bj_value(g.player || g.deck[1]) >= 21 then perform public._bj_settle(me, true); end if;
  elsif p_action = 'stand' then
    perform public._bj_settle(me, true);
  elsif p_action = 'double' then
    if array_length(g.player, 1) <> 2 then raise exception 'Verdubbelen kan enkel met je eerste 2 kaarten.'; end if;
    perform public._shop_spend(me, g.bet, 'casino_blackjack');
    update public.casino_bj set bet = bet * 2, player = player || deck[1], deck = deck[2:], updated_at = now() where user_id = me;
    perform public._bj_settle(me, true);
  else
    raise exception 'Onbekende actie.';
  end if;
  return public._bj_view(me);
end $$;

-- --- Krasbiljet: 25 polycoins, 6 vakjes, 3 dezelfde = prijs ---
create or replace function public.casino_scratch() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid(); r float8 := random() * 100; k text; syms text[]; prize int := 0; v_sticker jsonb; v int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  v := public._shop_spend(me, 25, 'casino_scratch');
  k := case when r < 22 then 'c25' when r < 36 then 'c50' when r < 41 then 'c100' when r < 42.5 then 'c250' when r < 45.5 then 'stk' end;
  if k is null then
    select array_agg(x order by random()) into syms from (
      select x from unnest(array['c25','c50','c100','c250','stk','c25','c50','c100','c250','stk']) x order by random() limit 6) y;
  else
    select array_agg(x order by random()) into syms from (
      select k as x from generate_series(1, 3)
      union all
      (select x from unnest(array['c25','c50','c100','c250','stk']) x where x <> k order by random() limit 3)) y;
    prize := case k when 'c25' then 25 when 'c50' then 50 when 'c100' then 100 when 'c250' then 250 else 0 end;
    if prize > 0 then perform public._tb_pay(me, prize); v := v + prize; end if;
    if k = 'stk' then v_sticker := public._give_sticker(me, 'rare'); end if;
  end if;
  insert into public.casino_log (user_id, game, bet, win, detail) values (me, 'scratch', 25, prize, jsonb_build_object('k', k));
  return jsonb_build_object('symbols', to_jsonb(syms), 'win', k, 'prize', prize, 'sticker', v_sticker, 'wallet', v);
end $$;

-- =====================================================================
-- 11. Puzzels: elke dag nieuw en voor iedereen dezelfde
--     Verbanden (16 woorden in 4 groepjes), Memory (8 paren) en Mini-sudoku (6×6)
-- =====================================================================
create table if not exists public.puzzle_games (
  user_id uuid not null references auth.users(id) on delete cascade,
  pdate date not null,
  kind text not null check (kind in ('conn', 'memory', 'sudoku')),
  state jsonb not null default '{}'::jsonb,
  status text not null default 'playing' check (status in ('playing', 'won', 'lost')),
  reward int not null default 0,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  primary key (user_id, pdate, kind)
);
alter table public.puzzle_games enable row level security;
-- Bewust geen policies: lezen via de puzzelfuncties

create table if not exists public.conn_puzzles (
  id int primary key,
  groups jsonb not null
);
alter table public.conn_puzzles enable row level security;
-- Bewust geen policies: de oplossingen blijven geheim

insert into public.conn_puzzles (id, groups) values
  (1, '[{"t": "Fruit", "w": ["APPEL", "PEER", "KERS", "PRUIM"], "l": 1}, {"t": "Kaartkleuren", "w": ["HARTEN", "RUITEN", "KLAVEREN", "SCHOPPEN"], "l": 2}, {"t": "Op je bureau", "w": ["NIETJE", "PERFORATOR", "MAP", "PRINTER"], "l": 3}, {"t": "___boom", "w": ["KERST", "STAM", "SLAG", "PALM"], "l": 4}]'::jsonb),
  (2, '[{"t": "Belgische steden", "w": ["GENT", "BRUGGE", "LEUVEN", "MECHELEN"], "l": 1}, {"t": "Koffie", "w": ["ESPRESSO", "LATTE", "CAPPUCCINO", "MOKKA"], "l": 2}, {"t": "Planeten", "w": ["MARS", "VENUS", "SATURNUS", "JUPITER"], "l": 3}, {"t": "___koek", "w": ["PEPER", "ONTBIJT", "PANNEN", "BOTER"], "l": 4}]'::jsonb),
  (3, '[{"t": "Huisdieren", "w": ["HOND", "KAT", "KONIJN", "CAVIA"], "l": 1}, {"t": "Weer", "w": ["REGEN", "HAGEL", "SNEEUW", "MIST"], "l": 2}, {"t": "Muziekinstrumenten", "w": ["GITAAR", "VIOOL", "TROMPET", "HARP"], "l": 3}, {"t": "___stoel", "w": ["BUREAU", "SCHOMMEL", "ROL", "KINDER"], "l": 4}]'::jsonb),
  (4, '[{"t": "Zuivel", "w": ["MELK", "KAAS", "BOTER", "YOGHURT"], "l": 1}, {"t": "Balsporten", "w": ["TENNIS", "HOCKEY", "GOLF", "RUGBY"], "l": 2}, {"t": "Kleuren", "w": ["OKER", "INDIGO", "TURKOOIS", "MAGENTA"], "l": 3}, {"t": "Er zit een dier in", "w": ["KATROL", "VISUM", "BEERPUT", "UILSKUIKEN"], "l": 4}]'::jsonb),
  (5, '[{"t": "Groenten", "w": ["WORTEL", "PREI", "UI", "SPRUIT"], "l": 1}, {"t": "Op kantoor", "w": ["VERGADERING", "DEADLINE", "MAIL", "AGENDA"], "l": 2}, {"t": "Gewrichten", "w": ["ELLEBOOG", "KNIE", "ENKEL", "POLS"], "l": 3}, {"t": "___bad", "w": ["BUBBEL", "ZON", "MODDER", "STOOM"], "l": 4}]'::jsonb),
  (6, '[{"t": "Seizoenen", "w": ["LENTE", "ZOMER", "HERFST", "WINTER"], "l": 1}, {"t": "Ontbijt", "w": ["CROISSANT", "MUESLI", "OMELET", "WAFEL"], "l": 2}, {"t": "Openbaar vervoer", "w": ["TRAM", "METRO", "BUS", "TREIN"], "l": 3}, {"t": "___boek", "w": ["DAG", "KOOK", "STRIP", "PRENTEN"], "l": 4}]'::jsonb),
  (7, '[{"t": "Zeezoogdieren", "w": ["DOLFIJN", "WALVIS", "ZEEHOND", "ORKA"], "l": 1}, {"t": "Bloemen", "w": ["ROOS", "TULP", "LELIE", "ORCHIDEE"], "l": 2}, {"t": "Tellen in het Spaans", "w": ["UNO", "DOS", "TRES", "CUATRO"], "l": 3}, {"t": "Aan je computer", "w": ["MUIS", "SCHERM", "WEBCAM", "USB"], "l": 4}]'::jsonb),
  (8, '[{"t": "Kledij", "w": ["JAS", "BROEK", "TRUI", "SJAAL"], "l": 1}, {"t": "Fastfood", "w": ["FRIET", "BURGER", "PIZZA", "KEBAB"], "l": 2}, {"t": "Kaas", "w": ["BRIE", "GOUDA", "FETA", "CHEDDAR"], "l": 3}, {"t": "___plaats", "w": ["WERK", "PARKEER", "GEBOORTE", "MARKT"], "l": 4}]'::jsonb),
  (9, '[{"t": "Regenboog", "w": ["ROOD", "ORANJE", "GEEL", "GROEN"], "l": 1}, {"t": "Vogels", "w": ["MEEUW", "MUS", "MEREL", "SPECHT"], "l": 2}, {"t": "Gereedschap", "w": ["HAMER", "SCHROEVENDRAAIER", "TANG", "BOOR"], "l": 3}, {"t": "___vis", "w": ["GOUD", "ZWAARD", "KOGEL", "INKT"], "l": 4}]'::jsonb),
  (10, '[{"t": "Dranken", "w": ["WATER", "THEE", "SAP", "LIMONADE"], "l": 1}, {"t": "Gevoelens", "w": ["BLIJ", "BOOS", "BANG", "VERDRIETIG"], "l": 2}, {"t": "Dansen", "w": ["TANGO", "WALS", "HIPHOP", "BREAKDANCE"], "l": 3}, {"t": "Frietsauzen", "w": ["MAYO", "KETCHUP", "SAMOERAI", "ANDALOUSE"], "l": 4}]'::jsonb),
  (11, '[{"t": "Schoolvakken", "w": ["WISKUNDE", "FRANS", "AARDRIJKSKUNDE", "TURNEN"], "l": 1}, {"t": "Sterrenbeelden", "w": ["RAM", "STIER", "LEEUW", "WEEGSCHAAL"], "l": 2}, {"t": "Snoep", "w": ["DROP", "LOLLY", "ZUURTJE", "MARSHMALLOW"], "l": 3}, {"t": "___tand", "w": ["HOEK", "MELK", "SNIJ", "OOG"], "l": 4}]'::jsonb),
  (12, '[{"t": "Keukengerei", "w": ["PAN", "POT", "LEPEL", "VORK"], "l": 1}, {"t": "Gezelschapsspellen", "w": ["SCHAAK", "DAMMEN", "MONOPOLY", "DOMINO"], "l": 2}, {"t": "Belgische rivieren", "w": ["SCHELDE", "MAAS", "LEIE", "DIJLE"], "l": 3}, {"t": "Metalen", "w": ["GOUD", "ZILVER", "KOPER", "LOOD"], "l": 4}]'::jsonb),
  (13, '[{"t": "Bomen", "w": ["EIK", "BEUK", "BERK", "WILG"], "l": 1}, {"t": "Insecten", "w": ["MIER", "BIJ", "WESP", "VLINDER"], "l": 2}, {"t": "Munten", "w": ["EURO", "DOLLAR", "YEN", "POND"], "l": 3}, {"t": "___kast", "w": ["KLEER", "BOEKEN", "SCHOEN", "KOEL"], "l": 4}]'::jsonb),
  (14, '[{"t": "Vakantie", "w": ["STRAND", "ZON", "ZWEMBAD", "KOFFER"], "l": 1}, {"t": "In huis", "w": ["KEUKEN", "ZOLDER", "KELDER", "GARAGE"], "l": 2}, {"t": "Beroepen", "w": ["BAKKER", "SLAGER", "DOKTER", "PILOOT"], "l": 3}, {"t": "Sprookjesfiguren", "w": ["ASSEPOESTER", "SNEEUWWITJE", "ROODKAPJE", "REPELSTEELTJE"], "l": 4}]'::jsonb),
  (15, '[{"t": "''s Ochtends", "w": ["DOUCHEN", "TANDENPOETSEN", "ONTBIJTEN", "AANKLEDEN"], "l": 1}, {"t": "Sociale media", "w": ["INSTAGRAM", "TIKTOK", "FACEBOOK", "SNAPCHAT"], "l": 2}, {"t": "Fiets", "w": ["ZADEL", "KETTING", "PEDAAL", "STUUR"], "l": 3}, {"t": "___vogel", "w": ["NACHT", "ROOF", "TREK", "ZANG"], "l": 4}]'::jsonb),
  (16, '[{"t": "Smaken", "w": ["ZOET", "ZUUR", "ZOUT", "BITTER"], "l": 1}, {"t": "Superhelden", "w": ["BATMAN", "SUPERMAN", "SPIDERMAN", "HULK"], "l": 2}, {"t": "Europese landen", "w": ["NOORWEGEN", "PORTUGAL", "OOSTENRIJK", "ZWEDEN"], "l": 3}, {"t": "Er zit een lichaamsdeel in", "w": ["BEENHOUWER", "KNIESOOR", "HOOFDSTAD", "ARMBAND"], "l": 4}]'::jsonb),
  (17, '[{"t": "Op je boterham", "w": ["CHOCO", "CONFITUUR", "KAAS", "HAM"], "l": 1}, {"t": "Zee", "w": ["EB", "VLOED", "GOLF", "STROMING"], "l": 2}, {"t": "Disneyfilms", "w": ["FROZEN", "MOANA", "COCO", "ENCANTO"], "l": 3}, {"t": "___lijn", "w": ["TIJD", "FINISH", "HULP", "KUST"], "l": 4}]'::jsonb),
  (18, '[{"t": "Wintersport", "w": ["SKI", "SNOWBOARD", "SCHAATS", "SLEE"], "l": 1}, {"t": "Kerstversiering", "w": ["PIEK", "SLINGER", "ENGEL", "KRANS"], "l": 2}, {"t": "Hondenrassen", "w": ["POEDEL", "LABRADOR", "TECKEL", "HUSKY"], "l": 3}, {"t": "___vlees", "w": ["RUND", "KALFS", "VARKENS", "LAMS"], "l": 4}]'::jsonb),
  (19, '[{"t": "Weekdagen", "w": ["MAANDAG", "DINSDAG", "WOENSDAG", "VRIJDAG"], "l": 1}, {"t": "Ziekenhuis", "w": ["VERPLEEGSTER", "SPUIT", "PLEISTER", "BRANCARD"], "l": 2}, {"t": "IJssmaken", "w": ["VANILLE", "AARDBEI", "MOKKA", "PISTACHE"], "l": 3}, {"t": "Er zit een getal in", "w": ["DRIEHOEK", "VIERKANT", "TIENER", "ACHTERBAN"], "l": 4}]'::jsonb),
  (20, '[{"t": "Bouwmaterialen", "w": ["BAKSTEEN", "CEMENT", "ZAND", "BETON"], "l": 1}, {"t": "Monumenten", "w": ["ATOMIUM", "EIFFELTOREN", "COLOSSEUM", "BIGBEN"], "l": 2}, {"t": "Edelstenen", "w": ["ROBIJN", "SAFFIER", "SMARAGD", "DIAMANT"], "l": 3}, {"t": "___taart", "w": ["APPEL", "KAAS", "RIJST", "SLAGROOM"], "l": 4}]'::jsonb),
  (21, '[{"t": "In de tuin", "w": ["GRAS", "HAAG", "VIJVER", "SCHUUR"], "l": 1}, {"t": "Pasta", "w": ["SPAGHETTI", "PENNE", "LASAGNE", "FUSILLI"], "l": 2}, {"t": "Schaakstukken", "w": ["KONING", "DAME", "TOREN", "PAARD"], "l": 3}, {"t": "___spel", "w": ["KAART", "BORD", "SCHIJN", "WOORD"], "l": 4}]'::jsonb),
  (22, '[{"t": "Weekend", "w": ["UITSLAPEN", "BRUNCH", "WANDELEN", "NETFLIX"], "l": 1}, {"t": "Strandbeestjes", "w": ["KWAL", "KRAB", "ZEESTER", "HAAI"], "l": 2}, {"t": "Componisten", "w": ["MOZART", "BACH", "BEETHOVEN", "VIVALDI"], "l": 3}, {"t": "___bel", "w": ["DEUR", "FIETS", "ZEEP", "KOE"], "l": 4}]'::jsonb),
  (23, '[{"t": "Door de lucht", "w": ["VLIEGTUIG", "HELIKOPTER", "ZEPPELIN", "LUCHTBALLON"], "l": 1}, {"t": "Bakkerij", "w": ["BROOD", "PISTOLET", "KOFFIEKOEK", "ECLAIR"], "l": 2}, {"t": "Wiskunde", "w": ["SOM", "BREUK", "WORTEL", "GETAL"], "l": 3}, {"t": "Vergadertaal", "w": ["AFSTEMMEN", "BIJPRATEN", "SPARREN", "TERUGKOPPELEN"], "l": 4}]'::jsonb),
  (24, '[{"t": "Zintuigen", "w": ["ZIEN", "HOREN", "RUIKEN", "PROEVEN"], "l": 1}, {"t": "Vormen", "w": ["CIRKEL", "DRIEHOEK", "VIERKANT", "OVAAL"], "l": 2}, {"t": "Poker", "w": ["BLUF", "POT", "FLUSH", "FOLD"], "l": 3}, {"t": "Do-re-mi", "w": ["DO", "RE", "MI", "FA"], "l": 4}]'::jsonb),
  (25, '[{"t": "Boerderijdieren", "w": ["KOE", "VARKEN", "SCHAAP", "GEIT"], "l": 1}, {"t": "Italiaans eten", "w": ["RISOTTO", "TIRAMISU", "BRUSCHETTA", "GNOCCHI"], "l": 2}, {"t": "Oude munten", "w": ["FRANK", "GULDEN", "MARK", "LIRE"], "l": 3}, {"t": "___stok", "w": ["WANDEL", "BEZEM", "HOCKEY", "DRUM"], "l": 4}]'::jsonb),
  (26, '[{"t": "Belgische klassiekers", "w": ["STOOFVLEES", "WATERZOOI", "STOEMP", "MOSSELEN"], "l": 1}, {"t": "Kantoorbenodigdheden", "w": ["STEMPEL", "NIETMACHINE", "LIJMSTIFT", "SCHAAR"], "l": 2}, {"t": "Roofvogels", "w": ["ADELAAR", "VALK", "BUIZERD", "HAVIK"], "l": 3}, {"t": "___bril", "w": ["ZONNE", "LEES", "DUIK", "SKI"], "l": 4}]'::jsonb),
  (27, '[{"t": "Muziekstijlen", "w": ["ROCK", "JAZZ", "POP", "TECHNO"], "l": 1}, {"t": "In de ruimte", "w": ["KOMEET", "METEOOR", "NEVEL", "PLANEET"], "l": 2}, {"t": "Kruiden", "w": ["BASILICUM", "PETERSELIE", "TIJM", "ROZEMARIJN"], "l": 3}, {"t": "___post", "w": ["DOEL", "VOOR", "LUCHT", "BUITEN"], "l": 4}]'::jsonb),
  (28, '[{"t": "Speelgoed", "w": ["LEGO", "POP", "KNUFFEL", "PUZZEL"], "l": 1}, {"t": "Badkamer", "w": ["TANDENBORSTEL", "HANDDOEK", "ZEEP", "SHAMPOO"], "l": 2}, {"t": "Verjaardag", "w": ["TAART", "SLINGERS", "BALLONNEN", "CADEAUS"], "l": 3}, {"t": "___wagen", "w": ["BRAND", "POLITIE", "ZIEKEN", "BOODSCHAPPEN"], "l": 4}]'::jsonb),
  (29, '[{"t": "Tijd", "w": ["SECONDE", "MINUUT", "UUR", "WEEK"], "l": 1}, {"t": "Huishoudtoestellen", "w": ["STOFZUIGER", "WASMACHINE", "DROOGKAST", "MICROGOLF"], "l": 2}, {"t": "Kaartspelen", "w": ["POKER", "BRIDGE", "PESTEN", "WIEZEN"], "l": 3}, {"t": "___ling", "w": ["LEER", "NIEUWE", "VREEMDE", "ZUIGE"], "l": 4}]'::jsonb),
  (30, '[{"t": "Voetbal", "w": ["GOAL", "CORNER", "PENALTY", "OFFSIDE"], "l": 1}, {"t": "Haarkleuren", "w": ["BLOND", "BRUIN", "ZWART", "ROSSIG"], "l": 2}, {"t": "Snacks", "w": ["CHIPS", "NOOTJES", "POPCORN", "BITTERBALLEN"], "l": 3}, {"t": "In de auto", "w": ["GORDEL", "STUUR", "KOFFER", "CLAXON"], "l": 4}]'::jsonb)
on conflict (id) do update set groups = excluded.groups;

-- Beloning voor een opgeloste puzzel (dubbel tijdens puzzelweek, 2 stickers tijdens stickerweek)
create or replace function public._puzzle_reward(p_user uuid, p_kind text, p_coins int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare c int := p_coins; st jsonb := '[]'::jsonb; i int;
begin
  if public._week_event() = 'puzzle_bonus' then c := c * 2; end if;
  perform public._give_coins(p_user, c, 'puzzle', jsonb_build_object('kind', p_kind));
  update public.puzzle_games set reward = c where user_id = p_user and pdate = public._today() and kind = p_kind;
  for i in 1..(case when public._week_event() = 'sticker_bonus' then 2 else 1 end) loop
    st := st || public._give_sticker(p_user);
  end loop;
  return jsonb_build_object('coins', c, 'stickers', st);
end $$;
revoke all on function public._puzzle_reward(uuid, text, int) from public, anon, authenticated;

create or replace function public._puzzle_game(p_user uuid, p_kind text) returns public.puzzle_games
language plpgsql volatile security definer set search_path = public as $$
declare g public.puzzle_games;
begin
  insert into public.puzzle_games (user_id, pdate, kind) values (p_user, public._today(), p_kind) on conflict do nothing;
  select * into g from public.puzzle_games where user_id = p_user and pdate = public._today() and kind = p_kind for update;
  return g;
end $$;
revoke all on function public._puzzle_game(uuid, text) from public, anon, authenticated;

-- --- Verbanden ---
create or replace function public._conn_today() returns jsonb
language sql stable security definer set search_path = public as $$
  select groups from public.conn_puzzles
  order by id offset ((public._today() - date '2026-01-01') % greatest(1, (select count(*) from public.conn_puzzles)::int)) limit 1;
$$;
revoke all on function public._conn_today() from public, anon, authenticated;

create or replace function public._conn_view(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare pz jsonb := public._conn_today(); g public.puzzle_games; solved jsonb; done boolean;
begin
  select * into g from public.puzzle_games where user_id = p_user and pdate = public._today() and kind = 'conn';
  solved := coalesce(g.state->'solved', '[]'::jsonb);
  done := coalesce(g.status, 'playing') <> 'playing';
  return jsonb_build_object(
    'status', coalesce(g.status, 'playing'), 'mistakes', coalesce((g.state->>'mistakes')::int, 0), 'reward', coalesce(g.reward, 0),
    -- Opgeloste groepjes (of alles, als het spel gedaan is), in volgorde van oplossen
    'solved', (select coalesce(jsonb_agg(pz->(x::int) order by o), '[]'::jsonb) from jsonb_array_elements_text(solved) with ordinality s(x, o)),
    'revealed', case when done then (select jsonb_agg(e) from jsonb_array_elements(pz) e
                                     where not exists (select 1 from jsonb_array_elements_text(solved) s where (pz->(s::int)) = e)) end,
    -- Overblijvende woorden in een vaste, door elkaar geschudde volgorde
    'words', (select coalesce(jsonb_agg(w order by md5(public._today()::text || w)), '[]'::jsonb)
              from jsonb_array_elements(pz) with ordinality e(grp, i), jsonb_array_elements_text(grp->'w') w
              where not solved @> to_jsonb((i - 1)::int)));
end $$;
revoke all on function public._conn_view(uuid) from public, anon, authenticated;

create or replace function public.conn_state() returns jsonb
language sql stable security definer set search_path = public as $$ select public._conn_view(auth.uid()) $$;

create or replace function public.conn_guess(p_words text[]) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid(); pz jsonb := public._conn_today(); g public.puzzle_games;
  solved jsonb; i int; hit int; best int := 0; n int; mistakes int; res jsonb := '{}'::jsonb;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if array_length(p_words, 1) <> 4 or (select count(distinct upper(x)) from unnest(p_words) x) <> 4 then
    raise exception 'Kies precies 4 verschillende woorden.';
  end if;
  g := public._puzzle_game(me, 'conn');
  if g.status <> 'playing' then raise exception 'Je hebt de Verbanden van vandaag al gespeeld.'; end if;
  solved := coalesce(g.state->'solved', '[]'::jsonb);
  mistakes := coalesce((g.state->>'mistakes')::int, 0);
  for i in 0..3 loop
    if solved @> to_jsonb(i) then continue; end if;
    select count(*) into n from jsonb_array_elements_text(pz->i->'w') w where w = any(select upper(x) from unnest(p_words) x);
    if n = 4 then hit := i; end if;
    best := greatest(best, n);
  end loop;
  if hit is not null then
    solved := solved || to_jsonb(hit);
    res := jsonb_build_object('correct', true, 'group', pz->hit);
    if jsonb_array_length(solved) = 4 then
      update public.puzzle_games set state = jsonb_build_object('solved', solved, 'mistakes', mistakes),
        status = 'won', finished_at = now(), reward = greatest(10, 40 - 8 * mistakes) where user_id = me and pdate = g.pdate and kind = 'conn';
      res := res || jsonb_build_object('prize', public._puzzle_reward(me, 'conn', greatest(10, 40 - 8 * mistakes)));
    else
      update public.puzzle_games set state = jsonb_build_object('solved', solved, 'mistakes', mistakes)
        where user_id = me and pdate = g.pdate and kind = 'conn';
    end if;
  else
    mistakes := mistakes + 1;
    res := jsonb_build_object('correct', false, 'one_away', best = 3);
    update public.puzzle_games set state = jsonb_build_object('solved', solved, 'mistakes', mistakes),
      status = case when mistakes >= 4 then 'lost' else 'playing' end,
      finished_at = case when mistakes >= 4 then now() end,
      reward = case when mistakes >= 4 then 5 else 0 end
      where user_id = me and pdate = g.pdate and kind = 'conn';
    if mistakes >= 4 then perform public._give_coins(me, 5, 'puzzle', '{"kind":"conn"}'); end if;
  end if;
  return res || jsonb_build_object('state', public._conn_view(me));
end $$;

-- --- Memory: 16 kaartjes, iedereen dezelfde ligging ---
create or replace function public._memory_layout(p_date date) returns text[]
language sql immutable as $$
  select array_agg(icon order by md5(p_date::text || 'pos' || icon || n))
  from (select icon from unnest(array['🍕','🚀','🐱','🎸','🌵','⚽','🍩','🦊','🎈','🐙','🌙','🍉',
                                      '🎲','🦄','🍄','🐸','⭐','🍔','🎁','🐼','☕','📎','🎯','🌈']) icon
        order by md5(p_date::text || icon) limit 8) i, generate_series(1, 2) n;
$$;

create or replace function public._memory_view(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare g public.puzzle_games; lay text[] := public._memory_layout(public._today());
begin
  select * into g from public.puzzle_games where user_id = p_user and pdate = public._today() and kind = 'memory';
  return jsonb_build_object('status', coalesce(g.status, 'playing'), 'moves', coalesce((g.state->>'moves')::int, 0),
    'reward', coalesce(g.reward, 0), 'size', 16,
    'open', case when g.state->>'open' is not null then jsonb_build_object('pos', (g.state->>'open')::int, 'icon', lay[(g.state->>'open')::int + 1]) end,
    'matched', (select coalesce(jsonb_object_agg(p, lay[p::int + 1]), '{}'::jsonb) from jsonb_array_elements_text(coalesce(g.state->'matched', '[]')) p));
end $$;
revoke all on function public._memory_view(uuid) from public, anon, authenticated;

create or replace function public.memory_state() returns jsonb
language sql stable security definer set search_path = public as $$ select public._memory_view(auth.uid()) $$;

create or replace function public.memory_flip(p_pos int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid(); lay text[] := public._memory_layout(public._today()); g public.puzzle_games;
  matched jsonb; op int; moves int; res jsonb; coins int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if p_pos < 0 or p_pos > 15 then raise exception 'Ongeldig kaartje.'; end if;
  g := public._puzzle_game(me, 'memory');
  if g.status <> 'playing' then raise exception 'Je hebt de Memory van vandaag al opgelost.'; end if;
  matched := coalesce(g.state->'matched', '[]'::jsonb);
  if matched @> to_jsonb(p_pos::text) then raise exception 'Dit paar is al gevonden.'; end if;
  op := (g.state->>'open')::int; moves := coalesce((g.state->>'moves')::int, 0);
  if op is null then
    update public.puzzle_games set state = state || jsonb_build_object('open', p_pos) where user_id = me and pdate = g.pdate and kind = 'memory';
    return jsonb_build_object('pos', p_pos, 'icon', lay[p_pos + 1]);
  end if;
  if op = p_pos then raise exception 'Kies een ander kaartje.'; end if;
  moves := moves + 1;
  res := jsonb_build_object('pos', p_pos, 'icon', lay[p_pos + 1], 'other', op, 'other_icon', lay[op + 1], 'match', lay[op + 1] = lay[p_pos + 1], 'moves', moves);
  if lay[op + 1] = lay[p_pos + 1] then matched := matched || jsonb_build_array(op::text, p_pos::text); end if;
  update public.puzzle_games set state = jsonb_build_object('matched', matched, 'moves', moves)
    where user_id = me and pdate = g.pdate and kind = 'memory';
  if jsonb_array_length(matched) = 16 then
    coins := case when moves <= 10 then 40 when moves <= 14 then 30 when moves <= 18 then 20 else 10 end;
    update public.puzzle_games set status = 'won', finished_at = now(), reward = coins where user_id = me and pdate = g.pdate and kind = 'memory';
    res := res || jsonb_build_object('won', true, 'prize', public._puzzle_reward(me, 'memory', coins));
  end if;
  return res;
end $$;

-- --- Mini-sudoku 6×6 (blokjes van 2 rijen × 3 kolommen) ---
create or replace function public._sudoku_solution(p_date date) returns int[]
language plpgsql immutable as $$
declare
  rowmap int[]; colmap int[]; dig int[]; sol int[] := '{}'; r int; c int; band int[]; stack int[];
begin
  select array_agg(x order by md5(p_date::text || 'band' || x)) into band from generate_series(0, 2) x;
  select array_agg(x order by md5(p_date::text || 'stack' || x)) into stack from generate_series(0, 1) x;
  rowmap := '{}'; colmap := '{}';
  for r in 1..3 loop
    rowmap := rowmap || (select array_agg(band[r] * 2 + x order by md5(p_date::text || 'row' || r || x)) from generate_series(0, 1) x);
  end loop;
  for c in 1..2 loop
    colmap := colmap || (select array_agg(stack[c] * 3 + x order by md5(p_date::text || 'col' || c || x)) from generate_series(0, 2) x);
  end loop;
  select array_agg(x order by md5(p_date::text || 'dig' || x)) into dig from generate_series(1, 6) x;
  for r in 0..5 loop
    for c in 0..5 loop
      sol := sol || dig[(3 * (rowmap[r + 1] % 2) + rowmap[r + 1] / 2 + colmap[c + 1]) % 6 + 1];
    end loop;
  end loop;
  return sol;
end $$;

create or replace function public._sudoku_givens(p_date date) returns int[]
language sql immutable as $$
  select array_agg(case when keep then s.v else 0 end order by s.i)
  from unnest(public._sudoku_solution(p_date)) with ordinality s(v, i)
  left join lateral (select s.i in (select i from generate_series(1, 36) i order by md5(p_date::text || 'given' || i) limit 15) as keep) k on true;
$$;

create or replace function public._sudoku_view(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare g public.puzzle_games;
begin
  select * into g from public.puzzle_games where user_id = p_user and pdate = public._today() and kind = 'sudoku';
  return jsonb_build_object('givens', to_jsonb(public._sudoku_givens(public._today())),
    'status', coalesce(g.status, 'new'), 'reward', coalesce(g.reward, 0),
    'elapsed', case when g.status = 'playing' then extract(epoch from now() - g.started_at)::int else (g.state->>'seconds')::int end,
    'grid', g.state->'grid');
end $$;
revoke all on function public._sudoku_view(uuid) from public, anon, authenticated;

create or replace function public.sudoku_state() returns jsonb
language sql stable security definer set search_path = public as $$ select public._sudoku_view(auth.uid()) $$;

-- Starten zet de klok aan
create or replace function public.sudoku_start() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Niet ingelogd.'; end if;
  perform public._puzzle_game(auth.uid(), 'sudoku');
  return public._sudoku_view(auth.uid());
end $$;

create or replace function public.sudoku_submit(p_grid int[]) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); g public.puzzle_games; giv int[] := public._sudoku_givens(public._today()); k int; secs int; coins int; ok boolean;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select * into g from public.puzzle_games where user_id = me and pdate = public._today() and kind = 'sudoku' for update;
  if not found then raise exception 'Start eerst de sudoku.'; end if;
  if g.status <> 'playing' then raise exception 'Je hebt de sudoku van vandaag al opgelost.'; end if;
  if coalesce(array_length(p_grid, 1), 0) <> 36 then raise exception 'Vul alle 36 vakjes in.'; end if;
  for k in 1..36 loop
    if p_grid[k] is null or p_grid[k] not between 1 and 6 then raise exception 'Vul alle vakjes in met 1 tot 6.'; end if;
    if giv[k] <> 0 and giv[k] <> p_grid[k] then raise exception 'Een gegeven cijfer is aangepast.'; end if;
  end loop;
  -- Elke rij, kolom en elk blokje moet 1-6 precies één keer bevatten
  select bool_and(n = 6) into ok from (
    select count(distinct v) n from unnest(p_grid) with ordinality t(v, i) group by (i - 1) / 6
    union all select count(distinct v) from unnest(p_grid) with ordinality t(v, i) group by (i - 1) % 6
    union all select count(distinct v) from unnest(p_grid) with ordinality t(v, i) group by ((i - 1) / 6) / 2, ((i - 1) % 6) / 3
  ) x;
  if not ok then
    update public.puzzle_games set state = state || jsonb_build_object('fails', coalesce((state->>'fails')::int, 0) + 1)
      where user_id = me and pdate = g.pdate and kind = 'sudoku';
    return jsonb_build_object('correct', false);
  end if;
  secs := extract(epoch from now() - g.started_at)::int;
  coins := case when secs < 180 then 45 else 30 end;
  update public.puzzle_games set status = 'won', finished_at = now(), reward = coins,
    state = state || jsonb_build_object('seconds', secs, 'grid', to_jsonb(p_grid))
    where user_id = me and pdate = g.pdate and kind = 'sudoku';
  return jsonb_build_object('correct', true, 'seconds', secs, 'prize', public._puzzle_reward(me, 'sudoku', coins));
end $$;

-- Puzzelresultaten van vandaag: jij en je vrienden
create or replace function public.puzzle_board() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('user_id', g.user_id, 'name', p.display_name, 'kind', g.kind, 'status', g.status,
    'score', case g.kind when 'conn' then (g.state->>'mistakes')::int when 'memory' then (g.state->>'moves')::int else (g.state->>'seconds')::int end)
    order by g.kind, g.status = 'won' desc,
      case g.kind when 'conn' then (g.state->>'mistakes')::int when 'memory' then (g.state->>'moves')::int else (g.state->>'seconds')::int end), '[]'::jsonb)
  from public.puzzle_games g join public.profiles p on p.id = g.user_id
  where g.pdate = public._today() and g.status <> 'playing'
    and (g.user_id = auth.uid() or g.user_id in (select friend_id from public.friendships where user_id = auth.uid()));
$$;

create or replace function public.puzzle_overview() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'conn', coalesce((select status from public.puzzle_games where user_id = auth.uid() and pdate = public._today() and kind = 'conn'), 'new'),
    'memory', coalesce((select status from public.puzzle_games where user_id = auth.uid() and pdate = public._today() and kind = 'memory'), 'new'),
    'sudoku', coalesce((select status from public.puzzle_games where user_id = auth.uid() and pdate = public._today() and kind = 'sudoku'), 'new'));
$$;

-- =====================================================================
-- 9. Kantoorhuisdier: groeit als je elke dag speelt
--    Elke dag max 3 XP: een Wordle, een battle en een puzzel. Ei → baby (3) → jong (15) → volwassen (40)
-- =====================================================================
create table if not exists public.pets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  species text not null,
  variant text not null default 'normaal',
  name text not null default 'Naamloos' check (char_length(name) between 1 and 20),
  adopted_at timestamptz not null default now()
);
alter table public.pets enable row level security;
-- Bewust geen policies: de soort blijft geheim tot het ei uitkomt, lezen via pet_state()

create or replace function public._pet_species()
returns table (species text, emoji text, label text, rarity text, weight int)
language sql immutable as $$
  values ('kat','🐱','Kat','common',16), ('hond','🐶','Hond','common',16), ('konijn','🐰','Konijn','common',14),
         ('pinguin','🐧','Pinguïn','common',14), ('kikker','🐸','Kikker','common',12), ('vos','🦊','Vos','common',12),
         ('uil','🦉','Uil','rare',6), ('panda','🐼','Panda','rare',6), ('draak','🐲','Draak','epic',2), ('eenhoorn','🦄','Eenhoorn','epic',2)
$$;

-- Dagen waarop iemand iets speelde (Wordle, battle, puzzel) sinds een bepaald moment
create or replace function public._pet_xp(p_user uuid, p_since timestamptz) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(least(3, n)), 0)::int from (
    select d, count(distinct k) as n from (
      select g.round_date as d, 'w' as k from public.wordle_games g
        where g.user_id = p_user and g.status <> 'playing' and g.finished_at >= p_since
      union all
      select (b.finished_at at time zone 'Europe/Brussels')::date, 'b' from public.tbattles b
        where b.status = 'done' and (b.player_a = p_user or b.player_b = p_user) and b.finished_at >= p_since
      union all
      select p.pdate, 'p' from public.puzzle_games p
        where p.user_id = p_user and p.status = 'won' and p.finished_at >= p_since
    ) x group by d
  ) y;
$$;

create or replace function public._pet_json(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p public.pets; xp int; stage text; sp record;
begin
  select * into p from public.pets where user_id = p_user;
  if not found then return null; end if;
  xp := public._pet_xp(p_user, date_trunc('day', p.adopted_at at time zone 'Europe/Brussels') at time zone 'Europe/Brussels');
  stage := case when xp >= 40 then 'volwassen' when xp >= 15 then 'jong' when xp >= 3 then 'baby' else 'ei' end;
  select * into sp from public._pet_species() where species = p.species;
  return jsonb_build_object('name', p.name, 'xp', xp, 'stage', stage,
    'next', case stage when 'ei' then 3 when 'baby' then 15 when 'jong' then 40 end,
    'species', case when stage <> 'ei' then p.species end,
    'emoji', case when stage <> 'ei' then sp.emoji end,
    'label', case when stage <> 'ei' then sp.label end,
    'rarity', case when stage <> 'ei' then sp.rarity end,
    'variant', case when stage <> 'ei' then p.variant end,
    'adopted_at', p.adopted_at);
end $$;
revoke all on function public._pet_json(uuid) from public, anon, authenticated;

create or replace function public.pet_state() returns jsonb
language sql stable security definer set search_path = public as $$ select public._pet_json(auth.uid()) $$;

create or replace function public.adopt_pet(p_name text default 'Naamloos') returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); v_species text; r float8 := random() * 100; rr float8 := random();
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if exists (select 1 from public.pets where user_id = me) then raise exception 'Je hebt al een huisdier.'; end if;
  select species into v_species from (
    select species, sum(weight) over (order by species) as upto, sum(weight) over () as total from public._pet_species()
  ) x where upto > rr * total order by upto limit 1;
  insert into public.pets (user_id, species, variant, name)
  values (me, v_species, case when r < 1 then 'regenboog' when r < 6 then 'goud' else 'normaal' end,
          coalesce(nullif(trim(p_name), ''), 'Naamloos'));
  return public._pet_json(me);
end $$;

create or replace function public.rename_pet(p_name text) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if char_length(trim(coalesce(p_name, ''))) not between 1 and 20 then raise exception 'Kies een naam van 1 tot 20 tekens.'; end if;
  update public.pets set name = trim(p_name) where user_id = auth.uid();
end $$;

-- =====================================================================
-- 13. Prestaties: elke prestatie = polycoins + een (zeldzame) sticker + een badge op je profiel
-- =====================================================================
create or replace function public._achievements()
returns table (ach_key text, icon text, title text, descr text, target int, reward int)
language sql immutable as $$
  values
    ('wordle_10',   '🟩', 'Woordzoeker',        'Speel 10 Wordles',                              10,  50),
    ('wordle_50',   '📚', 'Woordenboek',        'Speel 50 Wordles',                              50, 150),
    ('wordle_2',    '🎯', 'Scherpschutter',     'Los een Wordle op in 2 pogingen of minder',       1,  75),
    ('cards_25',    '🎴', 'Verzamelaar',        'Verzamel 25 verschillende kaarten',             25, 100),
    ('legend_3',    '🌟', 'Legendarisch',       'Verzamel 3 verschillende legendaries',           3, 150),
    ('page_1',      '🏅', 'Pagina vol',         'Vervolledig een pagina in je boek',              1,  50),
    ('maxlvl',      '⭐', 'Opgepoetst',         'Waardeer een kaart op tot ★★★',                  1, 100),
    ('battle_10',   '⚔️', 'Vechtersbaas',       'Win 10 battles',                                10,  75),
    ('battle_50',   '🛡️', 'Veteraan',           'Win 50 battles',                                50, 200),
    ('pvp_5',       '🤝', 'Vriendschappelijk',  'Win 5 battles tegen vrienden',                   5, 100),
    ('rank_gold',   '🥇', 'Goudhaantje',        'Bereik Goud in een seizoen',                     1, 150),
    ('puzzle_10',   '🧩', 'Puzzelaar',          'Los 10 puzzels op',                             10,  75),
    ('sudoku_fast', '⏱️', 'Snelle denker',      'Los een sudoku op in minder dan 3 minuten',      1,  75),
    ('conn_perfect','🔗', 'Verbonden',          'Los Verbanden op zonder fouten',                 1,  75),
    ('bj_10',       '🃏', 'Kaartenteller',      'Win 10 keer blackjack',                         10,  75),
    ('jackpot',     '💎', 'Jackpot!',           'Draai 💎💎💎 op de fruitautomaat',                1, 200),
    ('stickers_25', '🏷️', 'Plakker',            'Verzamel 25 verschillende stickers',            25, 100),
    ('album_theme', '📒', 'Albumkampioen',      'Vervolledig een stickerthema',                   1, 100),
    ('pet_adult',   '🐾', 'Trotse baas',        'Laat je huisdier volwassen worden',              1, 100),
    ('quests_20',   '📋', 'Plichtsbewust',      'Voltooi 20 dagelijkse opdrachten',             20, 100)
$$;

create table if not exists public.achievement_claims (
  user_id uuid not null references auth.users(id) on delete cascade,
  ach_key text not null,
  claimed_at timestamptz not null default now(),
  primary key (user_id, ach_key)
);
alter table public.achievement_claims enable row level security;
drop policy if exists "prestaties lezen" on public.achievement_claims;
create policy "prestaties lezen" on public.achievement_claims for select to authenticated using (true);
grant select on public.achievement_claims to authenticated;

create or replace function public._ach_progress(p_user uuid, p_key text) returns int
language plpgsql stable security definer set search_path = public as $$
declare n int := 0;
begin
  case p_key
    when 'wordle_10', 'wordle_50' then
      select count(*) into n from public.wordle_games where user_id = p_user and status <> 'playing';
    when 'wordle_2' then
      select count(*) into n from public.wordle_games where user_id = p_user and status = 'won' and attempts <= 2;
    when 'cards_25' then
      select count(distinct u.card_id) into n from public.user_cards u join public.cards c on c.id = u.card_id where u.user_id = p_user and c.rarity <> 'cat';
    when 'legend_3' then
      select count(distinct u.card_id) into n from public.user_cards u join public.cards c on c.id = u.card_id where u.user_id = p_user and c.rarity = 'legendary';
    when 'page_1' then
      select count(*) into n from public.collection_rewards where user_id = p_user and person <> '*BOOK*';
    when 'maxlvl' then
      select count(*) into n from public.card_levels where user_id = p_user and level >= 3;
    when 'battle_10', 'battle_50' then
      select count(*) into n from public.tbattles where status = 'done'
        and ((player_a = p_user and winner = 'A') or (player_b = p_user and winner = 'B'));
    when 'pvp_5' then
      select count(*) into n from public.tbattles where status = 'done' and mode = 'pvp'
        and ((player_a = p_user and winner = 'A') or (player_b = p_user and winner = 'B'));
    when 'rank_gold' then
      select count(*) into n from public.tb_ratings where user_id = p_user and best >= 1200;
    when 'puzzle_10' then
      select count(*) into n from public.puzzle_games where user_id = p_user and status = 'won';
    when 'sudoku_fast' then
      select count(*) into n from public.puzzle_games where user_id = p_user and kind = 'sudoku' and status = 'won' and (state->>'seconds')::int < 180;
    when 'conn_perfect' then
      select count(*) into n from public.puzzle_games where user_id = p_user and kind = 'conn' and status = 'won' and coalesce((state->>'mistakes')::int, 0) = 0;
    when 'bj_10' then
      select count(*) into n from public.casino_log where user_id = p_user and game = 'blackjack' and win > bet;
    when 'jackpot' then
      select count(*) into n from public.casino_log where user_id = p_user and game = 'slots' and (detail->>'jackpot')::boolean;
    when 'stickers_25' then
      select count(*) into n from public.user_stickers where user_id = p_user;
    when 'album_theme' then
      select count(*) into n from public.sticker_theme_claims where user_id = p_user;
    when 'pet_adult' then
      select case when public._pet_json(p_user)->>'stage' = 'volwassen' then 1 else 0 end into n;
    when 'quests_20' then
      select count(*) into n from public.quest_claims where user_id = p_user;
    else n := 0;
  end case;
  return n;
end $$;
revoke all on function public._ach_progress(uuid, text) from public, anon, authenticated;

create or replace function public.achievements_state() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_agg(jsonb_build_object('key', a.ach_key, 'icon', a.icon, 'title', a.title, 'desc', a.descr,
    'target', a.target, 'reward', a.reward,
    'progress', least(a.target, public._ach_progress(auth.uid(), a.ach_key)),
    'claimed', exists (select 1 from public.achievement_claims c where c.user_id = auth.uid() and c.ach_key = a.ach_key)))
  from public._achievements() a where auth.uid() is not null;
$$;

create or replace function public.claim_achievement(p_key text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); a record; v_sticker jsonb;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select * into a from public._achievements() where ach_key = p_key;
  if not found then raise exception 'Onbekende prestatie.'; end if;
  if public._ach_progress(me, p_key) < a.target then raise exception 'Deze prestatie is nog niet behaald.'; end if;
  insert into public.achievement_claims (user_id, ach_key) values (me, p_key) on conflict do nothing;
  if not found then raise exception 'Je hebt deze beloning al opgehaald.'; end if;
  perform public._give_coins(me, a.reward, 'achievement', jsonb_build_object('key', p_key));
  v_sticker := public._give_sticker(me, 'rare');
  perform public._log_activity(me, 'achievement', jsonb_build_object('key', p_key, 'title', a.title, 'icon', a.icon));
  return jsonb_build_object('reward', a.reward, 'sticker', v_sticker,
    'wallet', (select polycoins from public.user_wallet where user_id = me));
end $$;

-- =====================================================================
-- 14. Seizoensbeloningen: na elke maand een beloning volgens je eindrang
--     Brons 25 · Zilver 50 · Goud 100 · Platina 150 · Diamant 250 polycoins + sticker
-- =====================================================================
create table if not exists public.tb_season_claims (
  user_id uuid not null references auth.users(id) on delete cascade,
  season text not null,
  primary key (user_id, season)
);
alter table public.tb_season_claims enable row level security;

create or replace function public.season_state() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('season', public._season(), 'points', coalesce(t.points, 1000), 'rank', public._rank(coalesce(t.points, 1000)),
    'wins', coalesce(t.wins, 0), 'losses', coalesce(t.losses, 0),
    'ends', (date_trunc('month', now() at time zone 'Europe/Brussels') + interval '1 month')::date)
  from (select 1) x left join public.tb_ratings t on t.user_id = auth.uid() and t.season = public._season();
$$;

create or replace function public.claim_season_rewards() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); t record; out_ jsonb := '[]'::jsonb; rk text; coins int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  for t in select * from public.tb_ratings where user_id = me and season < public._season() and wins + losses > 0 loop
    insert into public.tb_season_claims values (me, t.season) on conflict do nothing;
    if found then
      rk := public._rank(t.points);
      coins := case rk when 'diamant' then 250 when 'platina' then 150 when 'goud' then 100 when 'zilver' then 50 else 25 end;
      perform public._give_coins(me, coins, 'season', jsonb_build_object('season', t.season, 'rank', rk));
      out_ := out_ || jsonb_build_object('season', t.season, 'rank', rk, 'coins', coins,
        'sticker', public._give_sticker(me, case when rk in ('goud', 'platina', 'diamant') then 'rare' end));
    end if;
  end loop;
  return out_;
end $$;

-- =====================================================================
-- 15. Profiel: 3 favoriete kaarten, rang, prestaties, stickers, bureau en huisdier
-- =====================================================================
create or replace function public.set_showcase(p_cards int[]) returns void
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  p_cards := coalesce(p_cards, '{}');
  if coalesce(array_length(p_cards, 1), 0) > 3 then raise exception 'Kies maximaal 3 kaarten.'; end if;
  if exists (select 1 from unnest(p_cards) x where not exists (select 1 from public.user_cards u where u.user_id = me and u.card_id = x)) then
    raise exception 'Je kan enkel kaarten tonen die je hebt.';
  end if;
  update public.profiles set showcase = (
    select coalesce(array_agg(x order by o), '{}') from (
      select distinct on (x) x, o from unnest(p_cards) with ordinality t(x, o) order by x, o) d)
  where id = me;
end $$;

create or replace function public.profile_view(p_user uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); u uuid := coalesce(p_user, auth.uid()); p public.profiles;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if u <> me and not exists (select 1 from public.friendships where user_id = me and friend_id = u) then
    raise exception 'Je kan enkel profielen van vrienden bekijken.';
  end if;
  select * into p from public.profiles where id = u;
  return jsonb_build_object('id', u, 'name', p.display_name, 'avatar_url', p.avatar_url,
    'ring', p.equipped_ring, 'title', p.equipped_title,
    'season', (select jsonb_build_object('points', coalesce(t.points, 1000), 'rank', public._rank(coalesce(t.points, 1000)))
               from (select 1) x left join public.tb_ratings t on t.user_id = u and t.season = public._season()),
    'achievements', (select coalesce(jsonb_agg(jsonb_build_object('key', a.ach_key, 'icon', a.icon, 'title', a.title) order by c.claimed_at), '[]'::jsonb)
                     from public.achievement_claims c join public._achievements() a on a.ach_key = c.ach_key where c.user_id = u),
    'stickers', jsonb_build_object('have', (select count(*) from public.user_stickers where user_id = u), 'total', (select count(*) from public._stickers())),
    'cards', (select count(distinct card_id) from public.user_cards uc join public.cards c on c.id = uc.card_id where uc.user_id = u and c.rarity <> 'cat'),
    'showcase', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'rarity', c.rarity,
                   'level', coalesce((select level from public.card_levels l where l.user_id = u and l.card_id = c.id), 1)) order by x.o), '[]'::jsonb)
                 from unnest(p.showcase) with ordinality x(id, o) join public.cards c on c.id = x.id),
    'bureau', (select coalesce(jsonb_object_agg(b.slot, jsonb_build_object('key', b.item_key, 'emoji', b.emoji, 'name', b.name)), '{}'::jsonb)
               from public._bureau_items() b
               where b.item_key = coalesce(p.bureau->>b.slot, (select d.item_key from public._bureau_items() d where d.slot = b.slot and d.price = 0 limit 1))),
    'pet', public._pet_json(u));
end $$;

-- =====================================================================
-- 16. Aanpassingen aan bestaande onderdelen
-- =====================================================================
-- Opdrachten: nieuwe opdracht "Los een puzzel op"
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
    ('open_pack',         'other',  'Koop een pakje in de Shop',                             1, 15),
    ('puzzle_one',        'other',  'Los een puzzel op',                                     1, 15),
    ('puzzle_all',        'other',  'Los alle 3 de puzzels van vandaag op',                  3, 30)
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
  elsif p_key in ('puzzle_one', 'puzzle_all') then
    select count(*) into n from public.puzzle_games where user_id = p_user and pdate = p_date and status = 'won';
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

-- Wordle tijdens de geluksweek: je pakje telt alsof je 1 poging minder nodig had
create or replace function public._wordle_draw(p_user uuid, p_attempts int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  r float8 := random() * 100;
  leg float8; ep float8; v_rarity text; a int;
  v_card public.cards; v_dup boolean; v_coins int;
begin
  if p_attempts is null then
    v_rarity := 'cat';
  else
    a := least(p_attempts, 6);
    if public._week_event() = 'lucky_draw' then a := greatest(1, a - 1); end if;
    leg := (array[80, 30, 10, 3, 1, 0.5])[a];
    ep  := (array[20, 50, 35, 22, 11, 4.5])[a];
    v_rarity := case when r < leg then 'legendary' when r < leg + ep then 'epic' else 'common' end;
  end if;
  select * into v_card from public.cards where rarity = v_rarity order by random() limit 1;
  if not found then raise exception 'Geen kaarten gevonden voor zeldzaamheid %.', v_rarity; end if;
  v_dup := exists (select 1 from public.user_cards where user_id = p_user and card_id = v_card.id);
  insert into public.user_cards (user_id, card_id) values (p_user, v_card.id);
  v_coins := 0;
  if v_dup then
    v_coins := case v_rarity when 'common' then 10 when 'epic' then 25 when 'legendary' then 60 else 5 end;
    insert into public.user_wallet (user_id, polycoins) values (p_user, v_coins)
      on conflict (user_id) do update set polycoins = public.user_wallet.polycoins + excluded.polycoins;
  end if;
  return jsonb_build_object('card', to_jsonb(v_card), 'dup', v_dup, 'coins', v_coins);
end $$;
revoke all on function public._wordle_draw(uuid, int) from public, anon, authenticated;

-- =====================================================================
-- 17. Rechten
-- =====================================================================
do $$
declare f text;
begin
  foreach f in array array[
    'public.sticker_catalog()', 'public.buy_sticker_pack()', 'public.claim_sticker_rewards()',
    'public.bureau_state()', 'public.buy_bureau_item(text)', 'public.equip_bureau_item(text)',
    'public.casino_wheel_state()', 'public.casino_spin()', 'public.casino_slots(int)', 'public.casino_scratch()',
    'public.bj_state()', 'public.bj_start(int)', 'public.bj_action(text)',
    'public.conn_state()', 'public.conn_guess(text[])', 'public.memory_state()', 'public.memory_flip(int)',
    'public.sudoku_state()', 'public.sudoku_start()', 'public.sudoku_submit(int[])', 'public.puzzle_board()', 'public.puzzle_overview()',
    'public.pet_state()', 'public.adopt_pet(text)', 'public.rename_pet(text)',
    'public.achievements_state()', 'public.claim_achievement(text)',
    'public.season_state()', 'public.claim_season_rewards()',
    'public.set_showcase(int[])', 'public.profile_view(uuid)'] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end $$;
-- Interne hulpfuncties zijn niet rechtstreeks aan te roepen
do $$
declare f text;
begin
  foreach f in array array[
    'public._bj_value(int[])', 'public._memory_layout(date)', 'public._sudoku_solution(date)', 'public._sudoku_givens(date)',
    'public._conn_view(uuid)', 'public._memory_view(uuid)', 'public._sudoku_view(uuid)', 'public._pet_xp(uuid, timestamptz)',
    'public._tb_ai(jsonb, text, text, int)', 'public._tb_eff(text, text)', 'public._tb_ab_cost(jsonb, text, int)',
    'public._tb_n(jsonb, text, text, int)', 'public._tb_set(jsonb, text, text, int, int)', 'public._person_type(text)'] loop
    execute 'revoke all on function ' || f || ' from public, anon, authenticated';
  end loop;
end $$;
