# Fork Project Workflow

Automated tooling for forking third-party GitHub Actions into your organization with upstream sync, tag monitoring, and security scanning.

## Why

When your CI/CD pipelines depend on third-party GitHub Actions, you're exposed to supply chain attacks -- tag mutations, compromised maintainer accounts, or malicious code injection. Forking the Action and pinning to reviewed tags eliminates this risk.

This repo provides `fork-action.sh` to bootstrap forks with sync infrastructure and automated security scanning.

## How It Works

1. **`fork-action.sh`** (one-time setup) -- Creates the fork, workflows, manifest, and branch structure
2. **Sync Upstream** (weekly cron) -- Fast-forward merges the `upstream-tracking` branch with upstream's default branch, opens a PR for review
3. **Sync Tags** (weekly cron) -- Detects new upstream releases, tag mutations, and deletions
4. **Security Scan** (automatic) -- Runs dependency review and posts a diff summary on each sync PR

## Quick Start

```bash
# Fork a new action (no-app mode, zero secrets needed)
./fork-action.sh peter-evans/create-pull-request --tag v7.0.8 --no-app

# Fork into a specific org/user
./fork-action.sh irongut/CodeCoverageSummary --tag v1.3.0 --org SamFleming-TylerTech --no-app

# Fork with GitHub App mode (requires app secrets)
./fork-action.sh peter-evans/create-pull-request --tag v7.0.8

# Add sync infra to an existing fork
./fork-action.sh irongut/CodeCoverageSummary --existing --org SamFleming-TylerTech --no-app

# Update sync infra on an existing fork
./fork-action.sh irongut/CodeCoverageSummary --existing --force-update --org SamFleming-TylerTech --no-app
```

## Modes

### No-App Mode (`--no-app`)

Recommended for most users. Uses `GITHUB_TOKEN` for everything -- no secrets, no GitHub App setup. The security scan triggers automatically via `workflow_run` after sync-upstream completes.

### App Mode (default)

Uses a GitHub App token to create PRs, which allows the security scan to trigger via `on: pull_request`. Requires a GitHub App with `FORK_SYNC_APP_ID` and `FORK_SYNC_APP_PRIVATE_KEY` secrets. See the [walkthrough](docs/walkthrough.md) for setup instructions.

See [docs/app-vs-noapp-comparison.md](docs/app-vs-noapp-comparison.md) for a detailed comparison.

## What fork-action.sh Creates

In the fork repository:

```
.github/workflows/
  sync-upstream.yml    # Syncs upstream changes, creates PR
  sync-tags.yml        # Monitors tag mutations, new releases, deletions
  security-scan.yml    # Runs dependency review + diff summary on sync PRs
FORK_MANIFEST.json     # Upstream provenance and sync state
CODEOWNERS             # Protects sync infrastructure files
```

## Options

| Flag | Description |
|------|-------------|
| `--org <org>` | Target GitHub org or user (default: `tyler-technologies-oss`) |
| `--tag <tag>` | Pin a specific upstream tag (e.g., `v7.0.8`) |
| `--no-app` | Skip GitHub App requirement (uses GITHUB_TOKEN only) |
| `--existing` | Operate on an already-forked repo |
| `--force-update` | Overwrite existing sync infrastructure (use with `--existing`) |
| `--templates-repo <r>` | Central templates repo (default: `SamFleming-TylerTech/fork-sync-shared-workflow`) |
| `--templates-ref <ref>` | Central templates ref/tag (default: `v1`) |

Environment variables `FORK_ORG`, `TEMPLATES_REPO`, and `TEMPLATES_REF` can also be used.

## Prerequisites

- `gh` CLI (authenticated)
- `git`
- `jq`

## Repository Layout

```
fork-action.sh                              # Main bootstrap script
verify-repo.sh                              # Fork verification script
set-secrets.sh                              # Secret setup helper (app mode)
.github/workflows/
  caller-sync-upstream.yml                  # App mode: thin caller template
  caller-sync-upstream-noapp.yml            # No-app mode: standalone sync template
  caller-sync-tags.yml                      # Caller template (both modes)
  caller-security-scan.yml                  # App mode: thin caller template
  caller-security-scan-noapp.yml            # No-app mode: workflow_run template
templates/
  FORK_MANIFEST.json                        # Manifest template
  CODEOWNERS                                # CODEOWNERS template
docs/
  walkthrough.md                            # Step-by-step guide
  app-vs-noapp-comparison.md                # Mode comparison
  workflow-migration-example.yml            # Before/after migration example
```

## Related

- [fork-sync-shared-workflow](https://github.com/SamFleming-TylerTech/fork-sync-shared-workflow) -- Reusable workflows referenced by app mode caller templates
