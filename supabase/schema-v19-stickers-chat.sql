-- Polygon Trading Cards — uitbreiding v19: stickers op kaarten, prikbord en chat
-- Voer dit volledige bestand in één keer uit in Supabase SQL Editor (ná v13). Kies "Run without RLS". Veilig om opnieuw uit te voeren.
--
-- Stickers die je plakt of verstuurt, blijven gewoon in je album: je moet ze enkel hebben.

-- =====================================================================
-- 1. Sticker op een kaart (max 1 per kaart)
-- =====================================================================
create table if not exists public.card_stickers (
  user_id uuid not null references auth.users(id) on delete cascade,
  card_id int not null references public.cards(id) on delete cascade,
  sticker_key text not null,
  primary key (user_id, card_id)
);
alter table public.card_stickers enable row level security;
drop policy if exists "kaartstickers lezen" on public.card_stickers;
create policy "kaartstickers lezen" on public.card_stickers for select to authenticated using (true);
grant select on public.card_stickers to authenticated;
revoke insert, update, delete on public.card_stickers from anon, authenticated;

create or replace function public._sticker_json(p_key text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('key', s.sticker_key, 'emoji', s.emoji, 'name', s.name, 'rarity', s.rarity, 'anim', s.anim)
  from public._stickers() s where s.sticker_key = p_key;
$$;

create or replace function public.set_card_sticker(p_card_id int, p_sticker text default null) returns void
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if p_sticker is null then
    delete from public.card_stickers where user_id = me and card_id = p_card_id;
    return;
  end if;
  if not exists (select 1 from public.user_cards where user_id = me and card_id = p_card_id) then
    raise exception 'Je kan enkel stickers plakken op je eigen kaarten.';
  end if;
  if not exists (select 1 from public.user_stickers where user_id = me and sticker_key = p_sticker and count > 0) then
    raise exception 'Je hebt deze sticker niet.';
  end if;
  insert into public.card_stickers values (me, p_card_id, p_sticker)
    on conflict (user_id, card_id) do update set sticker_key = excluded.sticker_key;
end $$;

-- =====================================================================
-- 2. Prikbord op je bureau (max 6 stickers)
-- =====================================================================
alter table public.profiles add column if not exists board text[] not null default '{}';

create or replace function public.set_board(p_stickers text[]) returns void
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  p_stickers := coalesce(p_stickers, '{}');
  if coalesce(array_length(p_stickers, 1), 0) > 6 then raise exception 'Er passen maximaal 6 stickers op je prikbord.'; end if;
  if exists (select 1 from unnest(p_stickers) k
             where not exists (select 1 from public.user_stickers u where u.user_id = me and u.sticker_key = k and u.count > 0)) then
    raise exception 'Je kan enkel stickers ophangen die je hebt.';
  end if;
  update public.profiles set board = p_stickers where id = me;
end $$;

-- Profiel: nu ook met prikbord en de stickers op je favoriete kaarten
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
                   'level', coalesce((select level from public.card_levels l where l.user_id = u and l.card_id = c.id), 1),
                   'sticker', (select public._sticker_json(cs.sticker_key) from public.card_stickers cs where cs.user_id = u and cs.card_id = c.id)) order by x.o), '[]'::jsonb)
                 from unnest(p.showcase) with ordinality x(id, o) join public.cards c on c.id = x.id),
    'board', (select coalesce(jsonb_agg(public._sticker_json(k) order by o), '[]'::jsonb) from unnest(p.board) with ordinality b(k, o)),
    'bureau', (select coalesce(jsonb_object_agg(b.slot, jsonb_build_object('key', b.item_key, 'emoji', b.emoji, 'name', b.name)), '{}'::jsonb)
               from public._bureau_items() b
               where b.item_key = coalesce(p.bureau->>b.slot, (select d.item_key from public._bureau_items() d where d.slot = b.slot and d.price = 0 limit 1))),
    'pet', public._pet_json(u));
end $$;

-- =====================================================================
-- 3. Chat: privé met vrienden + een groepschat "Iedereen"
-- =====================================================================
create table if not exists public.chat_messages (
  id bigserial primary key,
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid references auth.users(id) on delete cascade,   -- null = groepschat
  body text check (body is null or char_length(body) between 1 and 500),
  sticker_key text,
  created_at timestamptz not null default now(),
  check (body is not null or sticker_key is not null)
);
create index if not exists chat_dm_idx on public.chat_messages (least(sender_id, recipient_id), greatest(sender_id, recipient_id), id desc);
create index if not exists chat_group_idx on public.chat_messages (id desc) where recipient_id is null;
alter table public.chat_messages enable row level security;
drop policy if exists "chat lezen" on public.chat_messages;
create policy "chat lezen" on public.chat_messages for select to authenticated
  using (recipient_id is null or sender_id = auth.uid() or recipient_id = auth.uid());
grant select on public.chat_messages to authenticated;
revoke insert, update, delete on public.chat_messages from anon, authenticated;

create table if not exists public.chat_reactions (
  message_id bigint not null references public.chat_messages(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  emoji text not null,
  primary key (message_id, user_id)
);
alter table public.chat_reactions enable row level security;
-- Bewust geen policies: lezen via de chatfuncties

-- Tot waar heb je een gesprek gelezen? (convo = 'all' of de id van de vriend)
create table if not exists public.chat_reads (
  user_id uuid not null references auth.users(id) on delete cascade,
  convo text not null,
  last_read bigint not null default 0,
  primary key (user_id, convo)
);
alter table public.chat_reads enable row level security;

-- Live meelezen via Supabase Realtime (de site werkt ook zonder, dan vernieuwt ze elke paar seconden)
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'chat_messages') then
    execute 'alter publication supabase_realtime add table public.chat_messages';
  end if;
end $$;

create or replace function public._chat_msg_json(m public.chat_messages) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', m.id, 'sender', m.sender_id, 'body', m.body, 'at', m.created_at,
    'sticker', case when m.sticker_key is not null then public._sticker_json(m.sticker_key) end,
    'name', p.display_name, 'avatar_url', p.avatar_url, 'ring', p.equipped_ring,
    'reactions', (select coalesce(jsonb_object_agg(emoji, jsonb_build_object('n', n, 'mine', mine)), '{}'::jsonb) from (
        select emoji, count(*) as n, bool_or(user_id = auth.uid()) as mine from public.chat_reactions r where r.message_id = m.id group by emoji) x))
  from public.profiles p where p.id = m.sender_id;
$$;

-- Overzicht: groepschat + vrienden met laatste bericht en aantal ongelezen
create or replace function public.chat_overview() returns jsonb
language sql stable security definer set search_path = public as $$
  with me as (select auth.uid() as id),
  fr as (
    select f.friend_id as id from public.friendships f, me where f.user_id = me.id
  ),
  last_dm as (
    select distinct on (fr.id) fr.id as friend, m.*
    from fr join public.chat_messages m
      on (m.sender_id = fr.id and m.recipient_id = (select id from me)) or (m.sender_id = (select id from me) and m.recipient_id = fr.id)
    order by fr.id, m.id desc
  )
  select jsonb_build_object(
    'group', jsonb_build_object(
      'last', (select public._chat_msg_json(m) from public.chat_messages m where m.recipient_id is null order by m.id desc limit 1),
      'unread', (select count(*) from public.chat_messages m where m.recipient_id is null and m.sender_id <> (select id from me)
                   and m.id > coalesce((select last_read from public.chat_reads r where r.user_id = (select id from me) and r.convo = 'all'), 0))),
    'friends', (select coalesce(jsonb_agg(x order by x->>'last_at' desc nulls last, x->>'name'), '[]'::jsonb) from (
       select jsonb_build_object('id', fr.id, 'name', p.display_name, 'avatar_url', p.avatar_url, 'ring', p.equipped_ring, 'title', p.equipped_title,
         'last', case when l.id is not null then jsonb_build_object('body', l.body, 'sticker', l.sticker_key is not null, 'mine', l.sender_id = (select id from me)) end,
         'last_at', l.created_at,
         'unread', (select count(*) from public.chat_messages m where m.sender_id = fr.id and m.recipient_id = (select id from me)
                      and m.id > coalesce((select last_read from public.chat_reads r where r.user_id = (select id from me) and r.convo = fr.id::text), 0))) as x
       from fr join public.profiles p on p.id = fr.id left join last_dm l on l.friend = fr.id) y),
    'read_by_friend', (select coalesce(jsonb_object_agg(r.user_id, r.last_read), '{}'::jsonb) from public.chat_reads r
                       where r.convo = (select id from me)::text and r.user_id in (select id from fr)))
  where auth.uid() is not null;
$$;

create or replace function public.chat_unread() returns int
language sql stable security definer set search_path = public as $$
  select ((public.chat_overview()->'group'->>'unread')::int
        + coalesce((select sum((f->>'unread')::int) from jsonb_array_elements(public.chat_overview()->'friends') f), 0))::int;
$$;

-- Berichten van een gesprek (p_with null = groepschat); markeert ze als gelezen
create or replace function public.chat_messages_list(p_with uuid default null, p_after bigint default 0) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); out_ jsonb; mx bigint; v_convo text := coalesce(p_with::text, 'all');
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if p_with is not null and not exists (select 1 from public.friendships where user_id = me and friend_id = p_with) then
    raise exception 'Je kan enkel chatten met vrienden.';
  end if;
  select coalesce(jsonb_agg(public._chat_msg_json(m) order by m.id), '[]'::jsonb), max(m.id) into out_, mx from (
    select * from public.chat_messages m
    where m.id > coalesce(p_after, 0)
      and case when p_with is null then m.recipient_id is null
               else (m.sender_id = me and m.recipient_id = p_with) or (m.sender_id = p_with and m.recipient_id = me) end
    order by m.id desc limit 60) m;
  if mx is not null then
    insert into public.chat_reads (user_id, convo, last_read) values (me, v_convo, mx)
      on conflict (user_id, convo) do update set last_read = greatest(public.chat_reads.last_read, excluded.last_read);
  end if;
  return jsonb_build_object('messages', out_,
    'read_upto', case when p_with is not null then (select last_read from public.chat_reads where user_id = p_with and convo = me::text) end);
end $$;

-- Reacties van de laatste berichten opnieuw ophalen (voor live bijwerken)
create or replace function public.chat_reactions_for(p_ids bigint[]) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(m.id, public._chat_msg_json(m)->'reactions'), '{}'::jsonb)
  from public.chat_messages m
  where m.id = any(p_ids) and (m.recipient_id is null or m.sender_id = auth.uid() or m.recipient_id = auth.uid());
$$;

create or replace function public.chat_send(p_to uuid default null, p_body text default null, p_sticker text default null) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); m public.chat_messages;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  p_body := nullif(trim(p_body), '');
  if p_body is null and p_sticker is null then raise exception 'Leeg bericht.'; end if;
  if char_length(p_body) > 500 then raise exception 'Max 500 tekens.'; end if;
  if p_to is not null and not exists (select 1 from public.friendships where user_id = me and friend_id = p_to) then
    raise exception 'Je kan enkel chatten met vrienden.';
  end if;
  if p_sticker is not null and not exists (select 1 from public.user_stickers where user_id = me and sticker_key = p_sticker and count > 0) then
    raise exception 'Je hebt deze sticker niet.';
  end if;
  if (select count(*) from public.chat_messages where sender_id = me and created_at > now() - interval '1 minute') >= 20 then
    raise exception 'Rustig aan! Max 20 berichten per minuut.';
  end if;
  insert into public.chat_messages (sender_id, recipient_id, body, sticker_key) values (me, p_to, p_body, p_sticker) returning * into m;
  insert into public.chat_reads (user_id, convo, last_read) values (me, coalesce(p_to::text, 'all'), m.id)
    on conflict (user_id, convo) do update set last_read = greatest(public.chat_reads.last_read, excluded.last_read);
  return public._chat_msg_json(m);
end $$;

create or replace function public.chat_react(p_id bigint, p_emoji text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); m public.chat_messages;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if p_emoji not in ('❤️', '😂', '😮', '👍', '🔥', '😢') then raise exception 'Onbekende reactie.'; end if;
  select * into m from public.chat_messages where id = p_id;
  if not found or not (m.recipient_id is null or m.sender_id = me or m.recipient_id = me) then raise exception 'Bericht niet gevonden.'; end if;
  if exists (select 1 from public.chat_reactions where message_id = p_id and user_id = me and emoji = p_emoji) then
    delete from public.chat_reactions where message_id = p_id and user_id = me;
  else
    insert into public.chat_reactions values (p_id, me, p_emoji) on conflict (message_id, user_id) do update set emoji = excluded.emoji;
  end if;
  return public._chat_msg_json(m)->'reactions';
end $$;

-- Eigen bericht verwijderen (admins mogen ook berichten in de groepschat verwijderen)
create or replace function public.chat_delete(p_id bigint) returns void
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  delete from public.chat_messages
  where id = p_id and (sender_id = me or (recipient_id is null and public.is_admin()));
  if not found then raise exception 'Je kan dit bericht niet verwijderen.'; end if;
end $$;

do $$
declare f text;
begin
  foreach f in array array['public.set_card_sticker(int, text)', 'public.set_board(text[])', 'public.chat_overview()', 'public.chat_unread()',
    'public.chat_messages_list(uuid, bigint)', 'public.chat_reactions_for(bigint[])', 'public.chat_send(uuid, text, text)',
    'public.chat_react(bigint, text)', 'public.chat_delete(bigint)', 'public.profile_view(uuid)'] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
  foreach f in array array['public._sticker_json(text)', 'public._chat_msg_json(public.chat_messages)'] loop
    execute 'revoke all on function ' || f || ' from public, anon, authenticated';
  end loop;
end $$;
