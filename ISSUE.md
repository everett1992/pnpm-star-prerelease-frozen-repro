### Verify latest release

- [x] I verified that the issue exists in the latest pnpm release

### pnpm version

12.16.1 (also 12.17.0 and 11.28.9)

### Which area(s) of pnpm are affected? (leave empty if unsure)

Lockfile, CLI

### Link to the code that reproduces this issue or a replay of the bug

https://github.com/everett1992/pnpm-star-prerelease-frozen-repro

### Reproduction steps

The repository's `package.json` depends on `"@demo/only-pre": "*"`.
`@demo/only-pre` has one version, 1.0.0-alpha.0, which is `latest`, and a postinstall script.
Any package with no stable version and a prerelease `latest` does the same.
`./repro.sh [pnpm-version]` publishes it to a local [pnpr](https://github.com/pnpm/pnpm/tree/main/pnpr)
and runs:

```sh
pnpm install                    # ERR_PNPM_IGNORED_BUILDS, as expected; locks 1.0.0-alpha.0
pnpm approve-builds --all       # v12: ERR_PNPM_OUTDATED_LOCKFILE
pnpm rebuild                    # v12: ERR_PNPM_OUTDATED_LOCKFILE
rm -rf node_modules
pnpm install --frozen-lockfile  # ERR_PNPM_OUTDATED_LOCKFILE
pnpm install --lockfile-only    # writes the same lockfile
```

### Describe the Bug

pnpm rejects a lockfile that it has just written for an unchanged `package.json`.
On 12.16.1:

```
ERR_PNPM_OUTDATED_LOCKFILE
  Cannot install with "frozen-lockfile" because pnpm-lock.yaml is not up to date with package.json.
  Failure reason:
  the importer resolution is broken at dependency "@demo/only-pre": version "1.0.0-alpha.0" doesn't satisfy range "*"
```

The resolver and the freshness check disagree about `*`:

- The resolver gives `*` the `latest` tag when no stable version matches, even if `latest` is a prerelease.
  This is on purpose (pnpm/pnpm#865), and npm does the same.
  v11 [`pickPackageFromMeta`](https://github.com/pnpm/pnpm/blob/bbd4e6debba1d4a6930088a653cb868f8ebd761b/pnpm11/resolving/npm-resolver/src/pickPackageFromMeta.ts#L221-L223),
  v12 [`pick_package_from_meta.rs`](https://github.com/pnpm/pnpm/blob/bbd4e6debba1d4a6930088a653cb868f8ebd761b/pnpm/crates/resolving-npm-resolver/src/pick_package_from_meta.rs#L340).
- The check added in pnpm/pnpm#9832 uses plain semver, where a prerelease never satisfies `*`.
  v11 [`findDependencyMismatch`](https://github.com/pnpm/pnpm/blob/bbd4e6debba1d4a6930088a653cb868f8ebd761b/pnpm11/lockfile/verification/src/satisfiesPackageManifest.ts#L227),
  v12 [`check_resolution_satisfies`](https://github.com/pnpm/pnpm/blob/bbd4e6debba1d4a6930088a653cb868f8ebd761b/pnpm/crates/lockfile/src/freshness/manifest.rs#L234-L253).

So:

- `pnpm install --frozen-lockfile` fails in every clean checkout, so CI fails.
  No pnpm command writes a lockfile that passes: `pnpm install` and `--lockfile-only` write the same one again.
- On v12, `approve-builds` and `rebuild` always run a frozen install
  ([`rebuild.rs`](https://github.com/pnpm/pnpm/blob/bbd4e6debba1d4a6930088a653cb868f8ebd761b/pnpm/crates/cli/src/cli_args/rebuild.rs#L220)),
  so they fail too.
  `approve-builds` has already saved `allowBuilds` to `pnpm-workspace.yaml`, but the postinstall has not run.
  On v11 both pass.

Only `*` hits this on v12.
v11 also hits it for specifiers that semver normalizes to `*`, such as `x`, `>=0` and `""`.
Ranges such as `^1.0.0-alpha.0` lock the same version and pass.

npm is consistent: `npm ci` and `npm ls` accept the same lockfile,
because arborist's `dep-valid.js` has the resolver's exception (`if (requested.fetchSpec === '*') return true`).

### Expected Behavior

The freshness check accepts any locked version for `*`, as npm does.
That also fixes `approve-builds` and `rebuild` on v12.
This is narrower than pnpm/pnpm#11236 (open PR, v11 only),
which also accepts `1.0.0-alpha` for `^1.0.0`, a version the resolver would never pick for that range.

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

Related: pnpm/pnpm#865, pnpm/pnpm#9832, pnpm/pnpm#11236.

---
Written by an agent (Claude Code, claude-opus-5-5).
