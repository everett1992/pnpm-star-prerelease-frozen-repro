#!/usr/bin/env bash
# Usage: ./repro.sh [pnpm-version]    (default 12.16.1)
#
# Starts pnpr (pnpm's registry server) on 127.0.0.1:7677 and publishes only-pre/:
# @demo/only-pre has one version, 1.0.0-alpha.0, which is `latest`, and a postinstall script.
# Then runs pnpm on a copy of package.json and .npmrc in .work/app.
# Exits 1 if pnpm rejects the lockfile it wrote, 0 if it accepts it, and 2 if the setup fails.
set -uo pipefail

VERSION="${1:-12.16.1}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="$ROOT/.work"
REGISTRY="http://127.0.0.1:7677/npm/"

rm -rf "$WORK" && mkdir -p "$WORK/app"
# Keep the user's npm and pnpm config, store and cache out of it. CI=true would turn on --frozen-lockfile.
unset CI GITHUB_ACTIONS
export XDG_CONFIG_HOME="$WORK/config" XDG_DATA_HOME="$WORK/data" XDG_CACHE_HOME="$WORK/cache"
export npm_config_userconfig="$WORK/npmrc" npm_config_cache="$WORK/npm-cache"
: > "$npm_config_userconfig"

fail() { echo "setup failed: $*"; exit 2; }
npm install --silent --no-save --prefix "$WORK/tools" --registry https://registry.npmjs.org/ \
  "pnpm@$VERSION" @pnpm/pnpr@0.1.0-alpha.17 >/dev/null || fail "npm install"
PNPM="$WORK/tools/node_modules/.bin/pnpm"

"$WORK/tools/node_modules/.bin/pnpr" -c "$ROOT/pnpr.yaml" --listen 127.0.0.1:7677 --storage "$WORK/pnpr-storage" \
  > "$WORK/pnpr.log" 2>&1 &
PNPR_PID=$!
trap 'kill $PNPR_PID 2>/dev/null' EXIT
for _ in $(seq 50); do curl -sf "${REGISTRY%npm/}-/ping" >/dev/null && break; sleep 0.2; done
(cd "$ROOT/only-pre" && npm publish --tag latest --registry "$REGISTRY" "--${REGISTRY#http:}:_authToken=unused") \
  > "$WORK/publish.log" 2>&1 || fail "npm publish, see .work/publish.log"

cp "$ROOT/package.json" "$ROOT/.npmrc" "$WORK/app/"
cd "$WORK/app"

# step <command...>: runs pnpm, prints ok or its error code and failure reason, and sets $ERR.
step() {
  echo "\$ pnpm $*"
  if "$PNPM" "$@" > "$WORK/step.log" 2>&1; then
    ERR=ok
    echo "  ok"
  else
    ERR="$(grep -m1 -oE 'ERR_PNPM_[A-Z_]+' "$WORK/step.log" || echo "failed, see .work/step.log")"
    echo "  $ERR"
    reason="$(awk '/Failure reason/ { f = 1; next } f && (/^ *$/ || /help:/) { exit } f' "$WORK/step.log" |
      tr -s ' \n' ' ' | sed 's/^ *//;s/ *$//')"
    [ -n "$reason" ] && echo "  $reason"
  fi
}

echo "pnpm $("$PNPM" --version), node $(node --version)"

# The postinstall waits for approve-builds, so this fails, but it writes the lockfile and node_modules.
step install
[ "$ERR" = ERR_PNPM_IGNORED_BUILDS ] || fail "expected ERR_PNPM_IGNORED_BUILDS"
echo "  locked @demo/only-pre $(grep -A2 "'@demo/only-pre':" pnpm-lock.yaml | awk '/version:/ { print $2 }')"
cp pnpm-lock.yaml "$WORK/written.yaml"

step approve-builds --all
grep -q "'@demo/only-pre': true" pnpm-workspace.yaml 2>/dev/null &&
  echo "  allowBuilds saved in pnpm-workspace.yaml" || echo "  allowBuilds not saved"
[ -f node_modules/@demo/only-pre/built.txt ] && echo "  postinstall ran" || echo "  postinstall did not run"

step rebuild

rm -rf node_modules # a clean checkout
step install --frozen-lockfile
FROZEN="$ERR"

step install --lockfile-only # what the v12 error message suggests
cmp -s "$WORK/written.yaml" pnpm-lock.yaml && echo "  wrote the same lockfile" || echo "  wrote a different lockfile"

[ "$FROZEN" = ok ] && exit 0 || exit 1
