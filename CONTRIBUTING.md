# Contributing to directa

directa is a personal tool first; issues and patches are welcome all the same. Read `AGENTS.md` for the codebase map, invariants, and commands (`CLAUDE.md` is a one-line pointer to it), and `docs/cli-contract.md` for the JSON surface. `make test` and `scripts/smoke.sh` must pass locally; `scripts/smoke-launchd.sh` exercises the real launchd lifecycle if your change touches daemon management. GitHub Actions (`.github/workflows/ci.yml`) runs `swift build` + `swift test` on `macos-26` only: no smoke, no large runners.

## Commit and changeset hygiene

Commit subjects and PR titles are Conventional Commits. The type/scope list and subject grammar live in `AGENTS.md` (Engineering rules / Git). GitHub squash uses the PR title as the `main` subject, so the PR title is a conventional commit subject, not a headline sentence.

Never `git stash` (use temp commits). Agents never bump versions or publish.

### Subject examples

Good:

```
feat(cli): add Grok Build session hook so sessions rediscover servers
fix(app): keep the menu bar extra from quitting after memory pressure
fix(supervisor): spawn agent-managed servers outside the daemon's jetsam coalition
feat(cli)!: leave lock holders running by default
docs: adopt conventional commits for PR and commit titles
```

Bad:

```
lock: hold the resource without stopping servers by default
Lock leaves servers up; doctor reports jetsam leftovers; DMG installer can replace the app
Update SetupPerformer.swift
WIP
fix stuff
```

The first is missing a type. The second is a semicolon laundry list: title the primary change (`!` then feat then fix) and name the rest in the body. The others are a file list or a placeholder.

### PR body

User-facing: what changed for a person running directa, migration if any, how it was verified. Not a restatement of the subject, not a file list. Version Packages PRs keep the title the Changesets bot writes.

### Changesets

User-facing changes get a Changeset (`npm run changeset`); see `.changeset/README.md`. Internal-only work (CI, agent docs, no-behavior refactors) never gets a changeset. A breaking subject (`type(scope)!:`) still needs a major changeset: the `!` is for git log, Changesets own the version.

The body is changelog text for someone using directa. Lead with what changed for them. No function names, internal file paths, or launchd labels. A term of art (jetsam, lock resource) gets a short plain-English gloss on first use.

Product version lives in `package.json`. `npm run version` (used by the Release workflow) syncs `DirectaVersion.version` in `Sources/DirectaKit/Model/Models.swift`.

## Releases

GitHub releases are driven by [Changesets](https://github.com/changesets/changesets). After changesets land on `main`, a Version Packages PR appears; merging it tags `vX.Y.Z` and opens the GitHub release. Nothing is published to npm: the root `package.json` is private and only tracks the product version.

A separate macOS workflow (`.github/workflows/release-dmg.yml`) builds a Developer ID-signed, notarized DMG and attaches it to that release. The Release job dispatches it after a successful publish (`workflow_dispatch`): a release created with `GITHUB_TOKEN` does not fire `release:published` on other workflows. Required repository secrets:

- `APPLE_DEVELOPER_ID_P12_BASE64` / `APPLE_DEVELOPER_ID_P12_PASSWORD`: exported Developer ID Application certificate
- `APPLE_SIGN_IDENTITY`: exact codesign identity string (for example `Developer ID Application: Name (TEAMID)`)
- `APPLE_API_KEY_BASE64` / `APPLE_API_KEY_ID` / `APPLE_API_ISSUER`: App Store Connect API key for `notarytool`

The release DMG build runs with `DIRECTA_REQUIRE_SIGNING=1`, so a runner missing the certificate fails the build rather than shipping an ad-hoc image Gatekeeper would disable.

Local path: `make release-dmg` (Developer ID signed, notarized, and stapled; fails loudly if signing or notary credentials are missing), then `gh release upload vX.Y.Z dist/directa-X.Y.Z.dmg`.

## Homebrew tap

directa is distributed as a cask through the self-owned tap `quantizor/homebrew-tap` (installed as `brew install --cask quantizor/tap/directa`). A tap is required rather than optional: the official `homebrew/cask` needs 225 stars and a 30-day-old repo, and a tapless cask can never be upgraded (brew re-reads the definition saved at install time, so the version always compares equal).

The release workflow bumps the tap automatically on publish. The cask's structure (`packaging/homebrew/directa.rb`), the `bump-homebrew-cask` workflow that injects each release's `version` and `sha256`, and the `scripts/smoke-cask.sh` gate are all documented in docs/releasing.md. One additional repository secret drives the bump:

- `HOMEBREW_TAP_TOKEN`: a fine-grained PAT with `contents: write` on `quantizor/homebrew-tap` (the default `GITHUB_TOKEN` cannot push across repos). A GitHub App token via `actions/create-github-app-token` is the equivalent alternative.

Anything in the cask's `uninstall` runs on every `brew upgrade`, not only on uninstall, so it is limited to unregistering the background agent (the app re-registers it when brew relaunches). It must never remove hooks or data: nothing restores those automatically. Full removal is `directa uninstall`.

## Adding an agent-harness adapter

The session-context payload is harness-agnostic: `directa context` prints a fenced plain-text block describing the current project's servers, and `directa statusline` prints a one-line presence summary from statusline stdin JSON. Wiring those into a harness is the only per-harness work.

1. Conform to `HarnessAdapter` in `Sources/directa/HookSupport.swift`: a `name` (the `--harness` value), the `settingsURL` of the file the harness reads, and an idempotent `install(cliPath:)` that merges a session-start hook into that file without clobbering what is already there. Read and write it with the protocol's own `loadSettings()` and `writeSettings(_:)` rather than reaching for `Data(contentsOf:)`: `install` writes back everything it reads, so a read that answers "empty" for a file that exists turns the merge into a replacement of settings directa does not own. `loadSettings` refuses a file it cannot parse for that reason, and returns an empty dictionary only when there is genuinely nothing there to lose.
2. If the harness wants a structured payload (as Claude Code does with `hookSpecificOutput.additionalContext`, or Cursor with `{additional_context}`), add a hidden subcommand like `HookClaudeSessionStart` / `HookCursorSessionStart` that adapts the `HookContext.render` output (a thin socket fetch over the pure `AgentContext.render` renderer in DirectaKit) to that shape. Keep the guarantees: exit 0 always, fast, silent when there is nothing to say, never auto-starting the daemon, and never emitting raw log lines or command strings (child output and committed configs are attacker-influenceable). Resolve the session directory via `HookSessionCwd` (Cursor: `workspace_roots` / `CURSOR_PROJECT_DIR`; Claude: `cwd`; Grok: `cwd` / `workspaceRoot` / `GROK_WORKSPACE_ROOT`).
3. Register the adapter in `harnessAdapters` and document the harness in `docs/cli-contract.md` under `directa hook install`.

A harness that only supports plain-text injection needs no adapter code at all: point its hook at `directa context`. Shipped adapters today: `antigravity`, `claude`, `cursor`, `grok`, `opencode`. Grok discards hook stdout on SessionStart and UserPromptSubmit, and delivers PreToolUse additionalContext after the tool result, so that adapter registers PreToolUse and UserPromptSubmit (UserPromptSubmit marks the turn; PreToolUse emits once per turn), removes this command from any other event on install, and also writes a managed `~/.grok/rules/directa.md` (a standing instruction to run `directa context`, not a live snapshot, because Grok home rules apply to every project and cover the first tool of a turn; the text lives in `HarnessStandingInstruction`, shared with OpenCode). OpenCode has no session-start injection point at all, so its adapter wires that same standing instruction through the `instructions` array of the winning global config (opencode.jsonc preferred over opencode.json) and never writes `~/.config/opencode/AGENTS.md`, which would shadow the `~/.claude/CLAUDE.md` fallback OpenCode reads. Do not register a Stop hook to smuggle additionalContext: Stop additionalContext is injected as a user message and continues the turn.
