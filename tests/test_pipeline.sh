#!/bin/sh
# Integration test for the sync-to-prod step in .woodpecker.yaml.
#
# There's no Woodpecker agent available here, so this doesn't run the
# pipeline through Woodpecker itself - it extracts the *actual* commands
# from .woodpecker.yaml (via PyYAML, so this can't drift into testing a
# reimplementation) and runs them with the local git/sh, which is all the
# step's alpine/git image provides anyway. Local bare git repos stand in
# for the dev/prod Bitbucket remotes; DEV_TOKEN/PROD_TOKEN are dummy
# values since local (non-http) transport ignores the auth header.
set -eu

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
WOODPECKER_YAML="$REPO_ROOT/.woodpecker.yaml"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Sandbox git's global config so this never touches the real user's
# ~/.gitconfig - the pipeline itself runs `git config --global ...`.
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
: > "$GIT_CONFIG_GLOBAL"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  OK   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

# ---- extract the real pipeline commands ------------------------------------
COMMANDS_SH="$WORK/commands.sh"
python -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
cmds = d["steps"]["sync-to-prod"]["commands"]
print("\n".join(cmds))
' "$WOODPECKER_YAML" > "$COMMANDS_SH"

run_pipeline() {
  # run_pipeline <dev_url> <dev_branch> <prod_url> <prod_branch> <sync_paths>
  ( set -eu
    RUN_DIR=$(mktemp -d "$WORK/run.XXXXXX")
    cd "$RUN_DIR"
    export DEV_URL="$1" DEV_BRANCH="$2" PROD_URL="$3" PROD_BRANCH="$4"
    export SYNC_PATHS="$5" BOT_NAME=test-bot BOT_EMAIL=test-bot@example.com
    export DEV_TOKEN=dummy-dev-token PROD_TOKEN=dummy-prod-token
    sh "$COMMANDS_SH"
  )
}

# ---- seed dev/prod bare repos (unrelated histories, like the real thing) ---
DEV_BARE="$WORK/dev.git"
PROD_BARE="$WORK/prod.git"
git init -q --bare "$DEV_BARE"
git init -q --bare "$PROD_BARE"

DEV_SEED="$WORK/dev_seed"
git init -q -b master "$DEV_SEED"
git -C "$DEV_SEED" config user.name  seed
git -C "$DEV_SEED" config user.email seed@example.com
mkdir -p "$DEV_SEED/HelmCharts" "$DEV_SEED/chart"
echo "dev-only content" > "$DEV_SEED/HelmCharts/dev-only.yaml"
echo "same content"     > "$DEV_SEED/HelmCharts/same.yaml"
echo "dev version"      > "$DEV_SEED/HelmCharts/differs.yaml"
echo "chart dev-only"   > "$DEV_SEED/chart/dev-only.yaml"
git -C "$DEV_SEED" add -A
git -C "$DEV_SEED" commit -q -m "dev seed"
git -C "$DEV_SEED" tag v1.0.0
git -C "$DEV_SEED" tag shared-tag
git -C "$DEV_SEED" push -q "$DEV_BARE" master --tags

PROD_SEED="$WORK/prod_seed"
git init -q -b master "$PROD_SEED"
git -C "$PROD_SEED" config user.name  seed
git -C "$PROD_SEED" config user.email seed@example.com
mkdir -p "$PROD_SEED/HelmCharts"
echo "same content"      > "$PROD_SEED/HelmCharts/same.yaml"
echo "prod version"      > "$PROD_SEED/HelmCharts/differs.yaml"
echo "prod-only content" > "$PROD_SEED/HelmCharts/prod-only.yaml"
git -C "$PROD_SEED" add -A
git -C "$PROD_SEED" commit -q -m "prod seed"
git -C "$PROD_SEED" tag shared-tag
git -C "$PROD_SEED" push -q "$PROD_BARE" master --tags

PROD_SHARED_TAG_BEFORE=$(git -C "$PROD_SEED" rev-parse shared-tag)

# ============================================================================
echo "== Run 1: normal sync =="
OUT1=$(run_pipeline "$DEV_BARE" master "$PROD_BARE" master "HelmCharts chart" 2>&1) && RC1=0 || RC1=$?
[ "$RC1" = 0 ] && ok "run succeeds" || { bad "run succeeds (exit $RC1)"; echo "$OUT1" | sed 's/^/    /'; }

VERIFY1="$WORK/verify1"
git clone -q --branch master "$PROD_BARE" "$VERIFY1"

[ "$(cat "$VERIFY1/HelmCharts/dev-only.yaml" 2>/dev/null)" = "dev-only content" ] \
  && ok "dev-only file added" || bad "dev-only file added"
[ "$(cat "$VERIFY1/chart/dev-only.yaml" 2>/dev/null)" = "chart dev-only" ] \
  && ok "dev-only file added (2nd SYNC_PATHS entry)" || bad "dev-only file added (2nd SYNC_PATHS entry)"
[ "$(cat "$VERIFY1/HelmCharts/same.yaml" 2>/dev/null)" = "same content" ] \
  && ok "identical file left alone" || bad "identical file left alone"
[ "$(cat "$VERIFY1/HelmCharts/differs.yaml" 2>/dev/null)" = "prod version" ] \
  && ok "differing file NOT overwritten" || bad "differing file NOT overwritten"
[ "$(cat "$VERIFY1/HelmCharts/prod-only.yaml" 2>/dev/null)" = "prod-only content" ] \
  && ok "prod-only file untouched" || bad "prod-only file untouched"

echo "$OUT1" | grep -q "DIFFERS (prod kept unchanged): HelmCharts/differs.yaml" \
  && ok "diff logged for differing file" || bad "diff logged for differing file"

git -C "$VERIFY1" log -1 --pretty=%s | grep -q '\[ci skip\]' \
  && ok "commit message contains [ci skip]" || bad "commit message contains [ci skip]"

git -C "$VERIFY1" fetch -q --tags
git -C "$VERIFY1" rev-parse v1.0.0 >/dev/null 2>&1 \
  && ok "new dev-only tag pushed to prod" || bad "new dev-only tag pushed to prod"

PROD_SHARED_TAG_AFTER=$(git -C "$VERIFY1" rev-parse shared-tag)
[ "$PROD_SHARED_TAG_BEFORE" = "$PROD_SHARED_TAG_AFTER" ] \
  && ok "existing tag not overwritten (no --force)" || bad "existing tag not overwritten (no --force)"

echo "$OUT1" | grep -q "Verified: all .* dev file(s) under SYNC_PATHS are present" \
  && ok "post-push verification step reported success" || bad "post-push verification step reported success"

# ============================================================================
echo "== Run 2: re-run is a no-op (idempotency) =="
OUT2=$(run_pipeline "$DEV_BARE" master "$PROD_BARE" master "HelmCharts chart" 2>&1) && RC2=0 || RC2=$?
[ "$RC2" = 0 ] && ok "second run succeeds" || { bad "second run succeeds (exit $RC2)"; echo "$OUT2" | sed 's/^/    /'; }
echo "$OUT2" | grep -q "No new files to add to prod." \
  && ok "second run makes no new commit" || bad "second run makes no new commit"

# ============================================================================
echo "== Run 3: SYNC_PATHS matching nothing must fail loudly =="
OUT3=$(run_pipeline "$DEV_BARE" master "$PROD_BARE" master "NoSuchPath" 2>&1) && RC3=0 || RC3=$?
[ "$RC3" != 0 ] && ok "empty SYNC_PATHS match fails the build" || bad "empty SYNC_PATHS match fails the build"
echo "$OUT3" | grep -q "no files matched SYNC_PATHS" \
  && ok "empty match produces a clear error" || bad "empty match produces a clear error"

# ============================================================================
echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
