#!/usr/bin/env bash
# Reproduces: pnpm resolves "*" to a prerelease `latest` dist-tag, then its own
# lockfile freshness check says that version does not satisfy "*".
#
# Usage: ./repro.sh [--npm] [pnpm-version]
#   ./repro.sh 12.16.1
#   ./repro.sh --npm 11.28.9     # also run the npm equivalents
#   PORT=7680 WORK=/tmp/w ./repro.sh   # another port and work dir
#
# Starts a throwaway pnpr registry on 127.0.0.1, publishes made-up @demo/* packages
# in two rounds (an npm lockfile is written between them), then runs, per case:
#   pnpm install; pnpm install and pnpm install --frozen-lockfile in a clean checkout;
#   pnpm install --frozen-lockfile, pnpm approve-builds --all and pnpm rebuild in place;
#   pnpm import from the older npm lockfile, then pnpm install --frozen-lockfile.
# Exits 1 if a lockfile written by `pnpm install` is rejected by `--frozen-lockfile` in a clean checkout.
set -euo pipefail

RUN_NPM=false
PNPM_VERSION=12.16.1
for arg in "$@"; do
  case "$arg" in
    --npm) RUN_NPM=true ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) PNPM_VERSION="$arg" ;;
  esac
done
PNPR_VERSION="0.1.0-alpha.17"
ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$ROOT/.work}"
PORT="${PORT:-7677}"
REGISTRY="http://127.0.0.1:$PORT/npm/"
AUTH="--//127.0.0.1:$PORT/npm/:_authToken=unused"

rm -rf "$WORK"
mkdir -p "$WORK"
# Keep npm away from the user's config and cache.
export npm_config_userconfig="$WORK/npmrc-user" npm_config_cache="$WORK/npm-cache"
export npm_config_audit=false npm_config_fund=false npm_config_update_notifier=false
: > "$npm_config_userconfig"
# CI=true would turn on --frozen-lockfile by default.
unset CI GITHUB_ACTIONS

echo "== tools"
npm install --silent --no-save --prefix "$WORK/tools" --registry https://registry.npmjs.org/ \
  "pnpm@$PNPM_VERSION" "@pnpm/pnpr@$PNPR_VERSION" semver@7 >/dev/null
PNPM="$WORK/tools/node_modules/.bin/pnpm"
PNPR="$WORK/tools/node_modules/.bin/pnpr"
SEMVER_VERSION="$(node -p "require('$WORK/tools/node_modules/semver/package.json').version")"
echo "pnpm $("$PNPM" --version), $("$PNPR" --version), npm $(npm --version), node $(node --version)," \
  "semver $SEMVER_VERSION, $(uname -sm)"

echo "== start pnpr on $REGISTRY"
"$PNPR" -c "$ROOT/pnpr.yaml" --listen "127.0.0.1:$PORT" --storage "$WORK/pnpr-storage" > "$WORK/pnpr.log" 2>&1 &
PNPR_PID=$!
trap 'kill $PNPR_PID 2>/dev/null || true' EXIT
for _ in $(seq 50); do
  curl -sf "http://127.0.0.1:$PORT/-/ping" >/dev/null && break
  sleep 0.2
done

# publish <name> <version> <dist-tag> [postinstall]
publish() {
  local dir="$WORK/pkgs/$1@$2"
  mkdir -p "$dir"
  (cd "$dir" && node -e '
    const [name, version, postinstall] = process.argv.slice(1)
    const pkg = { name, version, license: "MIT", main: "index.js" }
    if (postinstall) pkg.scripts = { postinstall }
    require("fs").writeFileSync("package.json", JSON.stringify(pkg, null, 2) + "\n")
    require("fs").writeFileSync("index.js", `module.exports = ${JSON.stringify(version)}\n`)
  ' "$1" "$2" "${4:-}")
  (cd "$dir" && npm publish --silent --registry "$REGISTRY" --tag "$3" "$AUTH" >/dev/null)
  echo "  $1@$2 (tag $3)"
}

# Cases: the package each case depends on. Ranges: what package.json asks for.
CASES=(only-pre pre-over-stable stable-latest)
RANGES=('*' '' 'x' '>=0' 'latest')

# write_project <dir> <case> <range> : package.json and .npmrc
write_project() {
  mkdir -p "$1"
  node -e '
    const [name, range] = process.argv.slice(1)
    const pkg = { name: "app", version: "1.0.0", private: true,
      dependencies: { [name]: range, "@demo/needs-build": "1.0.0" } }
    require("fs").writeFileSync(process.argv[3] + "/package.json", JSON.stringify(pkg, null, 2) + "\n")
  ' "@demo/$2" "$3" "$1"
  echo "registry=$REGISTRY" > "$1/.npmrc"
}

# Prints the version pnpm-lock.yaml (in the current dir) locks for @demo/<case>.
pnpm_locked() {
  [ -f pnpm-lock.yaml ] || { echo "(no lock)"; return; }
  awk -v dep="'@demo/$1':" '$1 == dep { found = 1; next } found && $1 == "version:" { print $2; exit }' pnpm-lock.yaml
}
# Prints the version package-lock.json (in the current dir) locks for @demo/<case>.
npm_locked() {
  [ -f package-lock.json ] || { echo "(no lock)"; return; }
  node -p "(require('./package-lock.json').packages['node_modules/@demo/$1'] || {}).version || '(none)'"
}
# err_of <log> : the first ERR_PNPM_* / npm error code in a log, or "failed".
err_of() {
  grep -m1 -oE 'ERR_PNPM_[A-Z_]+|npm error code [A-Z_]+|ETARGET|ELSPROBLEMS|EUSAGE' "$1" | sed 's/npm error code //' \
    || echo failed
}
# result <log> <command...> : runs the command, prints "ok" or its error code.
result() {
  local log="$1"; shift
  if "$@" > "$log" 2>&1; then echo ok; else err_of "$log"; fi
}
# workspace_yaml <dir> : a shared store, a cache of its own, no release-age gate, and builds
# left for approve-builds.
workspace_yaml() {
  printf 'storeDir: %s\ncacheDir: %s\nminimumReleaseAge: 0\nstrictDepBuilds: false\n' \
    "$WORK/store" "$1/.cache" > "$1/pnpm-workspace.yaml"
}
# checkout <project> <dir> : what a clean clone of <project> has (no node_modules).
checkout() {
  mkdir -p "$2"
  cp "$1/package.json" "$1/pnpm-lock.yaml" "$1/.npmrc" "$2/"
  workspace_yaml "$2"
}
show_range() { [ -n "$1" ] && echo "\`$1\`" || echo '`""`'; }

echo "== round 1 (before the older npm lockfile is written)"
publish @demo/only-pre 1.0.0-alpha.0 latest
publish @demo/pre-over-stable 1.0.0 latest
publish @demo/stable-latest 1.0.0 latest
publish @demo/needs-build 1.0.0 latest "node -e \"require('fs').writeFileSync('built.txt', '')\""

echo "== the older npm lockfiles (npm install --package-lock-only, round 1)"
declare -A OLD
for c in "${CASES[@]}"; do
  for i in "${!RANGES[@]}"; do
    d="$WORK/npm-old/$c-$i"
    write_project "$d" "$c" "${RANGES[$i]}"
    (cd "$d" && npm install --package-lock-only > npm.log 2>&1) || true
    OLD[$c-$i]="$(cd "$d" && npm_locked "$c")"
  done
done

echo "== round 2"
publish @demo/only-pre 1.0.0-alpha.1 latest
publish @demo/pre-over-stable 2.0.0-alpha.0 latest
publish @demo/stable-latest 1.0.1 latest
publish @demo/stable-latest 1.1.0-beta.0 next
publish_parent() {
  local dir="$WORK/pkgs/@demo/parent@1.0.0"
  mkdir -p "$dir"
  (cd "$dir" && node -e '
    const deps = Object.fromEntries(process.argv.slice(1).map((c) => ["@demo/" + c, "*"]))
    const pkg = { name: "@demo/parent", version: "1.0.0", license: "MIT", dependencies: deps }
    require("fs").writeFileSync("package.json", JSON.stringify(pkg, null, 2) + "\n")
  ' "${CASES[@]}" && npm publish --silent --registry "$REGISTRY" --tag latest "$AUTH" >/dev/null)
  echo "  @demo/parent@1.0.0 (tag latest), depends on each case package with \"*\""
}
publish_parent
for c in "${CASES[@]}"; do
  echo "  dist-tags of @demo/$c: $(npm view --registry "$REGISTRY" "@demo/$c" dist-tags --json | tr -d ' \n')"
done

echo
echo "== node-semver $SEMVER_VERSION: does the \`latest\` version satisfy the range?"
echo
echo "| version | range | satisfies | { loose } | { includePrerelease } |"
echo "|---|---|---|---|---|"
for v in 1.0.0-alpha.1 2.0.0-alpha.0 1.0.1; do
  for r in '*' '' 'x' '>=0'; do
    node -e '
      const s = require(process.argv[1]); const [v, r] = process.argv.slice(2)
      console.log(`| ${v} | ${r ? "`" + r + "`" : "`\"\"`"} | ${s.satisfies(v, r)} | ${s.satisfies(v, r, { loose: true })} | ${s.satisfies(v, r, { includePrerelease: true })} |`)
    ' "$WORK/tools/node_modules/semver" "$v" "$r"
  done
done

REPRODUCED=false
echo
echo "== pnpm $("$PNPM" --version)"
echo "Logs: ${WORK#"$ROOT"/}/pnpm/<case>-<n>/*.log"
echo
echo "| case | range | install locks | checkout: install sees lock as fresh | checkout: --frozen-lockfile | --frozen-lockfile, node_modules present | approve-builds --all | postinstall ran | rebuild | import: npm lock → pnpm lock | frozen after import |"
echo "|---|---|---|---|---|---|---|---|---|---|---|"
for c in "${CASES[@]}"; do
  for i in "${!RANGES[@]}"; do
    d="$WORK/pnpm/$c-$i"
    write_project "$d" "$c" "${RANGES[$i]}"
    workspace_yaml "$d"
    cd "$d"
    install=$(result install.log "$PNPM" install)
    [ "$install" = ok ] && install="$(pnpm_locked "$c")"
    fresh="-"; frozen="-"; frozen_nm="-"; approve="-"; built="-"; rebuild="-"
    if [ -f pnpm-lock.yaml ]; then
      # A clean checkout: pnpm skips resolution only for a lockfile it sees as fresh.
      checkout "$d" "$d-checkout-install"
      (cd "$d-checkout-install" && "$PNPM" install > install.log 2>&1) || true
      if grep -q 'Lockfile is up to date, resolution step is skipped' "$d-checkout-install/install.log"; then
        fresh=yes
      else
        fresh="**no** (resolves again)"
      fi
      checkout "$d" "$d-checkout-frozen"
      frozen=$(cd "$d-checkout-frozen" && result frozen.log "$PNPM" install --frozen-lockfile)
      frozen_nm=$(result frozen.log "$PNPM" install --frozen-lockfile)
      approve=$(result approve-builds.log "$PNPM" approve-builds --all)
      [ -f node_modules/@demo/needs-build/built.txt ] && built=yes || built=no
      [ "$built" = no ] && grep -q needs-build pnpm-workspace.yaml && built="no (allowBuilds saved)"
      rebuild=$(result rebuild.log "$PNPM" rebuild)
      if [ "$frozen" != ok ]; then REPRODUCED=true; frozen="**$frozen**"; fi
      [ "$frozen_nm" != ok ] && frozen_nm="**$frozen_nm**"
      [ "$approve" != ok ] && approve="**$approve**"
      [ "$rebuild" != ok ] && rebuild="**$rebuild**"
    fi
    # pnpm import from the npm lockfile written in round 1, then a frozen install.
    imp="-"; imp_frozen="-"
    if [ -f "$WORK/npm-old/$c-$i/package-lock.json" ]; then
      di="$WORK/pnpm/$c-$i-import"
      write_project "$di" "$c" "${RANGES[$i]}"
      workspace_yaml "$di"
      cp "$WORK/npm-old/$c-$i/package-lock.json" "$di/"
      cd "$di"
      imp=$(result import.log "$PNPM" import)
      [ "$imp" = ok ] && imp="${OLD[$c-$i]} → $(pnpm_locked "$c")"
      [ -f pnpm-lock.yaml ] && imp_frozen=$(result frozen.log "$PNPM" install --frozen-lockfile)
      [ "$imp_frozen" != ok ] && [ "$imp_frozen" != - ] && imp_frozen="**$imp_frozen**"
    fi
    echo "| $c | $(show_range "${RANGES[$i]}") | $install | $fresh | $frozen | $frozen_nm | $approve | $built | $rebuild | $imp | $imp_frozen |"
    cd "$ROOT"
  done
done

# transitive_project <dir> : depends on @demo/parent only, so each "*" is a transitive range.
transitive_project() {
  mkdir -p "$1"
  printf '{ "name": "app", "version": "1.0.0", "private": true, "dependencies": { "@demo/parent": "1.0.0" } }\n' \
    > "$1/package.json"
  echo "registry=$REGISTRY" > "$1/.npmrc"
}
echo
echo "== pnpm, transitive \"*\" (through @demo/parent)"
d="$WORK/pnpm/transitive"
transitive_project "$d"
workspace_yaml "$d"
(cd "$d" && "$PNPM" install > install.log 2>&1) || true
picks=""
for c in "${CASES[@]}"; do
  picks="$picks @demo/$c $(grep -oE "^  '@demo/$c@[^']+'" "$d/pnpm-lock.yaml" | head -1 | sed -E "s/.*@([^@']+)'$/\1/"),"
done
checkout "$d" "$d-checkout-frozen"
echo "locks:${picks%,}; --frozen-lockfile in a clean checkout: $(cd "$d-checkout-frozen" && result frozen.log "$PNPM" install --frozen-lockfile)"

if [ "$RUN_NPM" = true ]; then
  echo
  echo "== npm $(npm --version)"
  echo "Logs: ${WORK#"$ROOT"/}/npm/<case>-<n>/*.log"
  echo
  echo "| case | range | npm install locks | npm ci | npm ls | npm rebuild | older lock (round 1) | npm ci with it | npm ls with it |"
  echo "|---|---|---|---|---|---|---|---|---|"
  for c in "${CASES[@]}"; do
    for i in "${!RANGES[@]}"; do
      d="$WORK/npm/$c-$i"
      write_project "$d" "$c" "${RANGES[$i]}"
      cd "$d"
      install=$(result install.log npm install)
      [ "$install" = ok ] && install="$(npm_locked "$c")"
      ci="-"; ls_="-"; rb="-"
      if [ -f package-lock.json ]; then
        ci=$(result ci.log npm ci)
        ls_=$(result ls.log npm ls --all)
        rb=$(result rebuild.log npm rebuild)
      fi
      old="${OLD[$c-$i]}"; oci="-"; ols="-"
      if [ -f "$WORK/npm-old/$c-$i/package-lock.json" ]; then
        do_="$WORK/npm/$c-$i-old"
        write_project "$do_" "$c" "${RANGES[$i]}"
        cp "$WORK/npm-old/$c-$i/package-lock.json" "$do_/"
        cd "$do_"
        oci=$(result ci.log npm ci)
        ols=$(result ls.log npm ls --all)
      else
        old="$(err_of "$WORK/npm-old/$c-$i/npm.log")"
      fi
      echo "| $c | $(show_range "${RANGES[$i]}") | $install | $ci | $ls_ | $rb | $old | $oci | $ols |"
      cd "$ROOT"
    done
  done
  echo
  echo "== npm, transitive \"*\" (through @demo/parent)"
  d="$WORK/npm/transitive"
  transitive_project "$d"
  cd "$d"
  install=$(result install.log npm install)
  picks=""
  for c in "${CASES[@]}"; do picks="$picks @demo/$c $(npm_locked "$c"),"; done
  echo "npm install: $install; locks:${picks%,}; npm ci: $(result ci.log npm ci); npm ls: $(result ls.log npm ls --all)"
  cd "$ROOT"
fi

echo
if [ "$REPRODUCED" = true ]; then
  echo "RESULT: reproduced: a lockfile written by pnpm install is rejected by pnpm install --frozen-lockfile in a clean checkout"
  exit 1
fi
echo "RESULT: not reproduced"
