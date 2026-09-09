# Changesets

Version and changelog for GitHub releases. This repo is a Swift product: the root `package.json` is private and exists only so Changesets can bump `vX.Y.Z` tags and write `CHANGELOG.md`. Nothing is published to npm.

## Workflow

1. With a user-facing change, run `npm run changeset` (or `npx changeset`) and pick patch / minor / major. Internal-only work (CI, docs for agents, refactor with no behavior change) never gets a changeset. The body is changelog text for someone using directa: what changed for them, no internals, and a term of art gets a short plain-English gloss on first use.
2. Merge the PR. On `main`, the Release workflow opens or updates a **Version Packages** PR.
3. Merge that PR when ready. The workflow tags `vX.Y.Z` (matching historical releases) and creates the GitHub release from the changelog.

`npm run version` also syncs `Sources/DirectaKit/Model/Models.swift` (`DirectaVersion.version`) from `package.json` so `directa --version` and the app bundle stay aligned.

Changelog lines still link the PR/commit via `@changesets/changelog-github`. The local `changelog.cjs` wrapper drops "Thanks @quantizor" (maintainer self-thanks) and keeps thanks for other contributors.
