# AGENTS.md

Guidelines for AI agents (GitHub Copilot, Devin, etc.) contributing to this repo.

## Repository purpose

This is a GitHub Action that patches CodeQL to run on ARM64 Linux by replacing
the x86_64 `preload_tracer` binary with a stub and providing an ARM64 JDK for
the evaluation engine. The entire repo is ARM64-first by design.

## ARM64-first rule

**All CI jobs that can run on ARM64 must do so.**
Use `ubuntu-24.04-arm` for every job unless the task is architecturally
impossible on ARM64 (e.g. building x86_64 artifacts). Do not default to
`ubuntu-latest` (x86_64). This is dogfooding — the repo exists to make
ARM64 first-class for CodeQL users; it must model that itself.

## Commit messages — Conventional Commits

All commits **must** follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<optional scope>): <subject>

<optional body — lines ≤ 100 chars>
```

**Allowed types:** `build` `chore` `ci` `docs` `feat` `fix` `perf`
`refactor` `revert` `style` `test`

**Rules enforced by commitlint (CI) and the local pre-commit hook:**
- `subject-empty` — subject must not be empty
- `type-empty` — type must be present
- `body-max-line-length` — body lines must not exceed 100 characters
- Trailers like `Co-authored-by:` are exempt from the line-length rule

**Local hook setup** (one-time, per clone):
```bash
git config core.hooksPath .githooks
```

This activates `.githooks/commit-msg`, which validates the message locally
before `git commit` completes — same rules as the CI commitlint job.

Do **not** include `Agent-Logs-Url:` or other long auto-generated trailers
in commit bodies; they will exceed the 100-char body line limit.

## Release workflow — stub tracer is bundled with the version release

The `preload_tracer-arm64` binary is **not** released independently.
It is built inside the `build-stub-tracer` job (ARM64 runner) of
`.github/workflows/publish-marketplace.yml` and attached as a release asset
alongside the version tag. Do not recreate a standalone stub-tracer release
workflow.

A release is triggered by bumping `VERSION` (strict semver `X.Y.Z`) on `master`.
Every PR must include a `VERSION` bump — the `version-bump` CI job enforces this.

## Self-scan (dogfooding CodeQL)

`.github/workflows/codeql.yml` scans this repo using this action itself on
`ubuntu-24.04-arm`. It covers:
- `c-cpp` — `src/stub-tracer.c`, built with `gcc -static -O2`, using `./` to
  bootstrap CodeQL via the action under development
- `actions` — workflow YAML files, `build-mode: none`

Results are uploaded to GitHub Security (SARIF). Do not remove or disable
this workflow; it validates that the action works end-to-end on the code it ships.

## File layout

| Path | Purpose |
|------|---------|
| `action.yml` | Action entrypoint and input definitions |
| `patch-codeql.sh` | Main patching logic (bash) |
| `src/stub-tracer.c` | ARM64 stub that replaces `preload_tracer` |
| `VERSION` | Strict semver version string — bump to trigger a release |
| `.github/workflows/publish-marketplace.yml` | Builds stub + tags + GitHub Release |
| `.github/workflows/codeql.yml` | Self-scan on ARM64 (dogfood) |
| `.github/workflows/test.yml` | Compatibility matrix, SARIF check, performance report |
| `.githooks/commit-msg` | Local commitlint hook |

## What agents should not do

- Do not use `ubuntu-latest` for jobs that can run on `ubuntu-24.04-arm`
- Do not create a standalone release workflow for `stub-tracer`; it is part
  of the publish workflow
- Do not add `Agent-Logs-Url:` lines to commit bodies
- Do not squash the stub-tracer build into the checkout step; keep it as a
  separate named job so failures are obvious in the Actions UI
- Do not bypass `git config core.hooksPath .githooks` — the hook must stay active
