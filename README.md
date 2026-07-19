# Hilo

A fast **higher or lower** game with pass-the-phone multiplayer and a timed solo sprint.

## Play

Once GitHub Pages finishes its first deployment, open:

**https://coopdawg73.github.io/Hilo/**

No account, login, download, or backend is required.

## How it works

1. Enter both players' names and choose the number of rounds.
2. Pass the phone to the named player.
3. Answer the round's plain-English comparison with choices such as taller/shorter, faster/slower, or more/fewer.
4. Score a point for each correct answer. Most points wins.

Questions, card direction, and answer wording change from round to round. Rematches also alternate the starting player to keep things fair.

## Solo sprint

- 10 ranked questions per run
- 14-second timer on every question
- Up to 1,000 points per correct answer
- Faster correct answers earn more points, with a 100-point floor
- Global rankings sort by score and then total answer time

Without Supabase configuration, the leaderboard automatically works as a local preview on the current device.

## Supabase leaderboard setup

1. Run [`supabase/setup.sql`](supabase/setup.sql) in the Supabase SQL editor.
2. Add the project's public URL and publishable/anon key to `config.js`.
3. Never place a `service_role` or secret key in this public repository.

Row-level security allows public leaderboard reads while direct table writes remain blocked. Ranked submissions go through a validation function that recalculates the score from all 10 answer times.

GitHub Actions publishes every update to GitHub Pages.
