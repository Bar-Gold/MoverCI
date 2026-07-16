# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A single [Woodpecker CI](https://woodpecker-ci.org/) pipeline (`.woodpecker.yaml`) that
one-way syncs selected Helm chart paths from a **dev** git repo into a **separate production
Bitbucket repository**. It is a **central mover**: it lives in this one repo and can sync any
dev→prod pair, driven entirely by per-run parameters — the target repos need no config of
their own. There is no application code, build, or test suite for the sync itself — the
entire deliverable is the pipeline definition.

The repo also has one unrelated utility script, `encode.py`, which packs an arbitrary file
into a PNG (pure stdlib, no real steganography — it just serializes bytes into pixel data with
a header row). `.woodpecker_encoded.png` is a sample output from running it against
`.woodpecker.yaml`. Neither file is read by, or affects, the pipeline — don't assume they're
part of the sync mechanism.

## How the pipeline runs

- Trigger: **manual only** (`event: manual`). Each run is dispatched against a specific
  dev→prod pair by overriding the `environment:` values as manual parameters.
- `skip_clone: true` — there is **no implicit clone**; the pipeline needs no checkout of
  itself. The single step `sync-to-prod` (in an `alpine/git` container) **clones the dev
  (source) repo explicitly** with `git clone --branch $DEV_BRANCH $DEV_URL src`, then adds
  `prod` as a second remote and fetches it. A full clone pulls **all tags** — no partial/tags
  workaround needed.
- Two tokens, both Woodpecker secrets: `DEV_TOKEN` (`dev_token`, read the source) and
  `PROD_TOKEN` (`prod_token`, write the target), each passed as an `Authorization: Bearer`
  HTTP header (`$DEV_AUTH` / `$PROD_AUTH`) — never in the remote URL. Store them as org-level
  secrets so they're configured once. If one account can read dev and write prod, both may
  point at the same secret.
- Every run commits and pushes to prod directly (no dry-run / preview mode).

### Running it against a repo

Trigger manually and override, per target: `DEV_URL`, `PROD_URL`, and — if not `master` —
`DEV_BRANCH` / `PROD_BRANCH` / `SYNC_PATHS`. Nothing is stored in the target repos.

## Sync model (the part that needs reading carefully)

The dev and prod repos have **unrelated histories**, so there is no git merge. The sync is
**additive-only**: it copies new dev files into prod and never modifies or deletes existing
prod content. Work happens inside the freshly cloned `src/` dir, on branch `_sync_work`
checked out from `prod/${PROD_BRANCH}`. `DEV_REF` (the dev branch HEAD, captured before the
prod checkout) is the source of truth for dev content.

For each file under a path in `SYNC_PATHS`:
- **dev-only** → added and staged.
- **in both, identical** → nothing.
- **in both, but different** → a unified diff is printed to the build log and **prod is left
  unchanged** (drift is reported, never overwritten).
- **prod-only** → left untouched (dev never deletes prod content).

Tags are pushed additively, each logged with the commit it points to: existing tags on prod
are skipped, **no `--force`**, nothing is ever overwritten.

After the push, the step re-fetches `prod` and verifies every dev file under `SYNC_PATHS` is
actually present there, failing the build (`exit 1`) if `SYNC_PATHS` matched nothing or any
file didn't land — so a mistyped path or a push that silently didn't take effect shows up as a
failed run, not a falsely-green one.

## Editing conventions

- Every command block is `set -eu`; keep new logic fail-fast.
- The env block holds **per-run** values (`DEV_URL`/`DEV_BRANCH`, `PROD_URL`/`PROD_BRANCH`,
  `SYNC_PATHS`, bot identity); the defaults are placeholders — real targets come from manual
  parameters. `SYNC_PATHS` is a space-separated list of top-level paths.
- All commands run in **one shell** (Woodpecker concatenates them), so `cd src`, `DEV_REF`,
  and `$DEV_AUTH`/`$PROD_AUTH` set in early entries persist through the later blocks. Don't
  split the step assuming otherwise.
- Commit messages the pipeline generates include `[ci skip]` to avoid retriggering.
- Preserve the non-destructive guarantees above (additive-only, no tag force, prod-only
  files untouched, differing files logged-not-overwritten) — they are the point of this tool.

## Where the dev repo comes from

`skip_clone: true` disables Woodpecker's implicit clone, so **the pipeline clones the source
itself**: `git clone --branch $DEV_BRANCH $DEV_URL src`. This is what lets one central repo
serve many targets — the source is a parameter, not "whatever triggered the build." A full
clone includes all tags, so `git tag` lists the dev tags directly. The prod repo is never
cloned — only added as a remote (`git remote add prod …`) and fetched.
