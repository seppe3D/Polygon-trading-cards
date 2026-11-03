-- Polygon Trading Cards — uitbreiding v17: 3 nieuwe kaarten per collega
-- Per collega: slot 10 = common, slot 11 = epic, slot 12 = legendary (afbeeldingen cards/naam-10.jpg t/m -12.jpg)
-- Voer dit volledige bestand in één keer uit in Supabase SQL Editor. Kies "Run without RLS". Veilig om opnieuw uit te voeren.
-- De stats (HP/ATK/DEF) zijn dezelfde als die van de bestaande kaarten van dezelfde zeldzaamheid.

with nieuw(p, slot, rarity, name, flavor, sp_name, sp_desc, img) as (values
  ('marvin', 10, 'common', 'Window to Elsewhere', 'Staring out of the window. Professionally.', null, null, 'cards/marvin-10.jpg'),
  ('marvin', 11, 'epic', 'Stitching the World', 'Hold still, planet. Almost done.', null, null, 'cards/marvin-11.jpg'),
  ('marvin', 12, 'legendary', 'King of the Segment', 'If it''s not on the app, it didn''t happen.', 'Kudos Avalanche', 'Sprints up the glowing trail to the crown and buries every opponent under an avalanche of kudos.', 'cards/marvin-12.jpg'),
  ('steffi', 10, 'common', 'Head Elf on Duty', 'Wrapping is a competitive sport.', null, null, 'cards/steffi-10.jpg'),
  ('steffi', 11, 'epic', 'Midnight Kitchen Magic', 'A pinch of stardust, a dash of chaos.', null, null, 'cards/steffi-11.jpg'),
  ('steffi', 12, 'legendary', 'Queen of London Town', 'Tea at four. Adventure at five.', 'Double-Decker Dash', 'Charges through the sky on a flying double-decker bus and bowls over every opponent.', 'cards/steffi-12.jpg'),
  ('ale', 10, 'common', 'Whale Dentist', 'Brush twice a day. Even the big ones.', null, null, 'cards/ale-10.jpg'),
  ('ale', 11, 'epic', 'Ink of the Deep', 'He writes his stories on a whale''s back.', null, null, 'cards/ale-11.jpg'),
  ('ale', 12, 'legendary', 'The Soda Alchemist', 'Shaken, not stirred. Then it exploded.', 'Fizzy Big Bang', 'Uncorks a rainbow soda explosion that fizzes every opponent right off the battlefield.', 'cards/ale-12.jpg'),
  ('lana', 10, 'common', 'Birdsong Walk', 'Every bird in the forest knows her name.', null, null, 'cards/lana-10.jpg'),
  ('lana', 11, 'epic', 'Forest Palette', 'She paints. The forest blooms.', null, null, 'cards/lana-11.jpg'),
  ('lana', 12, 'legendary', 'Walking out of the Story', 'The best adventures start on page one.', 'Pop-Up Odyssey', 'Opens a giant pop-up book and drops a whole mountain range of waterfalls on every opponent.', 'cards/lana-12.jpg'),
  ('odo', 10, 'common', 'Suitcase Express', 'Late? He took the scenic sky.', null, null, 'cards/odo-10.jpg'),
  ('odo', 11, 'epic', 'The Cat Collector', 'One more page. One more cat.', null, null, 'cards/odo-11.jpg'),
  ('odo', 12, 'legendary', 'Sleeping on a Fortune', 'Money doesn''t grow on trees. Except this one.', 'Golden Payday', 'Shakes the money tree and rains a fortune of gold coins down on every opponent.', 'cards/odo-12.jpg'),
  ('sarah', 10, 'common', 'Ghost of the Archives', 'She knows where every file is buried.', null, null, 'cards/sarah-10.jpg'),
  ('sarah', 11, 'epic', 'Night Flight over the Canals', 'Paper boats light her way home.', null, null, 'cards/sarah-11.jpg'),
  ('sarah', 12, 'legendary', 'Guardian of the Skyline', 'The city sleeps. She keeps watch.', 'Moonlit Glide', 'Sweeps over the rooftops in a wave of moonlight that dazzles every opponent.', 'cards/sarah-12.jpg'),
  ('seppe', 10, 'common', 'Robot Romance', 'She said yes. In binary.', null, null, 'cards/seppe-10.jpg'),
  ('seppe', 11, 'epic', 'Five-Letter Wizard', 'Green, green, green, green… green!', null, null, 'cards/seppe-11.jpg'),
  ('seppe', 12, 'legendary', 'Master of All Games', 'Sudoku, poker or tarot: he wins them all.', 'Full House', 'Deals a perfect hand of glowing cards that hits every opponent at once.', 'cards/seppe-12.jpg')
), basis as (
  -- de echte naam van de collega zoals hij in de database staat, en de stats per zeldzaamheid
  select distinct on (lower(c.person), c.rarity) lower(c.person) as p, c.person, c.rarity, c.hp, c.attack, c.defense, c.special_power
  from public.cards c
  where c.rarity in ('common', 'epic', 'legendary')
  order by lower(c.person), c.rarity, c.slot
)
insert into public.cards (person, slot, name, rarity, hp, attack, defense, image_url, flavor_text, special_name, special_desc, special_power)
select b.person, n.slot, n.name, n.rarity, b.hp, b.attack, b.defense, n.img, n.flavor, n.sp_name, n.sp_desc,
       case when n.rarity = 'legendary' then coalesce(b.special_power, 80) end
from nieuw n join basis b on b.p = n.p and b.rarity = n.rarity
where not exists (select 1 from public.cards c where lower(c.person) = n.p and c.slot = n.slot);

-- Tekst of afbeelding aangepast? Bij opnieuw uitvoeren worden die bijgewerkt
update public.cards c set name = n.name, flavor_text = n.flavor, special_name = n.sp_name, special_desc = n.sp_desc, image_url = n.img
from (values
  ('marvin', 10, 'common', 'Window to Elsewhere', 'Staring out of the window. Professionally.', null, null, 'cards/marvin-10.jpg'),
  ('marvin', 11, 'epic', 'Stitching the World', 'Hold still, planet. Almost done.', null, null, 'cards/marvin-11.jpg'),
  ('marvin', 12, 'legendary', 'King of the Segment', 'If it''s not on the app, it didn''t happen.', 'Kudos Avalanche', 'Sprints up the glowing trail to the crown and buries every opponent under an avalanche of kudos.', 'cards/marvin-12.jpg'),
  ('steffi', 10, 'common', 'Head Elf on Duty', 'Wrapping is a competitive sport.', null, null, 'cards/steffi-10.jpg'),
  ('steffi', 11, 'epic', 'Midnight Kitchen Magic', 'A pinch of stardust, a dash of chaos.', null, null, 'cards/steffi-11.jpg'),
  ('steffi', 12, 'legendary', 'Queen of London Town', 'Tea at four. Adventure at five.', 'Double-Decker Dash', 'Charges through the sky on a flying double-decker bus and bowls over every opponent.', 'cards/steffi-12.jpg'),
  ('ale', 10, 'common', 'Whale Dentist', 'Brush twice a day. Even the big ones.', null, null, 'cards/ale-10.jpg'),
  ('ale', 11, 'epic', 'Ink of the Deep', 'He writes his stories on a whale''s back.', null, null, 'cards/ale-11.jpg'),
  ('ale', 12, 'legendary', 'The Soda Alchemist', 'Shaken, not stirred. Then it exploded.', 'Fizzy Big Bang', 'Uncorks a rainbow soda explosion that fizzes every opponent right off the battlefield.', 'cards/ale-12.jpg'),
  ('lana', 10, 'common', 'Birdsong Walk', 'Every bird in the forest knows her name.', null, null, 'cards/lana-10.jpg'),
  ('lana', 11, 'epic', 'Forest Palette', 'She paints. The forest blooms.', null, null, 'cards/lana-11.jpg'),
  ('lana', 12, 'legendary', 'Walking out of the Story', 'The best adventures start on page one.', 'Pop-Up Odyssey', 'Opens a giant pop-up book and drops a whole mountain range of waterfalls on every opponent.', 'cards/lana-12.jpg'),
  ('odo', 10, 'common', 'Suitcase Express', 'Late? He took the scenic sky.', null, null, 'cards/odo-10.jpg'),
  ('odo', 11, 'epic', 'The Cat Collector', 'One more page. One more cat.', null, null, 'cards/odo-11.jpg'),
  ('odo', 12, 'legendary', 'Sleeping on a Fortune', 'Money doesn''t grow on trees. Except this one.', 'Golden Payday', 'Shakes the money tree and rains a fortune of gold coins down on every opponent.', 'cards/odo-12.jpg'),
  ('sarah', 10, 'common', 'Ghost of the Archives', 'She knows where every file is buried.', null, null, 'cards/sarah-10.jpg'),
  ('sarah', 11, 'epic', 'Night Flight over the Canals', 'Paper boats light her way home.', null, null, 'cards/sarah-11.jpg'),
  ('sarah', 12, 'legendary', 'Guardian of the Skyline', 'The city sleeps. She keeps watch.', 'Moonlit Glide', 'Sweeps over the rooftops in a wave of moonlight that dazzles every opponent.', 'cards/sarah-12.jpg'),
  ('seppe', 10, 'common', 'Robot Romance', 'She said yes. In binary.', null, null, 'cards/seppe-10.jpg'),
  ('seppe', 11, 'epic', 'Five-Letter Wizard', 'Green, green, green, green… green!', null, null, 'cards/seppe-11.jpg'),
  ('seppe', 12, 'legendary', 'Master of All Games', 'Sudoku, poker or tarot: he wins them all.', 'Full House', 'Deals a perfect hand of glowing cards that hits every opponent at once.', 'cards/seppe-12.jpg')
) n(p, slot, rarity, name, flavor, sp_name, sp_desc, img)
where lower(c.person) = n.p and c.slot = n.slot;

-- Controle: 3 nieuwe kaarten per collega
select person, slot, rarity, name from public.cards where slot between 10 and 12 order by person, slot;
