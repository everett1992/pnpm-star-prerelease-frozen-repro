# pnpm rejects its own lockfile when `"*"` resolves to a prerelease `latest`

[`package.json`](package.json) depends on `"@demo/only-pre": "*"`.
[`only-pre/`](only-pre) is that package: its one version, 1.0.0-alpha.0, is `latest`, and it has a postinstall script.
pnpm locks `latest` for `*`, then its lockfile check says that version doesn't satisfy `*`.

```sh
./repro.sh           # pnpm 12.16.1
./repro.sh 11.28.9   # any pnpm version
```

The script needs Node.js, npm, curl and access to registry.npmjs.org (for pnpm and pnpr).
It starts [pnpr](https://github.com/pnpm/pnpm/tree/main/pnpr) on 127.0.0.1:7677 with [`pnpr.yaml`](pnpr.yaml),
publishes `only-pre/`, and runs pnpm on a copy of `package.json` and [`.npmrc`](.npmrc) in `.work/app`:

1. `pnpm install`, which must fail with `ERR_PNPM_IGNORED_BUILDS` (the postinstall waits for approval),
   but writes the lockfile and `node_modules`;
2. `pnpm approve-builds --all`;
3. `pnpm rebuild`;
4. with no `node_modules`, `pnpm install --frozen-lockfile`;
5. `pnpm install --lockfile-only`, and whether it wrote the same lockfile.

It exits 1 if step 4 fails, 0 if it passes, and 2 if the setup fails.
Output for 11.28.9, 12.16.1 and 12.17.0 is in [`results/`](results).
No settings are needed: the default `minimumReleaseAge` does not stop pnpm from locking the seconds-old version.

[`ISSUE.md`](ISSUE.md) is the draft bug report.
