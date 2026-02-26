# Fork-Sync Walkthrough

A step-by-step guide to forking a third-party GitHub Action, setting up automated sync, and detecting supply chain threats.

## The Problem

Your CI/CD pipeline uses a third-party action:

```yaml
- uses: some-vendor/deploy-action@v2.0.0
```

What happens when:

- The maintainer force-pushes `v2.0.0` to point at different code?
- A compromised account pushes a malicious v2.0.1?
- A dependency gets swapped out in a new release?

You wouldn't know. The tag resolves to whatever the upstream maintainer decides.

**Fork-sync fixes this.** You fork the action, pin to a reviewed commit, and get alerts when anything changes upstream.

---

## Prerequisites

- `gh` CLI, authenticated (`gh auth login`)
- `git`, `jq`
- Write access to the target GitHub org or user account

---

## Step 1: Fork an Action

```bash
./fork-action.sh some-vendor/deploy-action --tag v2.0.0 --org my-org
```

This:

- Creates `my-org/deploy-action` as a GitHub fork
- Adds an `upstream-tracking` branch
- Copies workflows (`sync-upstream.yml`, `sync-tags.yml`, `security-scan.yml`)
- Generates `FORK_MANIFEST.json` with upstream provenance and repo identity (GitHub repo ID)
- Adds `CODEOWNERS` for review enforcement on sync infrastructure and action definition files
- Creates required labels (`upstream-sync`, `needs-security-review`, `upstream-release`, `security-alert`, `upstream-tag-deleted`)
- Enables GitHub Actions, issues, and vulnerability alerts on the fork
- Configures branch protection:
  - Default branch: 1 required reviewer, stale review dismissal, `security-scan` status check, enforced for admins
  - `upstream-tracking`: force-push and deletion blocked, enforced for admins
- Creates an annotated tag `v2.0.0` pinned to the reviewed upstream commit

No secrets are needed. Everything uses `GITHUB_TOKEN`.

Output:

```
============================================================
  Fork Setup Complete
============================================================

  Fork URL:         https://github.com/my-org/deploy-action
  Upstream:         https://github.com/some-vendor/deploy-action
  Default branch:   main
  Tracking branch:  upstream-tracking
  Pinned tag:       v2.0.0

  Next steps:
    1. Review the fork
    2. Verify GitHub Actions are running
    3. No secrets required (uses GITHUB_TOKEN).
    4. Reference the pinned tag in workflows:
         uses: my-org/deploy-action@v2.0.0
============================================================
```

### Verify Issues Are Enabled

GitHub forks have issues disabled by default. The script enables them, but this
can sometimes revert. Verify after setup:

```bash
# Check
gh api repos/my-org/deploy-action --jq '.has_issues'

# Re-enable if needed
gh repo edit my-org/deploy-action --enable-issues
```

## Step 2: Update Your Workflows

Replace third-party references with your fork:

```yaml
# Before (vulnerable to supply chain attacks)
- uses: some-vendor/deploy-action@v2.0.0

# After (pinned to your reviewed fork)
- uses: my-org/deploy-action@v2.0.0
```

For maximum security, pin to the full commit SHA:

```yaml
- uses: my-org/deploy-action@a1b2c3d4e5f6...
```

---

## What Happens Automatically

Once the fork exists, three workflows run on schedule.

### Sync Upstream (Mondays)

Checks if the upstream repo has new commits. If it does:

1. Verifies upstream repo identity against the `repo_id` in `FORK_MANIFEST.json` (detects name squatting or repo transfer attacks)
2. Fast-forward merges `upstream-tracking` with upstream's latest
3. Updates `FORK_MANIFEST.json` with the new sync SHA and date
4. Opens a PR to your default branch with:
   - Diff stats
   - List of security-relevant file changes (action manifests, scripts, Dockerfiles, package.json, dist/, node_modules/)
   - Link to the upstream commit comparison
   - Review checklist

If the fast-forward merge fails (upstream history was rewritten), the workflow creates a divergence issue with investigation steps and security guidance.

Example PR body:

```
## Upstream Sync

Syncing changes from `some-vendor/deploy-action@main`.

### Diff Stats
 action.yml    |  5 +++++
 entrypoint.sh | 29 ++++++++++++++++++-----------
 2 files changed, 23 insertions(+), 11 deletions(-)

### Security-Relevant Files
action.yml
entrypoint.sh

### Review Checklist
- [ ] Check action.yml for unexpected changes
- [ ] Check for new or modified dependencies
- [ ] Check for obfuscated or minified code changes
- [ ] Run security scan on changed files
- [ ] Verify no secrets or credentials exposed
```

### Sync Tags (Wednesdays)

Compares upstream tags against fork tags. Creates issues for three scenarios:

**Tag Mutation** -- upstream force-pushed a tag to a different commit:

```
[SECURITY ALERT] Upstream tag mutated: v2.0.0

Fork (pinned):      a1b2c3d...
Upstream (changed): x9y8z7w...

This could indicate a supply chain attack.
The fork's tag is safe -- it still points to the original reviewed commit.
```

**New Release** -- upstream created a new tag:

```
[Security Review] New upstream release: v2.1.0

Security Review Checklist:
- [ ] Review the changelog and release notes
- [ ] Diff against the previous tag
- [ ] Check for new or modified dependencies
- [ ] Run static analysis on changed files
- [ ] Check for added or modified binary files

After review, create the tag:
  git tag -a v2.1.0 <sha> -m "Reviewed: 2025-01-15 by @reviewer"
  git push origin v2.1.0
```

**Tag Deletion** -- upstream removed a tag:

```
[Security Notice] Upstream tag removed: v2.0.0

The tag exists in the fork but is no longer present upstream.
Could indicate a retracted release or account compromise.
The fork's tag is unaffected.
```

### Security Scan (on every sync PR)

Triggers automatically after sync-upstream completes via `workflow_run`. Runs three checks in parallel:

| Check | What it does |
|-------|-------------|
| `codeql` | Runs CodeQL static analysis on JavaScript/TypeScript; informational only, results appear in the Code Scanning tab. Actions in other languages are not scanned by CodeQL but still receive dependency review and diff summary. |
| `dependency-review` | Scans for new vulnerabilities in dependency changes |
| `diff-summary` | Posts a comment with changed file stats, flags action manifests, scripts, binaries |

After all checks complete, a `report-status` job posts check runs and a `security-scan` commit status on the PR head. The aggregate status is based on `dependency-review` and `diff-summary`; CodeQL is excluded from the aggregate since findings are tracked separately in the Code Scanning tab.

```
sync-upstream completes
  -> workflow_run fires
    -> security-scan triggers
      -> find-pr discovers the open PR
      -> codeql, dependency-review, diff-summary run in parallel
      -> report-status posts check runs + commit status on PR
```

All actions in the workflow templates are SHA-pinned to prevent supply chain attacks on the scan infrastructure itself.

The security scan concurrency is set to never cancel in-progress runs, preventing an attacker from evading scans by rapidly pushing commits.

---

## Example: End-to-End

This example uses `uprightbass360/fork-test` as the upstream and `SamFleming-TylerTech` as the fork target.

### Create the fork

```bash
./fork-action.sh uprightbass360/fork-test --tag v1.0.0 --org SamFleming-TylerTech
```

No secrets needed -- the fork is ready to use immediately.

### Simulate upstream changes

In the upstream repo, a maintainer:
1. Pushes a new commit (adds a feature)
2. Force-pushes `v1.0.0` to a different commit (tag mutation)
3. Creates `v1.1.0` (new release)
4. Deletes an existing tag (tag removal)

### Trigger the sync

```bash
gh workflow run sync-upstream.yml --repo SamFleming-TylerTech/fork-test
gh workflow run sync-tags.yml    --repo SamFleming-TylerTech/fork-test
```

### Results

| Artifact | What it shows |
|----------|--------------|
| Sync PR | Upstream sync with diff stats, security-relevant files, review checklist |
| PR checks | `security-scan`, `security-scan/codeql`, `security-scan/dependency-review`, `security-scan/diff-summary` |
| PR comment | Security diff summary (files changed, lines added/removed, manifest/script/binary changes) |
| Issue: divergence | Upstream history was rewritten, with investigation steps and security guidance |
| Issue: tag mutation | `v1.0.0` moved to a different commit with comparison link |
| Issue: new release | `v1.1.0` detected with security review checklist |
| Issue: tag deleted | Tag removed from upstream, fork copy preserved |

---

## How It Scales

All three workflows (`sync-upstream.yml`, `sync-tags.yml`, `security-scan.yml`) are thin callers that delegate to reusable workflows in `fork-sync-shared-workflow`. They auto-update via the `@v1` floating tag -- push a fix to the shared repo and every fork picks it up on the next run.

To push caller template updates to existing forks:

```bash
./fork-action.sh some-vendor/deploy-action --existing --force-update --org my-org
```

---

## Useful Commands

```bash
# Manually trigger a sync
gh workflow run sync-upstream.yml --repo my-org/deploy-action

# Force sync even if already up to date
gh workflow run sync-upstream.yml --repo my-org/deploy-action -f force=true

# Check sync status
gh run list --repo my-org/deploy-action --limit 5

# View sync PR
gh pr list --repo my-org/deploy-action --label upstream-sync

# View security issues
gh issue list --repo my-org/deploy-action --label security-alert

# Add sync infra to an existing fork
./fork-action.sh some-vendor/deploy-action --existing --org my-org

# Update sync infra (overwrite workflows, manifest)
./fork-action.sh some-vendor/deploy-action --existing --force-update --org my-org

# Verify fork setup
./verify-repo.sh my-org/deploy-action
```
