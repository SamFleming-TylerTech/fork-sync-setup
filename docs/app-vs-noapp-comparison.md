# No-App vs App Mode Comparison

Comparison based on end-to-end tests using `acme/deploy-action` forked into `my-org/deploy-action`.

## Artifacts Created

| Artifact | App Mode | No-App Mode |
|----------|----------|-------------|
| Sync PR | PR created by GitHub App token | PR created by `GITHUB_TOKEN` |
| PR body (diff stats, security files, checklist) | Identical | Identical |
| Diff summary PR comment | Posted by `security-scan.yml` | Posted by `security-scan.yml` |
| `security-scan` commit status on PR | Created by workflow check | Created by `report-status` job |
| Tag mutation issue | Created | Created |
| New release issue | Created | Created |
| Tag deletion issue | Created | Created |

## Behavioral Differences

| Aspect | App Mode | No-App Mode |
|--------|----------|-------------|
| **Secrets required** | `FORK_SYNC_APP_ID` + `FORK_SYNC_APP_PRIVATE_KEY` | None |
| **Setup complexity** | GitHub App creation, installation, per-repo secrets | Zero additional setup |
| **Workflows deployed** | 3 (`sync-upstream`, `sync-tags`, `security-scan`) | 3 (`sync-upstream`, `sync-tags`, `security-scan`) |
| **Security scan trigger** | `on: pull_request` (triggered by PR creation) | `on: workflow_run` (triggered by sync-upstream completion) |
| **PR author** | GitHub App bot | `github-actions[bot]` |
| **dependency-review** | Runs in PR context | Runs with explicit `base-ref`/`head-ref` |
| **CodeQL** | Works if languages detected | Same -- non-blocking for status check |
| **diff-summary** | Works | Works |
| **Branch protection check** | `security-scan` | `security-scan` (posted via commit status API) |
| **Centralized updates** | All 3 workflows are thin callers -- updates propagate automatically | `sync-upstream` and `security-scan` are standalone -- must `--force-update` to update |
| **sync-tags updates** | Thin caller -- auto-updates | Thin caller -- auto-updates |

## How No-App Workflow Chaining Works

The key challenge with `GITHUB_TOKEN` is that PRs it creates don't trigger `on: pull_request` workflows. No-app mode solves this with `workflow_run`:

```
1. sync-upstream.yml runs (cron or manual trigger)
2. Creates PR using GITHUB_TOKEN
3. Workflow completes successfully
4. GitHub fires workflow_run event
5. security-scan.yml triggers automatically
6. Finds the open sync PR
7. Runs dependency-review, codeql, diff-summary
8. Posts commit status "security-scan" on the PR head SHA
9. Branch protection check is satisfied
```

## Key Trade-off

The **app mode** gives fully centralized maintenance -- all logic lives in shared reusable workflows and propagates to all forks automatically via the `@v1` floating tag.

The **no-app mode** eliminates all secret management and GitHub App overhead. The trade-off is that `sync-upstream.yml` and `security-scan.yml` are standalone workflows (not thin callers), so changes require `--force-update` to propagate. However, `sync-tags.yml` remains a thin caller and auto-updates.

For most teams, the no-app mode is the better default -- zero setup, no secrets to manage, and the workflow logic rarely changes once stable.
