# Contributing to ui-atlas

Thanks for contributing. This guide is the shared entry point for human contributors and AI agents: how to set up the environment, which checks to run, how to write issues, branches, commits, and pull requests, and what evidence UI changes need. For what the product is and how to use it, see the [README](README.md) ([简体中文](README.zh-CN.md)).

## Before you start

- Read [GLOSSARY.md](GLOSSARY.md). Terms follow the glossary in docs, code comments, and UI copy.
- Read the [ADRs](docs/adr/) relevant to your change, especially [ADR 0006](docs/adr/0006-native-design-document.md): the App is the sole owner of the design document, and human and agent edits share one undo history.
- [docs/macos.md](docs/macos.md) is the authoritative spec for canvas interaction behavior.
- [CLAUDE.md](CLAUDE.md) has the architecture overview and where code lives.
- **Do not reintroduce removed pieces.** [ADR 0002](docs/adr/0002-remove-browser-shell.md) removed the browser shell (`apps/atlas`, `dev:web`), and [ADR 0006](docs/adr/0006-native-design-document.md) removed the web-work pipeline (`catalog.json`, `examples/`, the preview launcher, WKWebView frames). If you really need one back, open an issue and write a new ADR first.

## Environment and commands

Requires macOS 14+, Swift 6 (the Xcode Command Line Tools are enough; no full Xcode and no third-party Swift packages), Node.js 22.12+, and pnpm 11.7.0.

```bash
pnpm install
pnpm dev               # build the app in debug and open it
pnpm build:native      # release build + ad-hoc signing → dist/ui-atlas.app
pnpm test:native       # run swift test on native/ (AtlasCoreTests + AtlasAppTests)
pnpm check             # Vitest (tests/): MCP tools, MCP server, chat harness
pnpm mcp               # start the ui-atlas MCP server over stdio (usually launched by the agent)
```

Run a single test (these call Vitest and SwiftPM directly; they are not `package.json` scripts):

```bash
pnpm vitest run tests/control-tools.test.ts -t "<name>"
swift test --package-path native --filter AtlasCoreTests.<SuiteOrTest>
```

Notes:

- The Node tests start real local sockets, HTTP servers, and child processes, so they need loopback networking. A sandbox that forbids listening on localhost makes them fail spuriously.
- `pnpm test:native` and `pnpm build:native` pin SwiftPM's scratch/cache directories under `/private/tmp/ui-atlas-native-*` (override with `UI_ATLAS_SWIFT_SCRATCH` / `UI_ATLAS_SWIFT_MODULE_CACHE`). **Do not run two Swift builds on the same scratch directory at once.**
- When tuning pan/zoom performance, set `UI_ATLAS_FRAME_LOG=1`; the app prints `[frame] hitches=N frames=M` once per second.

## Issues

Create and track tasks in [GitHub Issues](https://github.com/Bald-M/ui-atlas/issues); do not keep task records in the repository. `.scratch/<feature>/` is only for drafting longer specs or plans.

**Title**: `[Type][Priority] Area: summary`, e.g. `[Bug][P1] Canvas: layers flicker while dragging`.

- Type: `Bug`, `Enhancement` (new features and refactors), `Release`, or `Documentation`.
- Priority, judged by impact and urgency (never `[P?]`):

  | Priority | Meaning |
  | --- | --- |
  | P0 | App unusable, data loss, or a security problem |
  | P1 | A core flow is broken with no workaround |
  | P2 | A defect with a workaround, or a routine improvement |
  | P3 | A polish detail that can wait |

**Labels**: `bug`, `enhancement`, or `documentation`, matching the type.

**Body sections**:

- Bug: Problem, Steps to reproduce, Evidence, Impact, Acceptance criteria, Non-goals
- Feature: Background, Current behavior, Expected behavior, Acceptance criteria, Non-goals, References
- Refactor: Background, Current problem, Goal, Scope, Acceptance criteria, Non-goals, Main code locations

Write acceptance criteria as a verifiable `- [ ]` checklist, and **always include Non-goals**. The body holds only lasting product and engineering facts; progress updates and one-off command output go in comments or the PR.

## Branches and commits

- The default branch is `main`. Work on a task branch, push it, and open a PR against `main`.
- Branch name: `claude/<issue-number>-<summary>`, e.g. `claude/71-contributing`, or `claude/<summary>` without an issue. Human contributors may use their own prefix.
- Commit messages and PR titles follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/): `type(scope): summary`, with the summary in Chinese, matching the existing history.
  - type: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `style`, `chore`
  - scope: a product area or engineering boundary; common ones are `canvas`, `app`, `agent`, `file`, `readme`, `changelog`, `release`, `repo`. Never a branch name or "update files".
  - Examples from the history: `feat(canvas): 按住空格时光标立即变为抓手`, `fix(file): 导出 .uiatlas 文件类型，打开面板与 Finder 都能打开工程文件`
- Stage only your task's files; do not `git add -A` / `git add .`.

## Pull requests

The PR title uses the commit format. PRs are squash-merged, and the merge commit title gets the PR number appended. The body has these sections:

- **Summary**: 2–5 outcome-focused bullets
- **Related issue**: `Closes #n`, `Refs #n`, or `N/A: reason`
- **Verification**: tick only commands you actually ran and that passed, with results; list anything not run and why
- **Release notes**: one user-facing sentence, or N/A
- **Risk and compatibility**: API / shared contracts (including MCP tools and the control protocol), the `.uiatlas` file format, permissions / security, configuration / rollback; write N/A where nothing is affected
- **UI evidence**: light and dark screenshots for UI changes, otherwise N/A
- **Checklist**

Keep the PR as a **draft** until verification, evidence, and external dependencies are complete, then mark it ready for review. Docs-only PRs get the `documentation` label.

## Verification gate

**No CI is configured; local checks are the gate.** Before merging, these must pass locally:

- [ ] `pnpm check`
- [ ] `pnpm test:native`
- [ ] For native UI changes: `pnpm build:native`, plus a check in the real App in both light and dark appearance

When fixing a bug, first write a test that reproduces it. Testable rules belong in `AtlasCore` (no AppKit dependency). Never delete or skip a valid test to make a check pass.

## UI evidence

Check UI changes in the real App in both **light and dark** appearance, and put the screenshots in [`docs/evidence/`](docs/evidence/): one light and one dark, named `<subject>-light` / `<subject>-dark` (e.g. `launch-window-light.jpg`, `launch-window-dark.jpg`). List the paths in the PR's UI evidence section. Mock or test renders do not count as acceptance in the real App.

## Documentation conventions

- Language: project docs (README, CHANGELOG, `GLOSSARY.md`, `docs/`, ADRs), code comments, test descriptions, MCP tool descriptions, and error messages are in English. The App UI copy is in Chinese for now; when docs name a menu, panel, or button, describe it in English and keep the App's Chinese label in parentheses the first time, e.g. *File menu → Open Recent (打开最近)*.
- Record new terms in [GLOSSARY.md](GLOSSARY.md) and architecture decisions in [docs/adr/](docs/adr/).
- Record user-visible changes under `Unreleased` in [CHANGELOG.md](CHANGELOG.md); they are moved into the matching version on release ([Keep a Changelog](https://keepachangelog.com/en/1.1.0/)).
- When canvas interaction behavior changes, update [docs/macos.md](docs/macos.md) too.

## Security

- Never commit, or paste into issues, PRs, or comments, `.env` files, API keys, tokens, Keychain contents, or other secrets (`.env` is in `.gitignore`).
- The chat panel's API key lives only in the local Keychain (service `ui-atlas.agent`) and reaches the harness only through the `UI_ATLAS_API_KEY` environment variable. Do not write it into the repository, project files, preferences, or logs.
- The control channel is open only to the current user and does not listen on a network address; do not turn it into a network service.
