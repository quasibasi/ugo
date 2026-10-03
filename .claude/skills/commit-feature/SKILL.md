---
name: commit-feature
description: Commit and push each finished feature or fix in Ugo on its own. Use as soon as a feature, fix or design change builds and is installed, before starting the next one, and whenever the user asks to commit or push.
---

# Commit and push every feature separately

Each feature or fix gets its own commit, pushed right away. Never let two
features pile up in the working tree, and never fold one into another's
commit.

## When

- A feature, fix or design change is done: `scripts/build.sh release --install --run`
  succeeds and the README matches what changed.
- Before starting on the next request, if the last one left changes uncommitted.
- When the user asks to commit or push.

Do not commit work that does not build.

## How

1. Look at what changed: `git status --short` and `git diff`.
2. Stage only the files this feature touched, by path. Several Claude
   sessions work in this repo at once, so `git add -A` or `git add .` can
   sweep another session's half-done work into this commit. If a file holds
   changes from two features, stage just this feature's hunks or ask the user.
3. Commit with a message whose first line says what the user gets, in the
   imperative and under 70 characters (`Merge folders and notes into one sidebar`),
   then a short body on what changed and why. End it with the attribution
   lines the session gives for commits.
4. Bring in any commits pushed meanwhile: `git fetch origin`, and only if
   `git status -sb` shows `main` behind `origin/main`, run
   `git pull --rebase --autostash origin main`. The `--autostash` matters:
   other sessions usually have uncommitted edits in the tree, and a plain
   rebase refuses to run. Resolve conflicts, rebuild if the rebase touched
   Swift files.
5. Push: `git push origin main`.
6. Tell the user the commit hash and its first line.

Ugo works straight on `main`; there are no feature branches or pull
requests unless the user asks for them.
