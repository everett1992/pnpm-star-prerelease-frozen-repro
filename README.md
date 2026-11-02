# pnpm: `*` resolves to a prerelease `latest`, then pnpm's own lockfile check rejects it

A minimal reproduction for a pnpm bug, with the npm behaviour next to it.
When every published version of a package is a prerelease, pnpm resolves a `*` dependency to the `latest` dist-tag.
It does this on purpose (pnpm/pnpm#865), and npm does the same.
pnpm's lockfile freshness check then tests the locked version with plain semver,
where a prerelease never satisfies `*`.
So pnpm writes a lockfile that it then calls outdated:

```
ERR_PNPM_OUTDATED_LOCKFILE
  Cannot install with "frozen-lockfile" because pnpm-lock.yaml is not up to date with package.json.
  Failure reason:
  the importer resolution is broken at dependency "@demo/only-pre": version "1.0.0-alpha.1" doesn't satisfy range "*"
```

`pnpm install --frozen-lockfile` fails in a clean checkout on pnpm 11 and 12.
On pnpm 12, `pnpm approve-builds` and `pnpm rebuild` fail the same way, because they always run the frozen install.

## Run it

```sh
./repro.sh                # pnpm 12.16.1
./repro.sh 11.28.9        # any pnpm version
./repro.sh --npm 12.17.0  # also run the npm equivalents
```

Needs Node.js, npm, curl and network access to registry.npmjs.org (for pnpm, pnpr and semver).
The script exits 1 when the bug reproduces.
Everything it creates goes in `.work/`, and the logs of each step are kept there.
The full output of the runs below is in [`results/`](results).

## What the script does

1. Installs the requested pnpm, [pnpr](https://github.com/pnpm/pnpm/tree/main/pnpr) 0.1.0-alpha.17
   (pnpm's registry server) and semver into `.work/tools`.
2. Starts pnpr on `127.0.0.1:7677` with [`pnpr.yaml`](pnpr.yaml).
   It hosts `@demo/*` and proxies nothing.
3. Publishes round 1, then writes an npm lockfile for each project with `npm install --package-lock-only`.
   These are the "older npm lockfiles" that `pnpm import` reads later.
4. Publishes round 2.
   The end state is:

   | package | versions | `latest` | case |
   |---|---|---|---|
   | `@demo/only-pre` | 1.0.0-alpha.0, 1.0.0-alpha.1 | 1.0.0-alpha.1 | prerelease `latest`, no stable release |
   | `@demo/pre-over-stable` | 1.0.0, 2.0.0-alpha.0 | 2.0.0-alpha.0 | prerelease `latest` over an older stable |
   | `@demo/stable-latest` | 1.0.0, 1.0.1, 1.1.0-beta.0 (`next`) | 1.0.1 | the normal case |
   | `@demo/needs-build` | 1.0.0 | 1.0.0 | has a postinstall script |
   | `@demo/parent` | 1.0.0 | 1.0.0 | depends on the three case packages with `*` |

5. For each case package and each range (`*`, `""`, `x`, `>=0` and the tag `latest`),
   makes a project that depends on it with that range and on `@demo/needs-build`.
   `pnpm-workspace.yaml` sets `minimumReleaseAge: 0`, because the packages are seconds old,
   and `strictDepBuilds: false`, so that the build waits for `approve-builds` instead of failing the install.
   Then it runs:
   1. `pnpm install`, which writes the lockfile;
   2. `pnpm install` in a clean checkout (package.json, pnpm-lock.yaml, no node_modules),
      to see whether pnpm prints "Lockfile is up to date, resolution step is skipped";
   3. `pnpm install --frozen-lockfile` in another clean checkout;
   4. `pnpm install --frozen-lockfile` in the project, where node_modules is up to date;
   5. `pnpm approve-builds --all`, and whether the postinstall of `@demo/needs-build` ran;
   6. `pnpm rebuild`;
   7. `pnpm import` from the older npm lockfile, then `pnpm install --frozen-lockfile`.
6. Installs `@demo/parent`, so that each `*` is a transitive range, and runs a frozen install in a clean checkout.
7. With `--npm`: `npm install`, `npm ci`, `npm ls --all` and `npm rebuild` for the same projects,
   and `npm ci` and `npm ls --all` with the older npm lockfile.

## Findings

Linux x86_64, Node.js 26.12.0, npm 11.20.0, semver 7.8.6, pnpr 0.1.0-alpha.17.
pnpm 11.28.9 (`latest-11`), 12.14.0, 12.16.1 (`latest`) and 12.17.0 (`next-12`).
12.16.1 and 12.17.0 gave the same results in every cell.

### node-semver

In node-semver, `*`, `""`, `x` and `>=0` are the same range: `semver.validRange()` returns `*` for each.
A prerelease satisfies none of them, with or without `loose`, and all of them with `includePrerelease`.
`latest` is not a range (`validRange` returns `null`).

### npm 11.20.0

| case | `*`, `""` | `x`, `>=0` | `latest` |
|---|---|---|---|
| only-pre | 1.0.0-alpha.1 | `ETARGET` (no version) | 1.0.0-alpha.1 |
| pre-over-stable | 2.0.0-alpha.0 | 1.0.0 | 2.0.0-alpha.0 |
| stable-latest | 1.0.1 | 1.0.1 | 1.0.1 |

- `npm ci`, `npm ls --all` and `npm rebuild` pass for every lockfile that `npm install` wrote.
- They also pass with the older npm lockfile, which holds 1.0.0-alpha.0 for `*` while `latest` is 1.0.0-alpha.1.
  npm keeps a locked prerelease for `*`.
- A transitive `*` gets the same versions as a direct one.
- npm is consistent because its resolver and its validator have the same exception:
  - npm-pick-manifest 11.0.3 takes `latest` when `range === '*' || semver.satisfies(latest, range, { loose: true })`.
  - @npmcli/arborist 9.9.2 `lib/dep-valid.js`: `if (requested.fetchSpec === '*') return true`,
    and plain `semver.satisfies(child.version, fetchSpec, true)` for every other range.
  - npm-package-arg turns an empty spec into `*`.
    `x` and `>=0` are not the literal `*`, so both sides use plain semver for them.

### pnpm, direct dependencies

Each cell is the version that `pnpm install` locks, then `pnpm install --frozen-lockfile` in a clean checkout.

| case | range | 11.28.9 | 12.14.0 | 12.16.1, 12.17.0 |
|---|---|---|---|---|
| only-pre | `*` | 1.0.0-alpha.1, **OUTDATED** | 1.0.0-alpha.1, **OUTDATED** | 1.0.0-alpha.1, **OUTDATED** |
| only-pre | `""` | 1.0.0-alpha.1, **OUTDATED** | 1.0.0-alpha.1, ok | 1.0.0-alpha.1, ok |
| only-pre | `x`, `>=0` | 1.0.0-alpha.1, **OUTDATED** | `NO_MATCHING_VERSION` | `NO_MATCHING_VERSION` |
| only-pre | `latest` | 1.0.0-alpha.1, ok | 1.0.0-alpha.1, ok | 1.0.0-alpha.1, ok |
| pre-over-stable | `*` | 1.0.0, ok | 1.0.0, ok | 1.0.0, ok |
| pre-over-stable | `""` | 2.0.0-alpha.0, **OUTDATED** | 1.0.0, ok | 2.0.0-alpha.0, ok |
| pre-over-stable | `x`, `>=0` | 1.0.0, ok | 1.0.0, ok | 1.0.0, ok |
| pre-over-stable | `latest` | 2.0.0-alpha.0, ok | 2.0.0-alpha.0, ok | 2.0.0-alpha.0, ok |
| stable-latest | any | 1.0.1, ok | 1.0.1, ok | 1.0.1, ok |

OUTDATED is `ERR_PNPM_OUTDATED_LOCKFILE` with "version "…" doesn't satisfy range "…"".
Every OUTDATED row also shows "resolves again" for the plain install in a clean checkout,
and that install writes the same lockfile back.

What else fails, for `only-pre` with `*`:

| step | 11.28.9 | 12.14.0, 12.16.1, 12.17.0 |
|---|---|---|
| `pnpm install` | locks 1.0.0-alpha.1 | locks 1.0.0-alpha.1 |
| `pnpm install`, clean checkout | resolves again, same lockfile | resolves again, same lockfile |
| `pnpm install --frozen-lockfile`, clean checkout | **OUTDATED** | **OUTDATED** |
| `pnpm install --frozen-lockfile`, node_modules up to date | ok ("Already up to date") | **OUTDATED** |
| `pnpm approve-builds --all` | ok, the postinstall runs | **OUTDATED**; allowBuilds is saved, the postinstall does not run |
| `pnpm rebuild` | ok | **OUTDATED** |
| `pnpm import` (npm locked 1.0.0-alpha.0) | locks 1.0.0-alpha.1, then frozen **OUTDATED** | the same |

### pnpm, transitive `*`

On every version, `@demo/parent`'s `*` ranges lock 1.0.0-alpha.1, 2.0.0-alpha.0 and 1.0.1, as npm does.
The frozen install passes, because the freshness check only looks at a project's own dependencies.

## Analysis

### The resolver

- pnpm/pnpm#865 (2017, "manage '*' version as latest"): a `*` range failed with "No compatible version found"
  for a package that had only prereleases, where npm installed `latest`.
  The fix gives `*` the `latest` tag:
  - v11 `pnpm11/resolving/npm-resolver/src/pickPackageFromMeta.ts:229-231`:
    "Not using semver.satisfies in case of * because it does not select beta versions".
  - v12 `pnpm/crates/resolving-npm-resolver/src/pick_package_from_meta.rs:365-366`:
    `opts.version_range == "*" || semver_satisfies_loose(latest, …)`.
- That rule runs only after the preferred-version step finds nothing.
  For a direct dependency, the manifest's own range is always a preferred selector
  (v11 `pnpm11/lockfile/preferred-versions/src/index.ts:35-43`,
  v12 `pnpm/crates/lockfile-preferred-versions/src/lib.rs:105`).
  The step starts from every version that satisfies the range in plain semver
  (v11 `pickPackageFromMeta.ts:291`, v12 `pick_package_from_meta/preferred_versions.rs:96-104`),
  so for `*` it picks the highest stable version whenever there is one.
  - So a direct `*` gets `latest` only when every version is a prerelease, which is the case of pnpm/pnpm#865.
  - With an older stable release, a direct `*` gets 1.0.0, while npm, and pnpm for a transitive `*`,
    get 2.0.0-alpha.0.
- pnpm 11 reads a specifier through `version-selector-type`, which calls `semver.validRange`,
  so `x` and `>=0` reach the picker as `*` and also get a prerelease `latest`.
  pnpm 12 keeps `x` and `>=0` as written, and fails with `NO_MATCHING_VERSION`, as npm does.
- `""` behaves like the `latest` tag on 11.28.9 and 12.16.1 (it takes 2.0.0-alpha.0 over 1.0.0,
  and `pnpm import` does not keep npm's 1.0.0), and like `*` on 12.14.0.
- `pnpm import` passes npm's 1.0.0-alpha.0 as a preferred version.
  The preferred step uses plain semver, so a prerelease preference never matches `*`,
  and the pick falls through to `latest`.
  A stable preference (1.0.0) is kept.

### The freshness check

- pnpm/pnpm#9832 ("validate that the version in the lockfile satisfies the range", merged 2025-08)
  tests each locked direct dependency against its specifier:
  - v11 `pnpm11/lockfile/verification/src/satisfiesPackageManifest.ts:224-233` (`findDependencyMismatch`):
    `semver.satisfies(version, range)` on the specifier as written.
  - v12 `pnpm/crates/lockfile/src/freshness/manifest.rs:235-255` (`check_resolution_satisfies`):
    `range.satisfies(version)`.
- Neither has the resolver's exception for `*`.
  v11 has a helper for it, `versionSatisfies` in `pnpm11/lockfile/verification/src/dependencySpec.ts:10`
  (`range === '*' || …`, "This should pass the same options to semver as @pnpm/resolving.npm-resolver"),
  but `findDependencyMismatch` does not use it.
- A tag is not a range, so the check skips `latest`.
  pnpm 12's Rust parser rejects `""`, so pnpm 12 skips `""` too.
- pnpm 11 skips the check when node_modules is already up to date,
  so it fails in a clean checkout (CI) but not on a developer machine after `pnpm install`.
  pnpm 12 runs it every time.
- A plain install takes a failed check as "resolve again", gets the same version, and writes the same lockfile.
  So the lockfile is never fresh, and nothing that a user can run makes `--frozen-lockfile` pass.

### approve-builds and rebuild

- pnpm 12 runs the rebuild through the frozen install on purpose:
  `pnpm/crates/cli/src/cli_args/rebuild.rs:223` sets `install.lockfile_policy.frozen = true`,
  and `pnpm/crates/package-manager/src/install/entry_points.rs:286-293` asserts it
  ("a rebuild must take the frozen path, since the fresh-resolve path drops the rebuild selection").
  So `frozenLockfile: false` does not help.
- `approve-builds` writes `allowBuilds` and clears the ignored builds before the rebuild
  (`pnpm/crates/cli/src/cli_args/approve_builds.rs:94-95`).
  When the rebuild fails, the approval is saved but the scripts have not run.
  They run at the next `pnpm install`.
- pnpm 11's `approve-builds` calls `rebuild.handler` (`pnpm11/building/commands/src/policy/approveBuilds.ts:273`),
  which builds from what is installed and does not run the check.
  It uses the frozen install only with `enableGlobalVirtualStore` (`approveBuilds.ts:264-270`).

### Which side is wrong

**The freshness check.**
It should accept what the resolver picks for `*`.

- The lockfile is pnpm's own resolver output for the same manifest, made that way on purpose.
  A check that rejects it cannot be satisfied: resolving again gives the same version.
- npm shows the consistent design.
  Its resolver and its validator have the same `*` exception, so `npm ci` and `npm ls` accept a prerelease for `*`,
  including an older one from an earlier lockfile.
- The fix is to give the check the resolver's rule:
  when the resolver treats the specifier as `*`, any locked version satisfies it.
  - v11: the resolver picks `latest` for every specifier whose `semver.validRange(range, true)` is `*`
    (`*`, `x` and `>=0` as `*`, `""` as the tag), so the check should accept any version for those.
  - v12: the resolver has the rule only for the literal `*`, so the check needs it for `*`.
    Also accepting the other spellings would do no harm, since pnpm 12 never locks a prerelease for them.
- This is narrower than pnpm/pnpm#11236, which switches the v11 check to `satisfiesWithPrereleases`.
  That also accepts `1.0.0-alpha` for `^1.0.0` (one of the PR's own test cases),
  a version below the range that the resolver never picks for it.
  pnpm/pnpm#13341 describes the same base-strip problem in pnpm 12's peer picker.

**Not the resolver.**
Because a direct `*` already gets the highest stable version when there is one,
the `*` → `latest` rule only fires when every version is a prerelease.
Taking it out would make `*` fail with `NO_MATCHING_VERSION` for such packages.
That would undo pnpm/pnpm#865 and differ from npm.
The resolver has its own inconsistency (a direct `*` gets 1.0.0, a transitive `*` gets 2.0.0-alpha.0, npm gets
2.0.0-alpha.0 for both), but that is a separate question, and it does not cause this bug.

**approve-builds and rebuild: a second fix, not the first.**
A rebuild resolves nothing, so the version-in-range part of the check protects nothing there,
and pnpm 11 does not run it.
pnpm 12 could keep the specifier check (a rebuild must not fetch a dependency the manifest no longer declares)
and skip the version-in-range check.
That alone would leave `pnpm install --frozen-lockfile` failing in CI on 11 and 12,
the lockfiles from `pnpm import` failing, and every plain install in a clean checkout resolving again.
`approve-builds` should also not save the approval and then fail, or it should say that it saved it.

## Upstream

- pnpm/pnpm#865: the `*` → `latest` rule.
- pnpm/pnpm#9832: the check that the locked version satisfies the range.
- pnpm/pnpm#11236: open PR (2026-04-09, review required, last update 2026-05-14) that switches the v11 check
  to `satisfiesWithPrereleases`.
  It is a PR, not an issue.
  It changes only the TypeScript check, at its path before the `pnpm11/` move,
  and does not touch pnpm 12, `approve-builds` or `rebuild`.
- Related, closed: pnpm/pnpm#12137 (the range check as a control), pnpm/pnpm#15528 (v12, a prerelease kept when
  the range moves to the stable release), pnpm/pnpm#13341 (v12 peer picker and prereleases).

[`ISSUE.md`](ISSUE.md) is a draft bug report.
It suggests a new issue that links pnpm/pnpm#11236, and a one-line comment on pnpm/pnpm#11236 that points to it.
