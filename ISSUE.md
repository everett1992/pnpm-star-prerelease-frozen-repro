<!--
Draft, not filed.
Where: open a new issue with this text, rather than only commenting on pnpm/pnpm#11236.
pnpm/pnpm#11236 is a pull request, not an issue, and there is no issue for this bug.
It changes only the v11 (TypeScript) check, at its path before the pnpm11/ move, and has had no review since 2026-05.
It does not cover pnpm 12's check, `approve-builds` or `rebuild`.
After filing, leave a one-line comment on pnpm/pnpm#11236 that links the new issue.
Title: A "*" range resolved to a prerelease `latest` fails pnpm's own lockfile freshness check
Fill in the link to the reproduction once the repository is published.
-->

### Verify latest release

- [x] I verified that the issue exists in the latest pnpm release

### pnpm version

12.16.1 (also 12.17.0, 12.14.0 and 11.28.9)

### Which area(s) of pnpm are affected? (leave empty if unsure)

Lockfile, Dependencies resolver, CLI

### Link to the code that reproduces this issue or a replay of the bug

(link to the reproduction repository)

### Reproduction steps

The repository's `./repro.sh [pnpm-version]` starts [pnpr](https://github.com/pnpm/pnpm/tree/main/pnpr) on 127.0.0.1,
publishes made-up packages to it and runs the steps below.
By hand, with a registry where every version of `@demo/only-pre` is a prerelease:

```sh
# @demo/only-pre: 1.0.0-alpha.0, 1.0.0-alpha.1 (latest: 1.0.0-alpha.1)
# @demo/needs-build: 1.0.0, has a postinstall script
cat > package.json <<'EOF'
{ "name": "app", "version": "1.0.0", "private": true,
  "dependencies": { "@demo/only-pre": "*", "@demo/needs-build": "1.0.0" } }
EOF
printf 'minimumReleaseAge: 0\nstrictDepBuilds: false\n' > pnpm-workspace.yaml

pnpm install                       # locks 1.0.0-alpha.1 for "*"
rm -rf node_modules                # as in a clean checkout
pnpm install --frozen-lockfile     # ERR_PNPM_OUTDATED_LOCKFILE (v11 and v12)
pnpm install                       # resolves again and writes the same lockfile
pnpm approve-builds --all          # v12: ERR_PNPM_OUTDATED_LOCKFILE
pnpm rebuild                       # v12: ERR_PNPM_OUTDATED_LOCKFILE
```

`pnpm import` from an npm lockfile that holds 1.0.0-alpha.0 for `*` also locks 1.0.0-alpha.1,
and the frozen install after it fails the same way.

### Describe the Bug

pnpm writes a lockfile that pnpm then calls outdated:

```
ERR_PNPM_OUTDATED_LOCKFILE
  Cannot install with "frozen-lockfile" because pnpm-lock.yaml is not up to date with package.json.
  Failure reason:
  the importer resolution is broken at dependency "@demo/only-pre": version "1.0.0-alpha.1" doesn't satisfy range "*"
```

The resolver and the lockfile freshness check do not agree on `*`.

- The resolver gives `*` the `latest` dist-tag even when it is a prerelease, on purpose (pnpm/pnpm#865).
  - v11 `pnpm11/resolving/npm-resolver/src/pickPackageFromMeta.ts:229-231`
  - v12 `pnpm/crates/resolving-npm-resolver/src/pick_package_from_meta.rs:365-366`
- The check from pnpm/pnpm#9832 tests the locked version with plain semver, where a prerelease never satisfies `*`.
  - v11 `pnpm11/lockfile/verification/src/satisfiesPackageManifest.ts:224-233`: `semver.satisfies(version, range)`.
    The helper `versionSatisfies` in `dependencySpec.ts` has `range === '*' || …`, but this check does not use it.
  - v12 `pnpm/crates/lockfile/src/freshness/manifest.rs:235-255`: `range.satisfies(version)`.

What follows from that:

- A plain install in a clean checkout takes the failed check as "resolve again", gets the same version,
  and writes the same lockfile.
  The lockfile is never fresh, and nothing makes `--frozen-lockfile` pass.
- `pnpm install --frozen-lockfile` fails in a clean checkout on v11 and v12.
  v11 skips the check when node_modules is already up to date, so it shows up in CI first.
- On v12, `approve-builds` and `rebuild` always take the frozen path (`cli_args/rebuild.rs:223` sets it,
  `install/entry_points.rs:286-293` asserts it), so they fail even with `frozenLockfile: false`.
  `approve-builds` has already written `allowBuilds` (`cli_args/approve_builds.rs:94-95`),
  so the approval is saved but the scripts have not run.
  On v11, `approve-builds` rebuilds from what is installed and passes.
- In v11 the resolver also reads `x` and `>=0` as `*` (through `version-selector-type`), so they lock the
  prerelease too and fail the same way, with `doesn't satisfy range "x"`.
  v11 also fails for `""`.
  v12 fails `x` and `>=0` with `NO_MATCHING_VERSION`, as npm does.

Results (clean-checkout `--frozen-lockfile`, made-up packages):

| `latest` | range | 11.28.9 | 12.14.0 | 12.16.1, 12.17.0 |
|---|---|---|---|---|
| prerelease, no stable release | `*` | OUTDATED | OUTDATED | OUTDATED |
| prerelease, no stable release | `x`, `>=0` | OUTDATED | NO_MATCHING_VERSION | NO_MATCHING_VERSION |
| prerelease, no stable release | `latest` | ok | ok | ok |
| prerelease over an older stable | `*` | ok (locks the stable) | ok (locks the stable) | ok (locks the stable) |
| stable | any | ok | ok | ok |

npm 11.20.0 is consistent here.
npm-pick-manifest takes `latest` for `range === '*'`,
and arborist's `dep-valid.js` has `if (requested.fetchSpec === '*') return true`.
So `npm ci` and `npm ls` accept a prerelease for `*`, including an older one from an earlier lockfile.

### Expected Behavior

1. A lockfile that pnpm's resolver wrote for `*` passes the freshness check.
   When the resolver treats a specifier as `*`, any locked version satisfies it:
   in v11 every specifier whose `semver.validRange(range, true)` is `*`, and in v12 at least `*`.
   This matches npm's `dep-valid`, and keeps the check strict for every other range.
   It is narrower than pnpm/pnpm#11236, whose `satisfiesWithPrereleases` also accepts `1.0.0-alpha` for `^1.0.0`
   (one of its test cases), a version below the range that the resolver never picks for it.
2. `rebuild` and the rebuild of `approve-builds` do not run the version-in-range part of the check,
   because they resolve nothing.
   Keeping the specifier check keeps the rule that a rebuild must not fetch what the manifest no longer declares.
3. If the rebuild of `approve-builds` fails, the error says that the approval was saved
   and that the scripts run at the next install.

I don't think the resolver should change.
For a direct dependency, pnpm already locks the highest stable version for `*` when there is one,
because the manifest's own range seeds the preferred versions, and that step uses plain semver.
So the `*` → `latest` rule only fires when every version is a prerelease,
and taking it out would bring back pnpm/pnpm#865.
(A transitive `*` does get the prerelease `latest`, 2.0.0-alpha.0 over 1.0.0, as npm does for both.
That difference is a separate question, and the check only looks at direct dependencies.)

### Which Node.js version are you using?

26.12.0

### Which operating systems have you used?

- [ ] macOS
- [ ] Windows
- [x] Linux

### If your OS is a Linux based, which one it is? (Include the version if relevant)

Linux x86_64

### Contributing a fix

- [ ] I am working on a fix

Related: pnpm/pnpm#11236 (open PR for the v11 check), pnpm/pnpm#12137, pnpm/pnpm#15528, pnpm/pnpm#13341.

Written by an agent (Claude Code, claude-opus-5-5)
