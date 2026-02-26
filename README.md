# Fork Project Workflow

Automated tooling for forking third-party GitHub Actions into your organization with upstream sync, tag monitoring, and security scanning. Zero secrets required.

## Why

When your CI/CD pipelines depend on third-party GitHub Actions, you're exposed to supply chain attacks -- tag mutations, compromised maintainer accounts, or malicious code injection. Forking the Action and pinning to reviewed tags eliminates this risk.

This repo provides `fork-action.sh` to bootstrap forks with sync infrastructure and automated security scanning.

## How It Works

1. **`fork-action.sh`** (one-time setup) -- Creates the fork, workflows, manifest, and branch structure
2. **Sync Upstream** (weekly cron) -- Verifies upstream repo identity, fast-forward merges the `upstream-tracking` branch, opens a PR for review
3. **Sync Tags** (weekly cron) -- Detects new upstream releases, tag mutations, and tag deletions; creates issues for each
4. **Security Scan** (automatic) -- Runs CodeQL, dependency review, and diff summary on each sync PR

## Quick Start

```bash
# Fork a new action and pin a tag
./fork-action.sh acme/deploy-action --tag v2.0.0

# Fork into a specific org/user
./fork-action.sh acme/deploy-action --tag v2.0.0 --org my-org

# Add sync infra to an existing fork
./fork-action.sh acme/deploy-action --existing --org my-org

# Update sync infra on an existing fork
./fork-action.sh acme/deploy-action --existing --force-update --org my-org
```

## What fork-action.sh Creates

In the fork repository:

```
.github/workflows/
  sync-upstream.yml    # Syncs upstream changes, creates PR
  sync-tags.yml        # Monitors tag mutations, new releases, deletions
  security-scan.yml    # Runs CodeQL, dependency review + diff summary on sync PRs
FORK_MANIFEST.json     # Upstream provenance, repo identity, and sync state
CODEOWNERS             # Protects sync infrastructure and action definition files
```

No secrets are needed. Everything uses `GITHUB_TOKEN`. The security scan triggers automatically via `workflow_run` after sync-upstream completes, posts check runs and commit statuses on the PR, and satisfies branch protection.

## Security Features

- **Upstream repo identity verification** -- `FORK_MANIFEST.json` records the upstream GitHub repo ID; the sync workflow verifies it on every run to detect name squatting or repo transfer attacks
- **SHA-pinned actions** -- All actions in workflow templates are pinned to full commit SHAs, not mutable tags
- **Branch protection** -- Default branch requires 1 reviewer + `security-scan` status check + stale review dismissal; `upstream-tracking` branch blocks force-push and deletion
- **Input validation** -- Tag names and org/user names are validated to prevent injection attacks
- **CODEOWNERS** -- Protects `.github/`, `FORK_MANIFEST.json`, `CODEOWNERS`, `action.yml`, `action.yaml`, `Dockerfile`, and `dist/`
- **Scan concurrency** -- Security scans never cancel in-progress runs, preventing evasion

## Options

| Flag | Description |
|------|-------------|
| `--org <org>` | Target GitHub org or user (default: `tyler-technologies-oss`) |
| `--tag <tag>` | Pin a specific upstream tag (e.g., `v7.0.8`) |
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
.github/workflows/
  caller-sync-upstream.yml                  # Thin caller -> shared workflow
  caller-sync-tags.yml                      # Thin caller -> shared workflow
  caller-security-scan.yml                  # Thin caller -> shared workflow
templates/
  FORK_MANIFEST.json                        # Manifest template
  CODEOWNERS                                # CODEOWNERS template
docs/
  walkthrough.md                            # Step-by-step guide
  workflow-migration-example.yml            # Before/after migration example
```

## Related

- [fork-sync-shared-workflow](https://github.com/SamFleming-TylerTech/fork-sync-shared-workflow) -- Reusable workflows (all three callers delegate to this)
