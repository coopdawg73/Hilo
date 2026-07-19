-- Hilo global solo leaderboard
-- Run this once in the Supabase SQL editor.

create table if not exists public.solo_scores (
  id uuid primary key default gen_random_uuid(),
  player_name text not null check (char_length(player_name) between 1 and 14),
  score integer not null check (score between 0 and 10000),
  correct_answers smallint not null check (correct_answers between 0 and 10),
  total_duration_ms integer not null check (total_duration_ms between 0 and 80000),
  created_at timestamptz not null default now()
);

create index if not exists solo_scores_ranking_idx
  on public.solo_scores (score desc, total_duration_ms asc, created_at asc);

alter table public.solo_scores enable row level security;

drop policy if exists "Public leaderboard is readable" on public.solo_scores;
create policy "Public leaderboard is readable"
  on public.solo_scores
  for select
  to anon, authenticated
  using (true);

-- Direct writes stay blocked. The RPC below validates and calculates every score.
revoke insert, update, delete on public.solo_scores from anon, authenticated;
grant select on public.solo_scores to anon, authenticated;

create or replace function public.submit_solo_score(
  p_player_name text,
  p_answer_times_ms integer[],
  p_correct boolean[]
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
  v_name text := btrim(p_player_name);
  v_score integer := 0;
  v_correct smallint := 0;
  v_total_duration integer := 0;
  v_elapsed integer;
  i integer;
begin
  if char_length(v_name) not between 1 and 14 or v_name ~ '[[:cntrl:]]' then
    raise exception 'Display name must be 1 to 14 visible characters';
  end if;

  if coalesce(array_length(p_answer_times_ms, 1), 0) <> 10
     or coalesce(array_length(p_correct, 1), 0) <> 10 then
    raise exception 'A ranked run must contain exactly 10 answers';
  end if;

  for i in 1..10 loop
    v_elapsed := p_answer_times_ms[i];
    if v_elapsed is null or v_elapsed < 0 or v_elapsed > 8000 or p_correct[i] is null then
      raise exception 'Invalid answer data';
    end if;

    v_total_duration := v_total_duration + v_elapsed;
    if p_correct[i] then
      v_correct := v_correct + 1;
      v_score := v_score + greatest(
        100,
        round(1000.0 * (8000 - v_elapsed) / 8000.0)::integer
      );
    end if;
  end loop;

  -- A light replay guard prevents accidental submission loops without blocking play.
  if (
    select count(*)
    from public.solo_scores
    where lower(player_name) = lower(v_name)
      and created_at > now() - interval '1 minute'
  ) >= 5 then
    raise exception 'Too many recent runs for this display name';
  end if;

  insert into public.solo_scores (
    player_name,
    score,
    correct_answers,
    total_duration_ms
  ) values (
    v_name,
    v_score,
    v_correct,
    v_total_duration
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.submit_solo_score(text, integer[], boolean[]) from public;
grant execute on function public.submit_solo_score(text, integer[], boolean[]) to anon, authenticated;
