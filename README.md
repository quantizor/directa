<div align="center">
  <br>
  <img src="logo.svg" width="96" height="96" alt="directa">
  <h1>directa</h1>
  <p>An agent-friendly coordinator for many devservers and their unique configurations.</p>
</div>

A macOS menu bar app and a CLI, built so coding agents never lose track of the servers they started.

![directa menu bar popover showing per-project servers, status dots, and pinned heads](./docs/images/menu-bar.png)

A launchd-supervised daemon owns every server process. Sessions come and go, contexts compact, terminals close: the servers, their logs, and their crash forensics stay. A CLI designed for agents (stable `--json` everywhere) and a quiet menu bar app for you sit on top of the same unix socket.

## Why

Agents forget their dev servers. After a context compaction they spawn duplicates, tail dead logs, and fight over ports. directa gives them one idempotent verb (`directa ensure myproj`) that always lands in the same place, a session hook that re-teaches every new or compacted session what is running, and a `why` command that turns a broken server into a root-cause diagnosis.

## Quick start

Install with Homebrew:

```sh
brew install --cask quantizor/tap/directa
```

The fully qualified `quantizor/tap/directa` trusts only this cask. `brew upgrade` keeps it current, and the in-app footer offers a one-click upgrade when a new version ships. To remove it later: `directa uninstall`, then `brew uninstall --cask --zap quantizor/tap/directa` if Homebrew installed the app.

Prefer a direct download? Grab the latest DMG from [GitHub Releases](https://github.com/quantizor/directa/releases) and double-click `directa` inside it. Either way nothing changes until you confirm: the setup panel lists what it will do, then moves the app to Applications, installs the CLI and daemon (migrating any older `make install` copy), and offers agent hooks for Antigravity, Claude Code, Cursor, Grok Build, and OpenCode (checked by default when needed).

Or build from source (your agent can do this for you):

```sh
make install          # CLI + daemon to ~/.local/bin, app to /Applications, daemon installed
cd your-project
directa register --name myproj --cmd bun --cmd run --cmd dev --port 3000
directa ensure myproj  # idempotent: healthy is a no-op
directa why myproj     # root cause when something breaks
directa hook install --harness antigravity # Antigravity sessions rediscover servers automatically
directa hook install --harness claude      # same for Claude Code (default harness)
directa hook install --harness cursor      # same for Cursor
directa hook install --harness grok        # Grok Build: live snapshot after the first tool, plus a home rule
directa hook install --harness opencode    # OpenCode: standing instruction wired into its global config
```

Name each server after the project (`myproj`, not a generic `web`) so it is easy to spot in Spotlight and search, and give it a `<project>.localhost` host rather than bare `localhost`: the per-project subdomain keeps browser cookies, storage, and service workers isolated between projects.

Or write a `devservers.json` at the project root (multiple servers, dependencies, healthchecks, `*.localhost` host signatures, multi-headed proxies, lifecycle playbooks); `directa up` brings the whole project up in dependency order. `directa config check` validates the file against the daemon's own validator, the schema is in [docs/design.md](./docs/design.md), and the full CLI contract lives in [docs/cli-contract.md](./docs/cli-contract.md).

Commit that file where the whole team runs the same servers. Keep it gitignored and per-machine where the repository would rather not carry it: a shared checkout, a repository whose own docs should name no personal tooling, or a project where each person's ports and heads differ. Runtime behavior is identical either way; the difference is whether a fresh clone arrives with one. `directa config init` writes the file back from what the daemon already knows, so a gitignored one that goes missing can be recovered.

## The parts

- `ddirecta`: the daemon. Spool-file output capture (children survive daemon restarts without SIGPIPE), process-group plus descendant-sweep teardown, health-gated phases, crash forensics, structured logs with correlation marks, a unified event feed.
- `directa`: the CLI. `ensure`, `wait`, `up`/`down`, `logs --since-mark`, `mark`, `events`, `restart`, `why`, `open`, `switch`, `lock` (take exclusive access to a resource a server holds while a harness runs, leaving the server up by default or stopping it with `--pause`, and report when a command changed that resource while a server still held it open), `config init`, `doctor`, and launchd management. A server can list the config files it reads at boot and directa restarts it when one changes. Agents are the first-class consumer.
- `directa.app`: the menu bar. Presence dots with counts, per-project rows with click-to-open heads (pinnable), crash notifications, a dashboard with live logs, an event timeline, and a validating config editor. Every server and head is Spotlight-searchable.

## Building

`make build` and `make test`; `make app` / `make dmg` assemble the menu bar app (and a double-click-to-install disk image) without Xcode, and `make release-dmg` builds the signed, notarized release image maintainers ship. `scripts/smoke.sh` is the end-to-end gate. See `CLAUDE.md` for the codebase map and `CONTRIBUTING.md` for adding an agent-harness adapter and for release DMG signing secrets.
