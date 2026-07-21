-- Hilo remote multiplayer: Crown Wheel over the network
-- Run this once in the Supabase SQL editor, AFTER supabase/setup.sql has already been run.
-- Purely additive — does not touch solo_scores or submit_solo_score.
--
-- One manual dashboard step is also required before this works end to end:
-- Authentication -> Sign In / Providers -> enable "Anonymous Sign-ins".
-- Without it, players have no auth.uid() and every RPC below will reject them.

-- ============================================================
-- Content tables (public read-only, same posture as solo_scores)
-- ============================================================

create table if not exists public.wheel_categories (
  key text primary key,
  label text not null,
  sort_order int not null,
  color text not null
);
alter table public.wheel_categories enable row level security;
drop policy if exists "Categories are readable" on public.wheel_categories;
create policy "Categories are readable" on public.wheel_categories
  for select to anon, authenticated using (true);
revoke insert, update, delete on public.wheel_categories from anon, authenticated;

create table if not exists public.facts (
  id bigint generated always as identity primary key,
  category text not null references public.wheel_categories(key),
  topic text not null,
  type text not null,
  item_a jsonb not null,
  item_b jsonb not null,
  is_crown_challenge boolean not null default false,
  active boolean not null default true
);
create index if not exists facts_category_idx on public.facts (category) where active;
alter table public.facts enable row level security;
-- Deliberately no select policy: facts hold the answer values, so the client never reads this
-- table directly (that would let anyone bypass spin_wheel's redaction and read the target
-- value before answering). Every legitimate read goes through a security-definer RPC that
-- redacts appropriately (spin_wheel, get_open_turn). RLS with zero policies denies all access.
revoke all on public.facts from anon, authenticated;

-- ============================================================
-- Match state tables (participant-only read; all writes go through RPCs below)
-- ============================================================

create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  match_code text unique not null,
  status text not null default 'pending' check (status in ('pending','active','completed','abandoned')),
  player1_id uuid not null references auth.users(id),
  player2_id uuid references auth.users(id),
  player1_name text not null,
  player2_name text,
  player1_score int not null default 0,
  player2_score int not null default 0,
  turn_player_id uuid references auth.users(id),
  winner_id uuid references auth.users(id),
  created_at timestamptz not null default now(),
  last_activity_at timestamptz not null default now()
);
create index if not exists matches_player1_idx on public.matches (player1_id);
create index if not exists matches_player2_idx on public.matches (player2_id);
alter table public.matches enable row level security;
drop policy if exists "Participants can read their matches" on public.matches;
create policy "Participants can read their matches" on public.matches
  for select to authenticated
  using (auth.uid() = player1_id or auth.uid() = player2_id);
revoke insert, update, delete on public.matches from anon, authenticated;

create table if not exists public.match_crowns (
  match_id uuid not null references public.matches(id) on delete cascade,
  category_key text not null references public.wheel_categories(key),
  won_by uuid not null references auth.users(id),
  won_at timestamptz not null default now(),
  primary key (match_id, category_key)
);
alter table public.match_crowns enable row level security;
drop policy if exists "Participants can read match crowns" on public.match_crowns;
create policy "Participants can read match crowns" on public.match_crowns
  for select to authenticated
  using (exists (
    select 1 from public.matches m
    where m.id = match_id and (m.player1_id = auth.uid() or m.player2_id = auth.uid())
  ));
revoke insert, update, delete on public.match_crowns from anon, authenticated;

create table if not exists public.match_turns (
  id bigint generated always as identity primary key,
  match_id uuid not null references public.matches(id) on delete cascade,
  turn_no int not null,
  player_id uuid not null references auth.users(id),
  category_key text not null references public.wheel_categories(key),
  fact_id bigint not null references public.facts(id),
  known_is_a boolean not null,
  is_crown_attempt boolean not null default false,
  used_double boolean not null default false,
  used_extra_time boolean not null default false,
  used_hint boolean not null default false,
  guess text check (guess in ('higher','lower')),
  correct boolean,
  points_earned int not null default 0,
  elapsed_ms int,
  answered_at timestamptz,
  created_at timestamptz not null default now(),
  unique (match_id, turn_no)
);
create index if not exists match_turns_match_idx on public.match_turns (match_id);
alter table public.match_turns enable row level security;
drop policy if exists "Participants can read match turns" on public.match_turns;
create policy "Participants can read match turns" on public.match_turns
  for select to authenticated
  using (exists (
    select 1 from public.matches m
    where m.id = match_id and (m.player1_id = auth.uid() or m.player2_id = auth.uid())
  ));
revoke insert, update, delete on public.match_turns from anon, authenticated;

-- ============================================================
-- Content seed data — mirrors the client-side Crown Wheel categories/facts
-- ============================================================

-- Wheel categories
insert into public.wheel_categories (key,label,sort_order,color) values
  ('size','Size & Scale',0,'#38bdf8'),
  ('distance','Distance',1,'#fb923c'),
  ('speed','Speed',2,'#f472b6'),
  ('counting','Counting',3,'#4ade80'),
  ('weight','Weight',4,'#facc15'),
  ('time','Time & Age',5,'#8b5cf6'),
  ('heat','Heat',6,'#ff5776'),
  ('sound','Sound & Food',7,'#22d3ee')
on conflict (key) do nothing;

-- Facts (mirrors the client-side FACTS array, tagged by category)
insert into public.facts (category,topic,type,item_a,item_b,is_crown_challenge) values
  ('size','Landmark height','taller','{"name":"Eiffel Tower","phrase":"the Eiffel Tower","value":330,"display":"330","unit":"meters"}'::jsonb,'{"name":"Empire State Building","phrase":"the Empire State Building","value":381,"display":"381","unit":"meters to roof"}'::jsonb,true::boolean),
  ('size','Mountain height','taller','{"name":"Mount Everest","phrase":"Mount Everest","value":8849,"display":"8,849","unit":"meters"}'::jsonb,'{"name":"K2","phrase":"K2","value":8611,"display":"8,611","unit":"meters"}'::jsonb,false::boolean),
  ('size','Worlds in space','wider','{"name":"The Moon","phrase":"the Moon","value":3475,"display":"3,475","unit":"km wide"}'::jsonb,'{"name":"Mercury","phrase":"Mercury","value":4879,"display":"4,879","unit":"km wide"}'::jsonb,false::boolean),
  ('size','Ocean area','area','{"name":"Pacific Ocean","phrase":"the Pacific Ocean","value":165.2,"display":"165.2M","unit":"square km"}'::jsonb,'{"name":"Atlantic Ocean","phrase":"the Atlantic Ocean","value":106.5,"display":"106.5M","unit":"square km"}'::jsonb,false::boolean),
  ('counting','Bones vs keys','count','{"name":"Adult human skeleton","phrase":"an adult human skeleton","value":206,"display":"206","unit":"bones"}'::jsonb,'{"name":"Piano","phrase":"a piano","value":88,"display":"88","unit":"keys"}'::jsonb,true::boolean),
  ('counting','Cards vs squares','count','{"name":"Standard card deck","phrase":"a standard card deck","value":52,"display":"52","unit":"cards"}'::jsonb,'{"name":"Chessboard","phrase":"a chessboard","value":64,"display":"64","unit":"squares"}'::jsonb,false::boolean),
  ('distance','Field length','longer','{"name":"Soccer pitch","phrase":"a soccer pitch","value":105,"display":"105","unit":"meters"}'::jsonb,'{"name":"Football field","phrase":"an American football field","value":109.7,"display":"109.7","unit":"meters incl. end zones"}'::jsonb,false::boolean),
  ('speed','Top speed','faster','{"name":"Cheetah","phrase":"a cheetah","value":120,"display":"120","unit":"km/h"}'::jsonb,'{"name":"Greyhound","phrase":"a greyhound","value":72,"display":"72","unit":"km/h"}'::jsonb,false::boolean),
  ('distance','Unexpected length','longer','{"name":"Blue whale","phrase":"a blue whale","value":30,"display":"30","unit":"meters"}'::jsonb,'{"name":"Basketball court","phrase":"a basketball court","value":28.65,"display":"28.65","unit":"meters"}'::jsonb,false::boolean),
  ('distance','Distance','longer','{"name":"Marathon","phrase":"a marathon","value":42.195,"display":"42.2","unit":"km"}'::jsonb,'{"name":"English Channel","phrase":"the English Channel crossing","value":33.3,"display":"33.3","unit":"km at narrowest"}'::jsonb,false::boolean),
  ('size','Sports height','higher','{"name":"NBA hoop","phrase":"an NBA hoop","value":3.05,"display":"3.05","unit":"meters"}'::jsonb,'{"name":"Men’s volleyball net","phrase":"a men’s volleyball net","value":2.43,"display":"2.43","unit":"meters"}'::jsonb,false::boolean),
  ('distance','Epic distance','longer','{"name":"Great Wall","phrase":"the Great Wall","value":21196,"display":"21,196","unit":"km total"}'::jsonb,'{"name":"Earth’s diameter","phrase":"Earth’s diameter","value":12742,"display":"12,742","unit":"km"}'::jsonb,false::boolean),
  ('distance','Space distance','distance','{"name":"Earth to Moon","phrase":"the Earth-to-Moon trip","value":384400,"display":"384,400","unit":"km average"}'::jsonb,'{"name":"Around the Earth","phrase":"one trip around Earth","value":40075,"display":"40,075","unit":"km"}'::jsonb,true::boolean),
  ('time','Length of a year','duration','{"name":"Year on Mercury","phrase":"a year on Mercury","value":88,"display":"88","unit":"Earth days"}'::jsonb,'{"name":"Year on Mars","phrase":"a year on Mars","value":687,"display":"687","unit":"Earth days"}'::jsonb,false::boolean),
  ('time','Pregnancy length','duration','{"name":"Camel pregnancy","phrase":"a camel pregnancy","value":13,"display":"13","unit":"months"}'::jsonb,'{"name":"Elephant pregnancy","phrase":"an elephant pregnancy","value":22,"display":"22","unit":"months"}'::jsonb,false::boolean),
  ('heat','Melting point','temperature','{"name":"Gold","phrase":"gold","value":1064,"display":"1,064°","unit":"Celsius"}'::jsonb,'{"name":"Iron","phrase":"iron","value":1538,"display":"1,538°","unit":"Celsius"}'::jsonb,false::boolean),
  ('size','Tower height','taller','{"name":"Statue of Liberty","phrase":"the Statue of Liberty","value":93,"display":"93","unit":"meters, ground to torch"}'::jsonb,'{"name":"Big Ben tower","phrase":"Big Ben’s tower","value":96,"display":"96","unit":"meters"}'::jsonb,false::boolean),
  ('time','Times per day','frequency','{"name":"Heartbeats","phrase":"heartbeats","value":100000,"display":"100K","unit":"roughly"}'::jsonb,'{"name":"Eye blinks","phrase":"eye blinks","value":15000,"display":"15K","unit":"roughly"}'::jsonb,false::boolean),
  ('counting','States vs countries','count','{"name":"United States","phrase":"the United States","value":50,"display":"50","unit":"states"}'::jsonb,'{"name":"Africa","phrase":"Africa","value":54,"display":"54","unit":"countries"}'::jsonb,false::boolean),
  ('distance','Pool vs plane','longer','{"name":"Olympic pool","phrase":"an Olympic pool","value":50,"display":"50","unit":"meters"}'::jsonb,'{"name":"Boeing 747-8","phrase":"a Boeing 747-8","value":76.3,"display":"76.3","unit":"meters"}'::jsonb,false::boolean),
  ('size','Skyscraper height','taller','{"name":"Burj Khalifa","phrase":"the Burj Khalifa","value":828,"display":"828","unit":"meters"}'::jsonb,'{"name":"Shanghai Tower","phrase":"the Shanghai Tower","value":632,"display":"632","unit":"meters"}'::jsonb,false::boolean),
  ('size','Tallest animal','taller','{"name":"Giraffe","phrase":"a giraffe","value":5.5,"display":"5.5","unit":"meters tall"}'::jsonb,'{"name":"African elephant","phrase":"an African elephant","value":3.3,"display":"3.3","unit":"meters at the shoulder"}'::jsonb,false::boolean),
  ('size','Broadcast towers','taller','{"name":"CN Tower","phrase":"the CN Tower","value":553,"display":"553","unit":"meters"}'::jsonb,'{"name":"Willis Tower","phrase":"the Willis Tower","value":442,"display":"442","unit":"meters"}'::jsonb,false::boolean),
  ('size','Nature vs landmark','taller','{"name":"Coast redwood","phrase":"the tallest coast redwood","value":116,"display":"116","unit":"meters"}'::jsonb,'{"name":"Big Ben","phrase":"the Big Ben clock tower","value":96,"display":"96","unit":"meters"}'::jsonb,false::boolean),
  ('distance','Bridge spans','longer','{"name":"Golden Gate Bridge","phrase":"the Golden Gate Bridge''s main span","value":1280,"display":"1,280","unit":"meters"}'::jsonb,'{"name":"Brooklyn Bridge","phrase":"the Brooklyn Bridge''s main span","value":486,"display":"486","unit":"meters"}'::jsonb,false::boolean),
  ('distance','River length','longer','{"name":"Nile","phrase":"the Nile River","value":6650,"display":"6,650","unit":"km"}'::jsonb,'{"name":"Mississippi","phrase":"the Mississippi River","value":3730,"display":"3,730","unit":"km"}'::jsonb,false::boolean),
  ('speed','Fastest dive','faster','{"name":"Peregrine falcon","phrase":"a diving peregrine falcon","value":389,"display":"389","unit":"km/h"}'::jsonb,'{"name":"Bugatti Chiron","phrase":"a Bugatti Chiron","value":490,"display":"490","unit":"km/h top speed"}'::jsonb,true::boolean),
  ('speed','Speed of sound','faster','{"name":"Speed of sound","phrase":"the speed of sound","value":1235,"display":"1,235","unit":"km/h"}'::jsonb,'{"name":"Airliner","phrase":"a cruising airliner","value":900,"display":"900","unit":"km/h"}'::jsonb,false::boolean),
  ('speed','Fast movers','faster','{"name":"Sailfish","phrase":"a sailfish","value":110,"display":"110","unit":"km/h"}'::jsonb,'{"name":"Racehorse","phrase":"a racehorse","value":70,"display":"70","unit":"km/h"}'::jsonb,false::boolean),
  ('size','Biggest countries','area','{"name":"Russia","phrase":"Russia","value":17.1,"display":"17.1M","unit":"square km"}'::jsonb,'{"name":"Canada","phrase":"Canada","value":9.98,"display":"9.98M","unit":"square km"}'::jsonb,false::boolean),
  ('size','Continent size','area','{"name":"Asia","phrase":"Asia","value":44.6,"display":"44.6M","unit":"square km"}'::jsonb,'{"name":"Africa","phrase":"Africa","value":30.4,"display":"30.4M","unit":"square km"}'::jsonb,false::boolean),
  ('size','Cold continent','area','{"name":"Antarctica","phrase":"Antarctica","value":14.2,"display":"14.2M","unit":"square km"}'::jsonb,'{"name":"Australia","phrase":"Australia","value":7.7,"display":"7.7M","unit":"square km"}'::jsonb,false::boolean),
  ('size','State vs country','area','{"name":"Texas","phrase":"Texas","value":695662,"display":"695,662","unit":"square km"}'::jsonb,'{"name":"France","phrase":"France","value":551695,"display":"551,695","unit":"square km"}'::jsonb,false::boolean),
  ('size','Icy island','area','{"name":"Greenland","phrase":"Greenland","value":2.16,"display":"2.16M","unit":"square km"}'::jsonb,'{"name":"Mexico","phrase":"Mexico","value":1.96,"display":"1.96M","unit":"square km"}'::jsonb,false::boolean),
  ('size','Tiny nations','area','{"name":"Monaco","phrase":"Monaco","value":2.02,"display":"2.02","unit":"square km"}'::jsonb,'{"name":"Vatican City","phrase":"Vatican City","value":0.44,"display":"0.44","unit":"square km"}'::jsonb,false::boolean),
  ('counting','String count','count','{"name":"Guitar","phrase":"a guitar","value":6,"display":"6","unit":"strings"}'::jsonb,'{"name":"Violin","phrase":"a violin","value":4,"display":"4","unit":"strings"}'::jsonb,false::boolean),
  ('counting','Arms vs limbs','count','{"name":"Octopus","phrase":"an octopus","value":8,"display":"8","unit":"arms"}'::jsonb,'{"name":"Squid","phrase":"a squid","value":10,"display":"10","unit":"limbs"}'::jsonb,false::boolean),
  ('counting','Team sizes','count','{"name":"Soccer team","phrase":"a soccer team","value":11,"display":"11","unit":"players"}'::jsonb,'{"name":"Baseball team","phrase":"a baseball team","value":9,"display":"9","unit":"players"}'::jsonb,false::boolean),
  ('counting','Leg count','count','{"name":"Spider","phrase":"a spider","value":8,"display":"8","unit":"legs"}'::jsonb,'{"name":"Insect","phrase":"an insect","value":6,"display":"6","unit":"legs"}'::jsonb,false::boolean),
  ('counting','Teeth count','count','{"name":"Adult human","phrase":"an adult human","value":32,"display":"32","unit":"teeth"}'::jsonb,'{"name":"Dog","phrase":"a dog","value":42,"display":"42","unit":"teeth"}'::jsonb,false::boolean),
  ('time','Venus day vs year','duration','{"name":"Day on Venus","phrase":"a day on Venus","value":243,"display":"243","unit":"Earth days"}'::jsonb,'{"name":"Year on Venus","phrase":"a year on Venus","value":225,"display":"225","unit":"Earth days"}'::jsonb,false::boolean),
  ('time','Daily sleep','duration','{"name":"Cat sleep","phrase":"a house cat''s daily sleep","value":15,"display":"15","unit":"hours"}'::jsonb,'{"name":"Giraffe sleep","phrase":"a giraffe''s daily sleep","value":4,"display":"4","unit":"hours"}'::jsonb,false::boolean),
  ('heat','Melting metals','temperature','{"name":"Tungsten","phrase":"tungsten","value":3422,"display":"3,422°","unit":"Celsius"}'::jsonb,'{"name":"Iron","phrase":"iron","value":1538,"display":"1,538°","unit":"Celsius"}'::jsonb,false::boolean),
  ('heat','Soft metals','temperature','{"name":"Copper","phrase":"copper","value":1085,"display":"1,085°","unit":"Celsius"}'::jsonb,'{"name":"Aluminum","phrase":"aluminum","value":660,"display":"660°","unit":"Celsius"}'::jsonb,false::boolean),
  ('weight','Heavy animals','heavier','{"name":"African elephant","phrase":"an African elephant","value":6000,"display":"6,000","unit":"kg"}'::jsonb,'{"name":"Hippo","phrase":"a hippopotamus","value":1500,"display":"1,500","unit":"kg"}'::jsonb,true::boolean),
  ('weight','Ball weight','heavier','{"name":"Golf ball","phrase":"a golf ball","value":46,"display":"46","unit":"grams"}'::jsonb,'{"name":"Ping pong ball","phrase":"a ping pong ball","value":2.7,"display":"2.7","unit":"grams"}'::jsonb,false::boolean),
  ('weight','Newborn weight','heavier','{"name":"Newborn human","phrase":"a newborn human","value":3300,"display":"3,300","unit":"grams"}'::jsonb,'{"name":"Newborn panda","phrase":"a newborn giant panda","value":100,"display":"100","unit":"grams"}'::jsonb,false::boolean),
  ('time','Ancient wonders','older','{"name":"Stonehenge","phrase":"Stonehenge","value":5000,"display":"~5,000","unit":"years old"}'::jsonb,'{"name":"Great Pyramid","phrase":"the Great Pyramid of Giza","value":4500,"display":"~4,500","unit":"years old"}'::jsonb,false::boolean),
  ('time','Cosmic age','older','{"name":"The universe","phrase":"the universe","value":13.8,"display":"13.8B","unit":"years old"}'::jsonb,'{"name":"Earth","phrase":"Earth","value":4.54,"display":"4.54B","unit":"years old"}'::jsonb,true::boolean),
  ('size','Deep places','deeper','{"name":"Mariana Trench","phrase":"the Mariana Trench","value":10935,"display":"10,935","unit":"meters deep"}'::jsonb,'{"name":"Grand Canyon","phrase":"the Grand Canyon","value":1857,"display":"1,857","unit":"meters deep"}'::jsonb,false::boolean),
  ('heat','What''s hotter','hotter','{"name":"Lightning bolt","phrase":"a lightning bolt","value":30000,"display":"30,000°","unit":"Celsius"}'::jsonb,'{"name":"Sun''s surface","phrase":"the Sun''s surface","value":5500,"display":"5,500°","unit":"Celsius"}'::jsonb,true::boolean),
  ('heat','Molten heat','hotter','{"name":"Lava","phrase":"molten lava","value":1200,"display":"1,200°","unit":"Celsius"}'::jsonb,'{"name":"Boiling water","phrase":"boiling water","value":100,"display":"100°","unit":"Celsius"}'::jsonb,false::boolean),
  ('size','Cruising altitude','higher','{"name":"Airliner","phrase":"a cruising airliner","value":11000,"display":"11,000","unit":"meters"}'::jsonb,'{"name":"Mount Everest","phrase":"the summit of Mount Everest","value":8849,"display":"8,849","unit":"meters"}'::jsonb,false::boolean),
  ('counting','Population giants','population','{"name":"India","phrase":"India","value":1.428,"display":"1.428B","unit":"people"}'::jsonb,'{"name":"China","phrase":"China","value":1.411,"display":"1.411B","unit":"people"}'::jsonb,false::boolean),
  ('counting','Metro populations','population','{"name":"Tokyo","phrase":"Tokyo''s metro area","value":37,"display":"37M","unit":"people"}'::jsonb,'{"name":"London","phrase":"London''s metro area","value":14,"display":"14M","unit":"people"}'::jsonb,false::boolean),
  ('speed','Sprint showdown','faster','{"name":"House cat","phrase":"a sprinting house cat","value":48,"display":"48","unit":"km/h"}'::jsonb,'{"name":"Usain Bolt","phrase":"Usain Bolt at top speed","value":44.7,"display":"44.7","unit":"km/h"}'::jsonb,false::boolean),
  ('weight','Whale tongue','heavier','{"name":"Blue whale tongue","phrase":"a blue whale''s tongue","value":2700,"display":"2,700","unit":"kg"}'::jsonb,'{"name":"Small car","phrase":"a small car","value":1500,"display":"1,500","unit":"kg"}'::jsonb,false::boolean),
  ('distance','Squid vs bus','longer','{"name":"Giant squid","phrase":"a giant squid","value":13,"display":"13","unit":"meters"}'::jsonb,'{"name":"School bus","phrase":"a school bus","value":12,"display":"12","unit":"meters"}'::jsonb,false::boolean),
  ('weight','Egg weight','heavier','{"name":"Ostrich egg","phrase":"an ostrich egg","value":1400,"display":"1,400","unit":"grams"}'::jsonb,'{"name":"Chicken egg","phrase":"a chicken egg","value":60,"display":"60","unit":"grams"}'::jsonb,false::boolean),
  ('speed','Sneeze vs cough','faster','{"name":"Sneeze","phrase":"a sneeze","value":160,"display":"160","unit":"km/h"}'::jsonb,'{"name":"Cough","phrase":"a cough","value":80,"display":"80","unit":"km/h"}'::jsonb,false::boolean),
  ('speed','Slow lane','faster','{"name":"Garden snail","phrase":"a garden snail","value":0.05,"display":"0.05","unit":"km/h"}'::jsonb,'{"name":"Giant tortoise","phrase":"a giant tortoise","value":0.5,"display":"0.5","unit":"km/h"}'::jsonb,false::boolean),
  ('sound','Fast food calories','caloric','{"name":"Big Mac","phrase":"a Big Mac","value":550,"display":"550","unit":"calories"}'::jsonb,'{"name":"Glazed donut","phrase":"a glazed donut","value":190,"display":"190","unit":"calories"}'::jsonb,false::boolean),
  ('sound','Fruit calories','caloric','{"name":"Avocado","phrase":"an avocado","value":240,"display":"240","unit":"calories"}'::jsonb,'{"name":"Banana","phrase":"a banana","value":105,"display":"105","unit":"calories"}'::jsonb,false::boolean),
  ('sound','Snack calories','caloric','{"name":"Pizza slice","phrase":"a slice of pizza","value":285,"display":"285","unit":"calories"}'::jsonb,'{"name":"Bagel","phrase":"a plain bagel","value":250,"display":"250","unit":"calories"}'::jsonb,false::boolean),
  ('sound','Drink vs fruit','caloric','{"name":"Can of cola","phrase":"a can of cola","value":140,"display":"140","unit":"calories"}'::jsonb,'{"name":"Apple","phrase":"a medium apple","value":95,"display":"95","unit":"calories"}'::jsonb,false::boolean),
  ('sound','Loud machines','louder','{"name":"Jet engine","phrase":"a jet engine at takeoff","value":140,"display":"140","unit":"decibels"}'::jsonb,'{"name":"Rock concert","phrase":"a rock concert","value":110,"display":"110","unit":"decibels"}'::jsonb,true::boolean),
  ('sound','Roar vs room','louder','{"name":"Lion''s roar","phrase":"a lion''s roar","value":114,"display":"114","unit":"decibels"}'::jsonb,'{"name":"Busy restaurant","phrase":"a busy restaurant","value":70,"display":"70","unit":"decibels"}'::jsonb,false::boolean),
  ('sound','Quiet sounds','louder','{"name":"Refrigerator","phrase":"a humming refrigerator","value":40,"display":"40","unit":"decibels"}'::jsonb,'{"name":"Whisper","phrase":"a whisper","value":30,"display":"30","unit":"decibels"}'::jsonb,false::boolean),
  ('sound','Storm vs engine','louder','{"name":"Thunderclap","phrase":"a thunderclap","value":120,"display":"120","unit":"decibels"}'::jsonb,'{"name":"Motorcycle","phrase":"a motorcycle","value":95,"display":"95","unit":"decibels"}'::jsonb,false::boolean),
  ('counting','Baby vs adult bones','count','{"name":"Newborn baby","phrase":"a newborn baby","value":300,"display":"300","unit":"bones"}'::jsonb,'{"name":"Adult human","phrase":"an adult human","value":206,"display":"206","unit":"bones"}'::jsonb,false::boolean),
  ('distance','Gut length','longer','{"name":"Small intestine","phrase":"the human small intestine","value":6,"display":"6","unit":"meters"}'::jsonb,'{"name":"Large intestine","phrase":"the human large intestine","value":1.5,"display":"1.5","unit":"meters"}'::jsonb,false::boolean),
  ('counting','Hand vs foot','count','{"name":"Human hand","phrase":"a human hand","value":27,"display":"27","unit":"bones"}'::jsonb,'{"name":"Human foot","phrase":"a human foot","value":26,"display":"26","unit":"bones"}'::jsonb,false::boolean),
  ('size','Waterfall height','higher','{"name":"Angel Falls","phrase":"Angel Falls","value":979,"display":"979","unit":"meters"}'::jsonb,'{"name":"Niagara Falls","phrase":"Niagara Falls","value":51,"display":"51","unit":"meters"}'::jsonb,false::boolean),
  ('size','Deep lakes','deeper','{"name":"Lake Baikal","phrase":"Lake Baikal","value":1642,"display":"1,642","unit":"meters deep"}'::jsonb,'{"name":"Crater Lake","phrase":"Crater Lake","value":594,"display":"594","unit":"meters deep"}'::jsonb,false::boolean),
  ('size','Deepest cave','deeper','{"name":"Veryovkina Cave","phrase":"the Veryovkina Cave","value":2212,"display":"2,212","unit":"meters deep"}'::jsonb,'{"name":"Lake Baikal","phrase":"Lake Baikal","value":1642,"display":"1,642","unit":"meters deep"}'::jsonb,false::boolean),
  ('distance','Long rivers','longer','{"name":"Amazon River","phrase":"the Amazon River","value":6400,"display":"6,400","unit":"km"}'::jsonb,'{"name":"Danube River","phrase":"the Danube River","value":2850,"display":"2,850","unit":"km"}'::jsonb,false::boolean),
  ('size','Desert vs country','area','{"name":"Sahara Desert","phrase":"the Sahara Desert","value":9.2,"display":"9.2M","unit":"square km"}'::jsonb,'{"name":"Brazil","phrase":"Brazil","value":8.5,"display":"8.5M","unit":"square km"}'::jsonb,false::boolean),
  ('size','Peak heights','taller','{"name":"Mount Kilimanjaro","phrase":"Mount Kilimanjaro","value":5895,"display":"5,895","unit":"meters"}'::jsonb,'{"name":"Mont Blanc","phrase":"Mont Blanc","value":4809,"display":"4,809","unit":"meters"}'::jsonb,false::boolean),
  ('size','Gas giants','wider','{"name":"Jupiter","phrase":"Jupiter","value":139820,"display":"139,820","unit":"km wide"}'::jsonb,'{"name":"Saturn","phrase":"Saturn","value":116460,"display":"116,460","unit":"km wide"}'::jsonb,false::boolean),
  ('size','Star vs planet','wider','{"name":"The Sun","phrase":"the Sun","value":1391000,"display":"1.39M","unit":"km wide"}'::jsonb,'{"name":"Earth","phrase":"Earth","value":12742,"display":"12,742","unit":"km wide"}'::jsonb,false::boolean),
  ('size','Red vs grey','wider','{"name":"Mars","phrase":"Mars","value":6779,"display":"6,779","unit":"km wide"}'::jsonb,'{"name":"The Moon","phrase":"the Moon","value":3475,"display":"3,475","unit":"km wide"}'::jsonb,false::boolean),
  ('time','Length of a day','duration','{"name":"Day on Jupiter","phrase":"a day on Jupiter","value":10,"display":"10","unit":"hours"}'::jsonb,'{"name":"Day on Earth","phrase":"a day on Earth","value":24,"display":"24","unit":"hours"}'::jsonb,false::boolean),
  ('distance','Planet distance','distance','{"name":"Neptune''s orbit","phrase":"Neptune''s distance from the Sun","value":4500,"display":"4,500M","unit":"km"}'::jsonb,'{"name":"Earth''s orbit","phrase":"Earth''s distance from the Sun","value":150,"display":"150M","unit":"km"}'::jsonb,false::boolean),
  ('heat','Hottest planet','hotter','{"name":"Venus","phrase":"the surface of Venus","value":465,"display":"465°","unit":"Celsius"}'::jsonb,'{"name":"Mercury","phrase":"Mercury''s day side","value":430,"display":"430°","unit":"Celsius"}'::jsonb,false::boolean),
  ('heat','Melting points','temperature','{"name":"Lead","phrase":"lead","value":327,"display":"327°","unit":"Celsius"}'::jsonb,'{"name":"Tin","phrase":"tin","value":232,"display":"232°","unit":"Celsius"}'::jsonb,false::boolean),
  ('heat','Boiling points','hotter','{"name":"Water","phrase":"water''s boiling point","value":100,"display":"100°","unit":"Celsius"}'::jsonb,'{"name":"Ethanol","phrase":"ethanol''s boiling point","value":78,"display":"78°","unit":"Celsius"}'::jsonb,false::boolean),
  ('time','Game clock','duration','{"name":"Soccer match","phrase":"a soccer match","value":90,"display":"90","unit":"minutes"}'::jsonb,'{"name":"NBA game","phrase":"an NBA game","value":48,"display":"48","unit":"minutes"}'::jsonb,false::boolean),
  ('counting','Tile games','count','{"name":"Scrabble game","phrase":"a Scrabble game","value":100,"display":"100","unit":"tiles"}'::jsonb,'{"name":"Domino set","phrase":"a standard domino set","value":28,"display":"28","unit":"tiles"}'::jsonb,false::boolean),
  ('size','Goal width','wider','{"name":"Soccer goal","phrase":"a soccer goal","value":7.32,"display":"7.32","unit":"meters wide"}'::jsonb,'{"name":"Hockey goal","phrase":"an ice hockey goal","value":1.83,"display":"1.83","unit":"meters wide"}'::jsonb,false::boolean),
  ('counting','Key count','count','{"name":"Computer keyboard","phrase":"a full computer keyboard","value":104,"display":"104","unit":"keys"}'::jsonb,'{"name":"Piano","phrase":"a grand piano","value":88,"display":"88","unit":"keys"}'::jsonb,false::boolean),
  ('distance','Sports lanes','longer','{"name":"Cricket pitch","phrase":"a cricket pitch","value":20.12,"display":"20.12","unit":"meters"}'::jsonb,'{"name":"Bowling lane","phrase":"a bowling lane","value":18.3,"display":"18.3","unit":"meters"}'::jsonb,false::boolean),
  ('speed','Track speeds','faster','{"name":"Formula 1 car","phrase":"a Formula 1 car","value":375,"display":"375","unit":"km/h"}'::jsonb,'{"name":"Bullet train","phrase":"a Japanese bullet train","value":320,"display":"320","unit":"km/h"}'::jsonb,false::boolean),
  ('counting','Days vs notes','count','{"name":"Week","phrase":"a week","value":7,"display":"7","unit":"days"}'::jsonb,'{"name":"Octave","phrase":"a musical octave","value":8,"display":"8","unit":"notes"}'::jsonb,false::boolean),
  ('weight','Heavy metals','heavier','{"name":"Gold bar","phrase":"a standard gold bar","value":12.4,"display":"12.4","unit":"kg"}'::jsonb,'{"name":"House cat","phrase":"a house cat","value":4.5,"display":"4.5","unit":"kg"}'::jsonb,false::boolean),
  ('size','Dino height','taller','{"name":"T. rex","phrase":"a Tyrannosaurus rex","value":6,"display":"6","unit":"meters tall"}'::jsonb,'{"name":"Double-decker bus","phrase":"a double-decker bus","value":4.4,"display":"4.4","unit":"meters tall"}'::jsonb,false::boolean),
  ('weight','Structure weight','heavier','{"name":"Eiffel Tower","phrase":"the Eiffel Tower","value":10100,"display":"10,100","unit":"tonnes"}'::jsonb,'{"name":"Statue of Liberty","phrase":"the Statue of Liberty","value":225,"display":"225","unit":"tonnes"}'::jsonb,false::boolean),
  ('counting','Colors vs rings','count','{"name":"Rainbow","phrase":"a rainbow","value":7,"display":"7","unit":"colors"}'::jsonb,'{"name":"Olympic flag","phrase":"the Olympic flag","value":5,"display":"5","unit":"rings"}'::jsonb,false::boolean),
  ('time','Ancient sites','older','{"name":"Great Wall","phrase":"the Great Wall of China","value":2300,"display":"~2,300","unit":"years old"}'::jsonb,'{"name":"Machu Picchu","phrase":"Machu Picchu","value":580,"display":"~580","unit":"years old"}'::jsonb,false::boolean),
  ('time','Landmark age','older','{"name":"Colosseum","phrase":"the Roman Colosseum","value":1950,"display":"~1,950","unit":"years old"}'::jsonb,'{"name":"Eiffel Tower","phrase":"the Eiffel Tower","value":135,"display":"135","unit":"years old"}'::jsonb,false::boolean),
  ('counting','Continent people','population','{"name":"Africa","phrase":"Africa","value":1400,"display":"1.4B","unit":"people"}'::jsonb,'{"name":"Europe","phrase":"Europe","value":745,"display":"745M","unit":"people"}'::jsonb,false::boolean),
  ('counting','Nation sizes','population','{"name":"United States","phrase":"the United States","value":335,"display":"335M","unit":"people"}'::jsonb,'{"name":"Indonesia","phrase":"Indonesia","value":277,"display":"277M","unit":"people"}'::jsonb,false::boolean),
  ('weight','Big cats','heavier','{"name":"Siberian tiger","phrase":"a Siberian tiger","value":300,"display":"300","unit":"kg"}'::jsonb,'{"name":"Lion","phrase":"a lion","value":190,"display":"190","unit":"kg"}'::jsonb,false::boolean),
  ('distance','Ocean giants','longer','{"name":"Whale shark","phrase":"a whale shark","value":12,"display":"12","unit":"meters"}'::jsonb,'{"name":"Great white shark","phrase":"a great white shark","value":6,"display":"6","unit":"meters"}'::jsonb,false::boolean),
  ('size','Bird wingspan','wider','{"name":"Wandering albatross","phrase":"a wandering albatross''s wingspan","value":3.5,"display":"3.5","unit":"meters"}'::jsonb,'{"name":"Bald eagle","phrase":"a bald eagle''s wingspan","value":2.3,"display":"2.3","unit":"meters"}'::jsonb,false::boolean),
  ('speed','Tiny fliers','faster','{"name":"Hummingbird dive","phrase":"a diving hummingbird","value":100,"display":"100","unit":"km/h"}'::jsonb,'{"name":"Housefly","phrase":"a housefly","value":7,"display":"7","unit":"km/h"}'::jsonb,false::boolean),
  ('time','Long life','older','{"name":"Galápagos tortoise","phrase":"a Galápagos tortoise","value":150,"display":"150","unit":"years max age"}'::jsonb,'{"name":"Human","phrase":"a human","value":122,"display":"122","unit":"years max age"}'::jsonb,false::boolean),
  ('weight','Egg to bird','heavier','{"name":"Emu egg","phrase":"an emu egg","value":600,"display":"600","unit":"grams"}'::jsonb,'{"name":"Kiwi egg","phrase":"a kiwi egg","value":450,"display":"450","unit":"grams"}'::jsonb,false::boolean),
  ('heat','Desert heat','hotter','{"name":"Death Valley record","phrase":"Death Valley''s record high","value":56.7,"display":"56.7°","unit":"Celsius"}'::jsonb,'{"name":"Sahara summer","phrase":"a typical Sahara summer day","value":45,"display":"45°","unit":"Celsius"}'::jsonb,false::boolean),
  ('heat','Frozen points','temperature','{"name":"Salt","phrase":"table salt","value":801,"display":"801°","unit":"Celsius"}'::jsonb,'{"name":"Sugar","phrase":"sugar","value":186,"display":"186°","unit":"Celsius"}'::jsonb,false::boolean),
  ('sound','Snack energy','caloric','{"name":"Chocolate bar","phrase":"a chocolate bar","value":230,"display":"230","unit":"calories"}'::jsonb,'{"name":"Rice cake","phrase":"a rice cake","value":35,"display":"35","unit":"calories"}'::jsonb,false::boolean),
  ('sound','Breakfast calories','caloric','{"name":"Croissant","phrase":"a butter croissant","value":270,"display":"270","unit":"calories"}'::jsonb,'{"name":"Boiled egg","phrase":"a boiled egg","value":78,"display":"78","unit":"calories"}'::jsonb,false::boolean),
  ('size','City heights','taller','{"name":"One World Trade Center","phrase":"One World Trade Center","value":541,"display":"541","unit":"meters"}'::jsonb,'{"name":"The Shard","phrase":"the Shard","value":310,"display":"310","unit":"meters"}'::jsonb,false::boolean),
  ('size','Statue scale','taller','{"name":"Statue of Unity","phrase":"the Statue of Unity","value":182,"display":"182","unit":"meters"}'::jsonb,'{"name":"Christ the Redeemer","phrase":"Christ the Redeemer","value":30,"display":"30","unit":"meters"}'::jsonb,false::boolean),
  ('size','Island size','area','{"name":"Madagascar","phrase":"Madagascar","value":587041,"display":"587,041","unit":"square km"}'::jsonb,'{"name":"Great Britain","phrase":"Great Britain","value":209331,"display":"209,331","unit":"square km"}'::jsonb,false::boolean),
  ('size','Lake surface','area','{"name":"Caspian Sea","phrase":"the Caspian Sea","value":371000,"display":"371,000","unit":"square km"}'::jsonb,'{"name":"Lake Superior","phrase":"Lake Superior","value":82100,"display":"82,100","unit":"square km"}'::jsonb,false::boolean),
  ('sound','Loud animals','louder','{"name":"Blue whale call","phrase":"a blue whale''s call","value":188,"display":"188","unit":"decibels"}'::jsonb,'{"name":"Howler monkey","phrase":"a howler monkey","value":140,"display":"140","unit":"decibels"}'::jsonb,false::boolean),
  ('sound','Everyday volume','louder','{"name":"Vacuum cleaner","phrase":"a vacuum cleaner","value":75,"display":"75","unit":"decibels"}'::jsonb,'{"name":"Normal conversation","phrase":"normal conversation","value":60,"display":"60","unit":"decibels"}'::jsonb,false::boolean),
  ('counting','Board game pieces','count','{"name":"Chess set","phrase":"a chess set","value":32,"display":"32","unit":"pieces"}'::jsonb,'{"name":"Checkers set","phrase":"a checkers set","value":24,"display":"24","unit":"pieces"}'::jsonb,false::boolean),
  ('counting','Keyboard rows','count','{"name":"Piano octaves","phrase":"a standard piano","value":7,"display":"7","unit":"octaves"}'::jsonb,'{"name":"Guitar","phrase":"a guitar","value":6,"display":"6","unit":"strings"}'::jsonb,false::boolean),
  ('counting','Rib count','count','{"name":"Human ribs","phrase":"an adult human","value":24,"display":"24","unit":"ribs"}'::jsonb,'{"name":"Dog ribs","phrase":"a dog","value":26,"display":"26","unit":"ribs"}'::jsonb,false::boolean),
  ('distance','Court length','longer','{"name":"Tennis court","phrase":"a tennis court","value":23.77,"display":"23.77","unit":"meters"}'::jsonb,'{"name":"Basketball court","phrase":"a basketball court","value":28.65,"display":"28.65","unit":"meters"}'::jsonb,false::boolean),
  ('distance','Race distances','distance','{"name":"Half marathon","phrase":"a half marathon","value":21.1,"display":"21.1","unit":"km"}'::jsonb,'{"name":"10K race","phrase":"a 10K race","value":10,"display":"10","unit":"km"}'::jsonb,false::boolean),
  ('time','Flight time','duration','{"name":"Monarch migration","phrase":"a monarch butterfly''s migration","value":60,"display":"60","unit":"days"}'::jsonb,'{"name":"Mayfly life","phrase":"an adult mayfly''s life","value":1,"display":"1","unit":"day"}'::jsonb,false::boolean),
  ('time','Gestation','duration','{"name":"Blue whale pregnancy","phrase":"a blue whale pregnancy","value":11,"display":"11","unit":"months"}'::jsonb,'{"name":"Human pregnancy","phrase":"a human pregnancy","value":9,"display":"9","unit":"months"}'::jsonb,false::boolean),
  ('size','Deep diving','deeper','{"name":"Sperm whale dive","phrase":"a sperm whale''s dive","value":2250,"display":"2,250","unit":"meters"}'::jsonb,'{"name":"Scuba record","phrase":"the scuba depth record","value":332,"display":"332","unit":"meters"}'::jsonb,false::boolean),
  ('speed','Planet spin','faster','{"name":"Earth''s rotation","phrase":"Earth''s equator spin","value":1670,"display":"1,670","unit":"km/h"}'::jsonb,'{"name":"Jupiter surface storm","phrase":"Jupiter''s Great Red Spot winds","value":640,"display":"640","unit":"km/h"}'::jsonb,false::boolean),
  ('time','Wonders age','older','{"name":"Petra","phrase":"the city of Petra","value":2100,"display":"~2,100","unit":"years old"}'::jsonb,'{"name":"Taj Mahal","phrase":"the Taj Mahal","value":370,"display":"~370","unit":"years old"}'::jsonb,false::boolean),
  ('counting','Country populations','population','{"name":"Nigeria","phrase":"Nigeria","value":223,"display":"223M","unit":"people"}'::jsonb,'{"name":"Japan","phrase":"Japan","value":124,"display":"124M","unit":"people"}'::jsonb,false::boolean),
  ('size','Mountain vs building','higher','{"name":"Denali summit","phrase":"the summit of Denali","value":6190,"display":"6,190","unit":"meters"}'::jsonb,'{"name":"Burj Khalifa","phrase":"the top of the Burj Khalifa","value":828,"display":"828","unit":"meters"}'::jsonb,false::boolean),
  ('weight','Tower weight','heavier','{"name":"Space Shuttle","phrase":"a Space Shuttle at launch","value":2030,"display":"2,030","unit":"tonnes"}'::jsonb,'{"name":"Blue whale","phrase":"a blue whale","value":150,"display":"150","unit":"tonnes"}'::jsonb,false::boolean),
  ('weight','Fruit size','heavier','{"name":"Watermelon","phrase":"an average watermelon","value":9,"display":"9","unit":"kg"}'::jsonb,'{"name":"Pineapple","phrase":"an average pineapple","value":1.5,"display":"1.5","unit":"kg"}'::jsonb,false::boolean);
-- ============================================================
-- RPCs — every write to match state goes through one of these
-- (security definer, validate-then-write, mirroring submit_solo_score's pattern)
-- ============================================================

create or replace function public.create_remote_match(p_player_name text)
returns table(match_id uuid, match_code text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_name text := btrim(p_player_name);
  v_code text;
  v_id uuid;
  v_tries int := 0;
begin
  if v_uid is null then
    raise exception 'Sign-in required';
  end if;
  if char_length(v_name) not between 1 and 14 or v_name ~ '[[:cntrl:]]' then
    raise exception 'Display name must be 1 to 14 visible characters';
  end if;
  if (select count(*) from public.matches where player1_id = v_uid and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'Too many matches created recently — try again later';
  end if;

  loop
    v_tries := v_tries + 1;
    v_code := upper(substr(md5(gen_random_uuid()::text), 1, 6));
    begin
      insert into public.matches (match_code, player1_id, player1_name, status)
      values (v_code, v_uid, v_name, 'pending')
      returning id into v_id;
      exit;
    exception when unique_violation then
      if v_tries > 5 then
        raise exception 'Could not generate a unique invite code — try again';
      end if;
    end;
  end loop;

  return query select v_id, v_code;
end;
$$;
revoke all on function public.create_remote_match(text) from public;
grant execute on function public.create_remote_match(text) to authenticated;

create or replace function public.join_remote_match(p_match_code text, p_player_name text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_name text := btrim(p_player_name);
  v_match public.matches;
begin
  if v_uid is null then
    raise exception 'Sign-in required';
  end if;
  if char_length(v_name) not between 1 and 14 or v_name ~ '[[:cntrl:]]' then
    raise exception 'Display name must be 1 to 14 visible characters';
  end if;

  select * into v_match from public.matches where match_code = upper(btrim(p_match_code)) for update;
  if not found then
    raise exception 'Invite code not found';
  end if;
  if v_match.status <> 'pending' then
    raise exception 'This match already started or finished';
  end if;
  if v_match.player1_id = v_uid then
    raise exception 'You created this match — share the link with a friend instead';
  end if;
  if v_match.created_at < now() - interval '7 days' then
    raise exception 'This invite has expired';
  end if;

  update public.matches set
    player2_id = v_uid,
    player2_name = v_name,
    status = 'active',
    turn_player_id = case when random() < 0.5 then v_match.player1_id else v_uid end,
    last_activity_at = now()
  where id = v_match.id;

  return v_match.id;
end;
$$;
revoke all on function public.join_remote_match(text, text) from public;
grant execute on function public.join_remote_match(text, text) to authenticated;

create or replace function public.spin_wheel(p_match_id uuid)
returns table(turn_id bigint, category_key text, is_crown_attempt boolean, question jsonb)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_match public.matches;
  v_category text;
  v_fact public.facts;
  v_is_crown boolean;
  v_known_is_a boolean;
  v_turn_no int;
  v_turn_id bigint;
  v_known jsonb;
  v_target jsonb;
begin
  if v_uid is null then raise exception 'Sign-in required'; end if;

  select * into v_match from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if v_uid <> v_match.player1_id and v_uid <> v_match.player2_id then raise exception 'Not a participant in this match'; end if;
  if v_match.status <> 'active' then raise exception 'Match is not active'; end if;
  if v_match.turn_player_id <> v_uid then raise exception 'Not your turn'; end if;
  if exists (select 1 from public.match_turns where match_id = p_match_id and answered_at is null) then
    raise exception 'A turn is already open for this match';
  end if;

  select key into v_category from public.wheel_categories order by random() limit 1;
  v_is_crown := not exists (select 1 from public.match_crowns mc where mc.match_id = p_match_id and mc.category_key = v_category);

  if v_is_crown then
    select * into v_fact from public.facts where category = v_category and is_crown_challenge and active limit 1;
  else
    select * into v_fact from public.facts
      where category = v_category and active and not is_crown_challenge
      order by random() limit 1;
    if not found then
      select * into v_fact from public.facts where category = v_category and active order by random() limit 1;
    end if;
  end if;
  if not found then raise exception 'No facts available for this category'; end if;

  v_known_is_a := random() < 0.5;
  v_known := case when v_known_is_a then v_fact.item_a else v_fact.item_b end;
  v_target := case when v_known_is_a then v_fact.item_b else v_fact.item_a end;

  select coalesce(max(turn_no), 0) + 1 into v_turn_no from public.match_turns where match_id = p_match_id;

  insert into public.match_turns (match_id, turn_no, player_id, category_key, fact_id, known_is_a, is_crown_attempt)
  values (p_match_id, v_turn_no, v_uid, v_category, v_fact.id, v_known_is_a, v_is_crown)
  returning id into v_turn_id;

  return query select v_turn_id, v_category, v_is_crown,
    jsonb_build_object(
      'topic', v_fact.topic,
      'type', v_fact.type,
      'known', v_known,
      'target', jsonb_build_object('name', v_target->>'name', 'phrase', v_target->>'phrase', 'unit', v_target->>'unit')
    );
end;
$$;
revoke all on function public.spin_wheel(uuid) from public;
grant execute on function public.spin_wheel(uuid) to authenticated;

-- Lets a client that reloaded mid-turn (spun but hasn't answered yet) reconstruct the
-- question without ever touching the facts table directly. Same redaction as spin_wheel.
create or replace function public.get_open_turn(p_match_id uuid)
returns table(turn_id bigint, category_key text, is_crown_attempt boolean, question jsonb)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_turn public.match_turns;
  v_fact public.facts;
  v_known jsonb; v_target jsonb;
begin
  if v_uid is null then raise exception 'Sign-in required'; end if;

  select * into v_turn from public.match_turns
    where match_id = p_match_id and player_id = v_uid and answered_at is null
    order by turn_no desc limit 1;
  if not found then
    return;
  end if;

  select * into v_fact from public.facts where id = v_turn.fact_id;
  v_known := case when v_turn.known_is_a then v_fact.item_a else v_fact.item_b end;
  v_target := case when v_turn.known_is_a then v_fact.item_b else v_fact.item_a end;

  return query select v_turn.id, v_turn.category_key, v_turn.is_crown_attempt,
    jsonb_build_object(
      'topic', v_fact.topic,
      'type', v_fact.type,
      'known', v_known,
      'target', jsonb_build_object('name', v_target->>'name', 'phrase', v_target->>'phrase', 'unit', v_target->>'unit')
    );
end;
$$;
revoke all on function public.get_open_turn(uuid) from public;
grant execute on function public.get_open_turn(uuid) to authenticated;

create or replace function public.use_power_up(p_turn_id bigint, p_kind text)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_turn public.match_turns;
  v_fact public.facts;
  v_known jsonb; v_target jsonb;
  v_count int;
  v_hi numeric; v_lo numeric;
  v_hint text;
begin
  if v_uid is null then raise exception 'Sign-in required'; end if;
  if p_kind not in ('double','extra_time','fifty_fifty') then raise exception 'Invalid power-up'; end if;

  select * into v_turn from public.match_turns where id = p_turn_id for update;
  if not found then raise exception 'Turn not found'; end if;
  if v_turn.player_id <> v_uid then raise exception 'Not your turn'; end if;
  if v_turn.answered_at is not null then raise exception 'Turn already answered'; end if;

  if p_kind = 'double' then
    if v_turn.used_double then raise exception 'Already armed for this turn'; end if;
    select count(*) into v_count from public.match_turns where match_id = v_turn.match_id and player_id = v_uid and used_double;
    if v_count >= 2 then raise exception 'No uses of Double left'; end if;
    update public.match_turns set used_double = true where id = p_turn_id;
    return null;
  end if;

  if p_kind = 'extra_time' then
    if v_turn.used_extra_time then raise exception 'Already used this turn'; end if;
    select count(*) into v_count from public.match_turns where match_id = v_turn.match_id and player_id = v_uid and used_extra_time;
    if v_count >= 2 then raise exception 'No uses of +6s left'; end if;
    update public.match_turns set used_extra_time = true where id = p_turn_id;
    return null;
  end if;

  -- fifty_fifty: a proximity hint, adapted for a higher/lower (not multiple-choice) format
  if v_turn.used_hint then raise exception 'Already used this turn'; end if;
  select count(*) into v_count from public.match_turns where match_id = v_turn.match_id and player_id = v_uid and used_hint;
  if v_count >= 2 then raise exception 'No uses of Hint left'; end if;

  select * into v_fact from public.facts where id = v_turn.fact_id;
  v_known := case when v_turn.known_is_a then v_fact.item_a else v_fact.item_b end;
  v_target := case when v_turn.known_is_a then v_fact.item_b else v_fact.item_a end;
  v_hi := greatest((v_known->>'value')::numeric, (v_target->>'value')::numeric);
  v_lo := greatest(1, least((v_known->>'value')::numeric, (v_target->>'value')::numeric));
  v_hint := case when (v_hi / v_lo) < 1.35 then 'Photo finish — it''s razor close.' else 'Not close — there''s a big gap.' end;

  update public.match_turns set used_hint = true where id = p_turn_id;
  return v_hint;
end;
$$;
revoke all on function public.use_power_up(bigint, text) from public;
grant execute on function public.use_power_up(bigint, text) to authenticated;

create or replace function public.submit_turn(p_turn_id bigint, p_guess text default null, p_elapsed_ms int default null)
returns table(correct boolean, points int, crown_won boolean, match_status text, winner_id uuid, target jsonb)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_turn public.match_turns;
  v_match public.matches;
  v_fact public.facts;
  v_known jsonb; v_target jsonb;
  v_correct boolean;
  v_points int := 0;
  v_crown_won boolean := false;
  v_other uuid;
  v_max_elapsed int;
  v_own_crowns int;
  v_total_crowns int;
  v_total_categories int;
  v_p1_crowns int;
  v_p2_crowns int;
  v_status text := 'active';
  v_winner uuid := null;
begin
  if v_uid is null then raise exception 'Sign-in required'; end if;
  if p_guess is not null and p_guess not in ('higher','lower') then raise exception 'Invalid guess'; end if;

  select * into v_turn from public.match_turns where id = p_turn_id for update;
  if not found then raise exception 'Turn not found'; end if;
  if v_turn.player_id <> v_uid then raise exception 'Not your turn'; end if;
  if v_turn.answered_at is not null then raise exception 'Turn already answered'; end if;

  select * into v_match from public.matches where id = v_turn.match_id for update;
  if v_match.status <> 'active' then raise exception 'Match is not active'; end if;

  select * into v_fact from public.facts where id = v_turn.fact_id;
  v_known := case when v_turn.known_is_a then v_fact.item_a else v_fact.item_b end;
  v_target := case when v_turn.known_is_a then v_fact.item_b else v_fact.item_a end;

  v_max_elapsed := case when v_turn.used_extra_time then 30000 else 20000 end;
  if p_elapsed_ms is null or p_elapsed_ms < 0 then p_elapsed_ms := v_max_elapsed; end if;
  if p_elapsed_ms > v_max_elapsed then p_elapsed_ms := v_max_elapsed; end if;

  if p_guess is null then
    v_correct := null;
  else
    v_correct := case when p_guess = 'higher' then (v_target->>'value')::numeric > (v_known->>'value')::numeric
                       else (v_target->>'value')::numeric < (v_known->>'value')::numeric end;
    if v_correct then
      v_points := 100;
      if v_turn.is_crown_attempt then
        v_points := v_points + 500;
        v_crown_won := true;
      end if;
      if v_turn.used_double then
        v_points := v_points * 2;
      end if;
    end if;
  end if;

  update public.match_turns set
    guess = p_guess,
    correct = v_correct,
    points_earned = v_points,
    elapsed_ms = p_elapsed_ms,
    answered_at = now()
  where id = p_turn_id;

  if v_crown_won then
    insert into public.match_crowns (match_id, category_key, won_by)
    values (v_turn.match_id, v_turn.category_key, v_uid)
    on conflict (match_id, category_key) do nothing;
  end if;

  v_other := case when v_uid = v_match.player1_id then v_match.player2_id else v_match.player1_id end;

  if v_uid = v_match.player1_id then
    update public.matches set player1_score = player1_score + v_points where id = v_match.id;
  else
    update public.matches set player2_score = player2_score + v_points where id = v_match.id;
  end if;

  select count(*) into v_total_categories from public.wheel_categories;
  select count(*) into v_own_crowns from public.match_crowns where match_id = v_turn.match_id and won_by = v_uid;
  select count(*) into v_total_crowns from public.match_crowns where match_id = v_turn.match_id;

  if v_own_crowns = v_total_categories then
    v_status := 'completed';
    v_winner := v_uid;
  elsif v_total_crowns = v_total_categories then
    select count(*) into v_p1_crowns from public.match_crowns where match_id = v_turn.match_id and won_by = v_match.player1_id;
    select count(*) into v_p2_crowns from public.match_crowns where match_id = v_turn.match_id and won_by = v_match.player2_id;
    v_status := 'completed';
    if v_p1_crowns <> v_p2_crowns then
      v_winner := case when v_p1_crowns > v_p2_crowns then v_match.player1_id else v_match.player2_id end;
    else
      select case when p1s <> p2s then (case when p1s > p2s then player1_id else player2_id end) else null end
        into v_winner
        from (select player1_score p1s, player2_score p2s, player1_id, player2_id from public.matches where id = v_match.id) s;
    end if;
  end if;

  if v_status = 'completed' then
    update public.matches set status = 'completed', winner_id = v_winner, last_activity_at = now() where id = v_match.id;
  else
    update public.matches set turn_player_id = v_other, last_activity_at = now() where id = v_match.id;
  end if;

  return query select v_correct, v_points, v_crown_won, v_status, v_winner,
    jsonb_build_object(
      'name', v_target->>'name', 'phrase', v_target->>'phrase',
      'value', (v_target->>'value')::numeric, 'display', v_target->>'display', 'unit', v_target->>'unit'
    );
end;
$$;
revoke all on function public.submit_turn(bigint, text, int) from public;
grant execute on function public.submit_turn(bigint, text, int) to authenticated;
