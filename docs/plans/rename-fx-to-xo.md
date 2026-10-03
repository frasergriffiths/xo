# Plan: rename `fx` to `xo`

This is a written plan, not a record of finished work. Nothing in it has been
executed. I measured every count and path below on commit `main` in this checkout on
2026-10-01.

## Policy: total rename, no back-compat

Every occurrence of the brand becomes `xo`. No deprecation windows, no dual-read
paths, no aliases, no legacy fallbacks, no re-export stubs. When this lands, the
product is `xo` in every direction it can be observed: the binary, the on-disk layout,
the environment variable namespace, the published package names, the signing identity,
the agent identity over ACP, the hook namespace, the theme names, and the
documentation.

This breaks existing users on purpose. Their `~/.fx` profile, `FX_*` shell exports,
`.fx.json` project config, saved permission decisions, and saved compaction state all
get left behind. The migration path is release notes, not runtime code. Anything that
reads the old spelling after this commit is a bug.

The rule has no exceptions: **not one name in this repository keeps the old spelling.**
Files, directories, packages, variables, types, functions, constants, string literals,
test names, fixture names, workflow files, and identifiers of every kind all become
`xo`. A construct that merely appears to be `fx` still gets renamed, unless it is one
of the three English words listed under "Known false positives". A name does not stay
`fx` because it looks internal or lives only in a test fixture. Awkwardness is not a
reason either. When in doubt, rename it and let the compiler or the test suite prove it
wrong.

Two consequences to accept up front:

- Nothing that validates against `fx` carries forward. Test sentinels, artifact handle
  prefixes, hash inputs, and the compaction marker all change too, and their paired
  assertions change in the same edit.
- Published release notes under the old name will describe `xo`. `CHANGELOG.md` is
  included in the rename. This rewrites what the history says the tool was called.

## Why this is not a find-and-replace

`fx` is more than a program name. It is the brand, the on-disk layout, the environment
variable namespace, the published package name, the signing identity, and the agent
identity advertised over ACP. Rename the binary alone and the product still lies about
itself in six directions at once.

Three of those directions are irreversible or externally owned:

- The GitHub repository name and the redirect behavior of every historical URL.
- The macOS codesigning identifier, which is bound to an Apple Developer account.
- The published npm packages, which cannot be unpublished or renamed in place.

Everything else is mechanical. The plan separates the two classes because they carry
completely different risk profiles and approval requirements.

## Measured surface

`git grep -Iio -e fx` over tracked files: **516 files, 13,398 occurrences**.

| Area | Files | Occurrences | Notes |
| --- | --- | --- | --- |
| `src/` | 243 | 3,149 | Product code, string literals, tests |
| `sdk/` | 93 | 938 | Published `libfx` npm package |
| `tests/e2e/` | 85 | 7,707 | Largest block by volume, mostly env plumbing |
| `tests/evals/` | 12 | 182 | Requires live credentials |
| `scripts/` | 24 | 244 | PGSO, signing, binary size |
| `.github/` | 11 | 458 | Workflows and the issue template |
| Root docs and build files | 7 | 514 | Includes `CHANGELOG.md` |

Top files by occurrence count, useful for sequencing review work:

| File | Hits |
| --- | --- |
| `tests/e2e/tui-auth-source-selection.test.ts` | 1,021 |
| `tests/e2e/cli.test.ts` | 618 |
| `tests/e2e/tui-gateway-stream-lifecycle.test.ts` | 497 |
| `tests/e2e/tui-resume.test.ts` | 430 |
| `src/core/config/config_runtime.zig` | 168 |
| `src/core/skills/skill_runtime.zig` | 130 |
| `src/core/cli/cli_ask.zig` | 107 |
| `CHANGELOG.md` | 103 |

## Settled answers

The total-rename policy already settled every decision below. Treat each one as the
target for its workstream, not as an open question.

1. **Profile directory.** `src/core/shared/profile_paths.zig:5` sets
   `root_dir_name = ".fx"`. It becomes `.xo`, so the user's home profile moves from
   `~/.fx` to `~/.xo`. The old `~/.fx` directory is never read again and never written
   to. No migration copy, no fallback read. Users move their own data.
2. **Project config file.** `.fx.json` becomes `.xo.json`, same precedence position,
   same repo-safe key allowlist. No fallback to `.fx.json`.
3. **Environment variable namespace.** Every `FX_*` becomes `XO_*`. Roughly 330
   distinct names. Only `XO_*` is read. `FX_*` is ignored, with no warning.
4. **npm package.** `libfx` becomes `libxo`. The CLI publishes as `xo` on npm if the
   name is free. No deprecation stub on the old names. They simply stop being
   published.
5. **Repository and host.** `frasergriffiths/xo` becomes the new org and name. `fx.sh`
   and `releases.fx.sh` become the new host and release host. This needs coordinated
   DNS and TLS work outside the repo, but the code changes to the new names regardless.
6. **macOS identifier.** `com.vercel.fx` becomes `com.vercel.xo`. It is asserted in
   `scripts/sign-and-notarize-macos.sh:8`, `scripts/compare_signed_macos.py:108`, and
   three spots in `scripts/tests/test_macos_signing.py`. A new identifier needs a new
   provisioning profile and a re-signing cycle against the Apple account.
7. **ACP agent identity.** `src/acp/types.zig:238` writes `"name":"xo"` and
   `"title":"xo"` into the `initialize` response. `src/acp/prompt.zig:1169` reads
   `_meta.xo`. Only the new key is read. Editors keying off `agentInfo.name` will show
   `xo`. The old `_meta.fx` key is no longer recognized.
8. **Hook and event namespace.** `fx.herdr.*` and `fx.sound.*` become `xo.herdr.*` and
   `xo.sound.*`. The herdr source string `custom:fx` in
   `src/builtins/hooks/herdr.zig:20` becomes `custom:xo`. Existing `settings.json`
   hook references stop working, by design.
9. **Theme identifiers.** `src/core/shared/theme.zig` defines `fx_dark` and `fx_light`
   with string names `fx-dark` and `fx-light`. Both identifiers and both string names
   become `xo_dark`, `xo_light`, `xo-dark`, and `xo-light`. No read alias.
10. **Product history.** `CHANGELOG.md` is included in the rename, all 103 occurrences.
    Past release notes will read `xo`. This is accepted, not deferred.

## Workstreams, in dependency order

Each workstream lands as its own commit or PR, so a failure stays contained.

### 1. Identity strings in product code

Lowest risk, no external dependency. Pure string content, fully covered by tests.

- `src/main.zig:6`, `pub const version = "0.0.12"`, unchanged, but confirm the
  release note later.
- `src/core/slash_commands/command_specs.zig`. Help output and examples at lines 296,
  297, 336, 1089 through 1222. Change usage strings to `xo [flags]` and
  `xo <command> [...flags] [...args]`, and update every paired test assertion in the
  same file. These tests are self-referential. They assert the exact string being
  changed, so a missed assertion shows up as a focused test failure, not a silent
  regression.
- `src/builtins/commands.zig:343` through 362. The four example commands and the
  `interactive_hint` string.
- `src/acp/types.zig:238`, agent name and title.
- `src/builtins/context.zig:2622`, asserts `scp.repo_name` equals `"xo"`.
- `src/builtins/skills.zig:135` and 1981, the managed install root message.
- Any user-visible error text. `src/core/agent/runtime/tests/gateway_flow.zig:7648`
  asserts the string `xo did not execute that call`, so the error text in the
  orchestrator and its test must change together.

Verification: `zig build test`, then `./zig-out/bin/xo --help` and `xo status --json`
from the built binary, per the `AGENTS.md` rule that a passing suite does not prove
the binary starts.

### 2. Environment variables

The largest mechanical block, roughly 330 distinct names, and the likeliest to break
silently. An unrecognized variable falls back to a default instead of failing loudly.
That is acceptable here because there is no fallback path to get wrong. Only `XO_*` is
ever read.

Every `FX_*` becomes `XO_*` across `src/`, `sdk/`, `tests/`, `scripts/`, `.github/`,
and docs. The high-traffic names that must be correct in the same pass, ordered by
occurrence count:

| Variable | Hits | Becomes | Role |
| --- | --- | --- | --- |
| `FX_BIN` | 438 | `XO_BIN` | Test harness binary path |
| `FX_MODEL` | 319 | `XO_MODEL` | Model selection |
| `FX_AUTO_UPGRADE` | 296 | `XO_AUTO_UPGRADE` | Auto-update control |
| `FX_GATEWAY_BASE_URL` | 222 | `XO_GATEWAY_BASE_URL` | Gateway base |
| `FX_TRACE_SCOPES` | 204 | `XO_TRACE_SCOPES` | Tracing |
| `FX_GATEWAY_CHAT_URL` | 184 | `XO_GATEWAY_CHAT_URL` | Gateway chat |
| `FX_DISABLE_KEYCHAIN` | 157 | `XO_DISABLE_KEYCHAIN` | Secret storage |
| `FX_RECORD` | 138 | `XO_RECORD` | Debug tape recording |
| `FX_PERMISSION_MODE` | 110 | `XO_PERMISSION_MODE` | Permission baseline |
| `FX_E2E_GATEWAY_MODELS_URL` | 100 | `XO_E2E_GATEWAY_MODELS_URL` | Test fixture |
| `FX_E2E_GATEWAY_CHAT_URL` | 97 | `XO_E2E_GATEWAY_CHAT_URL` | Test fixture |
| `FX_SOUND` | 89 | `XO_SOUND` | Notification audio |
| `FX_SKIP_ONBOARDING` | 67 | `XO_SKIP_ONBOARDING` | Onboarding |
| `FX_RECORD_INPUT` | 55 | `XO_RECORD_INPUT` | Debug tape |
| `FX_THEME` | 39 | `XO_THEME` | Theme selection |
| `FX_PROVIDER` | 37 | `XO_PROVIDER` | Provider selection |

Do not hand-edit these. A scripted pass plus a compile is the reliable route, because
a missed variable has no compile-time signal.

Two things to watch:

- `FX_E2E_*` variables are test-fixture URLs for live and fake gateways. They are
  internal to CI, and they are also the easiest to break because they appear in
  `scripts/pgso/corpus.json` defaults, not just in test files.
- Test sentinels such as `FX_PATH_SENTINEL` and `FX_API_KEY_SECRET`, about 60 in all,
  are distinctive strings used to prove a secret was not leaked into a transcript.
  Rename them like everything else, but update in lockstep any assertion that checks a
  specific sentinel does *not* appear. A renamed sentinel with a stale negative
  assertion is a false pass.

### 3. On-disk layout

`src/core/shared/profile_paths.zig` is the single source of truth for the profile
directory. Change `root_dir_name` there and the 29 call sites that read it follow
automatically, because they all reference the constant rather than hardcoding the
literal. Those call sites are in `app_lifecycle.zig`, `config_runtime.zig`,
`settings_store.zig`, `native_secret_store.zig`, `mcp_auth_store.zig`,
`profile_usage_store.zig`, `prompt_history_store.zig`, `terminal/host.zig`, and
`terminal/store.zig`.

The directory becomes `.xo`, so the user profile moves from `~/.fx` to `~/.xo`.
Required behavior:

1. `.xo/settings.json`, `.xo/auth.json`, `.xo/sessions/`, `.xo/skills/`,
   `.xo/logs/`, `.xo/backups/`, `.xo/recordings/`, `.xo/prompt_history*`, and
   `.xo/usage.jsonl` are the only paths read or written.
2. No code path reads `.fx`. No migration copy. No fallback. The old `~/.fx` directory
   is left on disk, untouched, and ignored.
3. `.fx.json` becomes `.xo.json` with the same precedence position, documented in the
   config precedence list in `AGENTS.md`. `.fx.json` is no longer read.
4. The project-local skills directory `.fx/skills` becomes `.xo/skills`, referenced
   from `src/builtins/skills.zig` and the managed install root message.

### 3a. Install prefix and self-upgrade

`AGENTS.md:21` and `AGENTS.md:27` both refer to an installed binary at `~/.fx/bin/fx`.
That path lives inside the profile directory, so it moves with everything else:

- The installed binary path becomes `~/.xo/bin/xo`.
- The auto-upgrade flow installs over `self_exe`
  (`src/core/upgrade/auto_upgrade.zig:329`, `installUnlessStopped`), so it inherits the
  new location automatically. Confirm it does not reconstruct the install path from
  `root_dir_name` plus a hardcoded `fx` binary name.
- `isDevelopmentBuildPath` at `src/core/upgrade/auto_upgrade.zig:51` matches
  `/zig-out/bin/` and `\zig-out\bin\`. Those directory names are build-system paths and
  do not change, but the two test fixtures at lines 487 and 489 embed the binary name
  and become `/repo/zig-out/bin/xo` and `/Users/me/.local/bin/xo`.
- `FX_BIN` appears 438 times as the test-harness binary path variable and becomes
  `XO_BIN`. It is defined in `tests/evals/eval-helpers.ts` and imported by many E2E
  files, including `tests/e2e/acp.test.ts:19`. Rename the export once at its
  definition, then update every importing file.
- The CDN installer `https://fx.sh/setup.sh` writes into this directory. Its
  destination host is workstream 8, but the path it writes must be `~/.xo/bin/xo`.

The repo's own `.fx/skills/technical-writer/` directory is tracked and moves to
`.xo/skills/`. `AGENTS.md` refers to the skill by relative path, so update that
reference too.

### 4. Persisted state keys and content

Renaming a directory is not enough if the keys inside it still say `fx`. Every one of
these changes, and each accepts the invalidation it causes:

- Theme names `xo-dark` and `xo-light` in `settings.json`. The old names are not read.
- Compaction marker `"xo-compaction-state-v1 "` in
  `src/core/agent/runtime/compaction_policy.zig:12`. This invalidates saved compaction
  state and forces a full re-read of history on next run. Accepted.
- Permission hash inputs in `src/core/agent/runtime/tool_admission.zig:155, 263, 305`,
  for example `xo.permission-action.v1`. This invalidates every saved permission
  decision, so users are re-prompted once. Accepted.
- Command replay artifact handles, `xo-command-replay-*`, in
  `src/core/session/command_replay_store.zig:823` and 872, plus
  `xo-command-cancelled.log` and `xo-command-replay-complete.bin`. These are
  referenced by both producers and validators; change them together so the validator
  matches the new prefix.
- Session IDs and artifact digests in `src/core/session/artifact_digest.zig:67`.

### 5. Build outputs and the SDK

`build.zig` names every artifact:

| Line | Artifact | Becomes |
| --- | --- | --- |
| 41 | executable `fx` | `xo` |
| 65 | step description `Run fx` | `Run xo` |
| 74, 99 | `FX_TEST_PRODUCT_EXE` path | `XO_TEST_PRODUCT_EXE` |
| 115 | `pgso/fx.bc` | `pgso/xo.bc` |
| 131, 132 | wasm names `fx-core`, `fx-term` | `xo-core`, `xo-term` |
| 196, 215, 216 | library `libfx`, `libfx.node`, step `libfx-napi` | `libxo`, `libxo.node`, `libxo-napi` |

`build.zig.zon` sets `.name = .fx` and carries a `.fingerprint`. The file's own
comment says the fingerprint encodes package identity and that a fork should delete the
field and run `zig build` to regenerate it, warning that changing the name while
leaving the fingerprint produces a package the toolchain treats as a hostile fork.
Since this is a deliberate rename of package identity, set `.name = .xo`, delete
`.fingerprint`, and let `zig build` regenerate it. Do not change the zon `.version`,
which `AGENTS.md` says is a placeholder.

The SDK carries the same names across JS, package manifests, and test expectations:

- `sdk/fx-sdk.js` becomes `sdk/xo-sdk.js`, with all 10 self-references and the wasm
  loader updated, exporting `xo.tool` and `xoSdkApiVersion`.
- `sdk/package.json`, name `libxo`, the `./wasm` export mapping to `./xo-sdk.js`, the
  `files` array listing `xo-sdk.js`, `xo-core.wasm`, and `xo-term.wasm`, and the
  repository and homepage URLs.
- `sdk/node/package.json`, name `xo-wasm-sdk-node-tests`.
- `sdk/node.js` and `sdk/wasm-module.js`, which probe `xo.linux` and `xo.darwin` for
  native artifact discovery.
- `sdk/scripts/package-libfx.mjs` becomes `package-libxo.mjs`, the packaging script.
- `sdk/tests/next/app/api/fx/route.js` becomes `api/xo/route.js`, a Next.js route
  fixture whose path is part of the test's contract, so update the test that requests
  it.
- `tests/e2e/fixtures/fx-render-bug-20260510-075848.tar.gz` becomes
  `xo-render-bug-...`. A binary render regression fixture referenced by
  `scripts/check-public-surface.sh:44`, which validates its contents and ownership.
  Rename the file, repack it so the rendered text inside also reads `xo`, and update
  the audit script's path. Note that `check-public-surface.sh` requires the archive to
  contain the marker `sanitized-v1`, so that marker stays exactly as it is.

### 6. Tests and CI

`tests/e2e` holds 7,707 of the 13,398 occurrences, mostly environment plumbing and
tmux fixtures. It is the last workstream, not the first, because it verifies
everything above it.

- `tests/e2e/ci-shard-weights.json` assigns each test file to exactly one shard per
  platform. Renaming test files invalidates the weights file. `ci-shards.test.ts`
  enforces this, so it fails loudly, which is the desired behavior.
- `scripts/pgso/corpus.json` classifies every root `tests/e2e/*.test.ts` file as
  Training, Verification-only, or Intentional exclusion. Per `AGENTS.md`, CI rejects
  missing, duplicate, stale, or unclassified files before running the expensive PGSO
  qualification. Any renamed test file needs its classification entry updated in the
  same change. New tests inside an already classified file inherit that
  classification.
- `scripts/pgso/corpus.json` also carries `defaults.env_set` with `FX_AUTO_UPGRADE`,
  `FX_SOUND`, and `NO_COLOR`, all of which become the `XO_` spelling. These defaults
  apply to every PGSO run, so a half-renamed environment silently changes training
  corpus behavior.
- `.github/workflows/` has 458 occurrences across 11 files. `publish-libfx.yml`
  becomes `publish-libxo.yml` and matches the new package name.
  `prepare-release.yml` feeds the diff to an LLM to draft the changelog.
  `pgso-macos-arm64.yml` owns the 7.800 MiB production ceiling.
- `.github/ISSUE_TEMPLATE/fx-report.yml` becomes `xo-report.yml`.

### 7. Documentation

`README.md` (43), `AGENTS.md` (31), `CONTRIBUTING.md` (34), and `THIRD_PARTY_NOTICES.md`
(2). `AGENTS.md` is load-bearing. It names the skill path, the config file, the
precedence list, and the binary path `./zig-out/bin/xo` used for verification. It also
states that all repository and license references must use `frasergriffiths/xo`. That
rule must be updated in the same commit as the rename, or the next agent will revert
it.

`CHANGELOG.md`, 103 occurrences, is renamed in full per decision 10.

## Mechanical rules

Most of the work is a scripted pass. The rules:

1. Match `fx` as a whole token, never as a raw substring. `s/fx/xo/g` corrupts
   `prefix`, `suffix`, `affix`, and worse.
2. Case variants are all in scope and all need distinct rules:
   - `fx` to `xo`
   - `FX_` to `XO_`
   - `Fx` to `Xo`, so `createFxAgent` becomes `createXoAgent` and `runFx` becomes
     `runXo`
   - `libfx` to `libxo`
   - `libFx` to `libXo`
3. Verify each rule before applying. From the measured data, `Fx` identifiers include
   `runFx` (821), `createFxAgent` (172), `startFx` (148), `parseFxJson` (76),
   `createFxTerminal` (65), `writeSeededFxLogin` (40), `installedFx` (21),
   `startMockFx` (17), `quitFx` (14), `launchFx` (14). These are internal symbols and
   all become the `Xo` spelling.
4. After the scripted pass, `git grep -i fx` must return only the known false
   positives below. Every remaining hit is either an English word that happens to
   contain `fx`, or a bug. Review the residue by hand.

### Known false positives

Only these three remain unrenamed, and only because `fx` is a coincidence of English
spelling rather than the brand:

- `prefix`, `suffix`, `affix`, and any identifier embedding them

Everything else that contains the letters `fx` is the brand and gets renamed, including
cases that superficially look like coincidences. These were confirmed present in the
tree and are genuine rename targets, not exceptions:

| Current | Becomes | Location |
| --- | --- | --- |
| `fx_herdr` | `xo_herdr` | `src/builtins/hooks/herdr.zig:42`, 46, 59 |
| `fxop:2:m:` operation ID prefix | `xoop:2:m:` | `src/core/subagent/tool_host.zig:1068`, 1581; `orchestrator.zig:1192` |
| `\nfx ask: reason=` | `\nxo ask: reason=` | `src/core/cli/cli_ask.zig:2492` |
| `\nfx setup: API key was not saved` | `\nxo setup: ...` | `src/core/cli/cli_surface.zig:1774`, 1784 |
| `FX_TEST_*` sentinels and fixtures | `XO_TEST_*` | throughout `tests/` and `scripts/` |

Two are worth calling out because they are easy to misread. `\xffx` in
`src/ui/input/runtime.zig:2354` and `src/ui/input/visual_layout.zig:845` is the escape
byte `0xFF` followed by a literal `x`, and does not contain the brand. It stays.

The `0xFF` case is the reason gate 8 is written as a residue check rather than an
expectation of zero. A blind substring count will never reach zero in this tree.

## Verification gates

Per `AGENTS.md`, the following are required before the work is called ready. The
rename does not get an exemption from any of them.

1. `zig fmt --check src/`
2. `zig build` succeeds
3. `zig build test` passes in full
4. `scripts/check-public-surface.sh` passes
5. `cd tests/e2e && bun test` passes, including `ci-shards.test.ts`
6. PGSO corpus validation passes, confirming no missing, duplicate, stale, or
   unclassified test files
7. Binary size stays under the 7.800 MiB ceiling and the informational 52,429 byte
   per-platform threshold is not exceeded without explanation
8. `git grep -Iio -e fx` over tracked files returns only `prefix`, `suffix`, and `affix`
   and their embeddings. Every other hit, including `\xffx` escapes, must be reviewed
   and confirmed as either renamed or a true non-brand coincidence.
9. Full CI green on the exact commit across `ubuntu-24.04`, `ubuntu-24.04-arm`,
   `macos-15-intel`, and `macos-15`
10. The final ship gate reports `SHIP`
11. Drive the built `./zig-out/bin/xo` binary by hand: start an interactive session,
    resume one, run `xo ask`, and check `xo status --json`
12. Confirm the profile lands in `~/.xo` and nothing is written to `~/.fx`. Run with a
    throwaway `HOME`, start a session, then inspect the directory tree.

Steps 5 through 10 are expensive. Run focused tests per workstream and open a draft PR
early, letting Full CI run on the branch, rather than waiting to have everything local
first.

## Ordering summary

| # | Workstream | Blocked by | Risk |
| --- | --- | --- | --- |
| 1 | Identity strings in product code | Nothing | Low |
| 2 | Environment variables | Nothing | Medium, silent failures |
| 3 | On-disk layout | Decision 1, 2 | High, user data orphaned |
| 3a | Install prefix and self-upgrade | Workstream 3 | Medium, touches the updater |
| 4 | Persisted state keys | Decision 1, 9 | Medium, accepted invalidation |
| 5 | Build outputs and SDK | Decisions 4, 6 | Medium, external publishing |
| 6 | Tests and CI | All of the above | Low mechanically, high volume |
| 7 | Documentation | All of the above | Low |
| 8 | Repo, DNS, npm, signing | External coordination | Highest |

Workstream 8 is not a code task. It needs a new repository name, new DNS with TLS for
the replacement host, npm publication under `xo` and `libxo`, and a new Apple
provisioning profile. Start it first because it has the longest external lead time,
even though it lands last. No compatibility is provided for the old names in the
interim; the cutover is the rename.

## External dependencies

These cannot be settled from the repo and need a decision before workstream 8:

1. What host replaces `fx.sh` and `releases.fx.sh`, and who controls the DNS and TLS.
2. Whether `xo` is free on npm for the CLI, and whether `libxo` is free.
3. The Apple Developer provisioning profile for `com.vercel.xo`.
4. The destination org and repository name for the GitHub move.

## Related

- `WORKLOG.md`, checked in this working tree, holds planning notes. Decide whether it
  ships in the rename or gets removed.
- The working tree was already dirty when this plan was written, with deleted
  `benchmarks/` and `libfx` workflow files staged. Establish whether that is a
  rename in progress before starting, so this plan does not collide with work already
  underway.
