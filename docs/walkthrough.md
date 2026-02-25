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

## Choosing a Mode

Fork-sync supports two modes. Choose the one that fits your setup:

| | No-App Mode (default) | App Mode |
|-|----------------------|----------|
| **Setup** | Zero additional setup | Requires GitHub App + secrets |
| **Secrets** | None | `FORK_SYNC_APP_ID` + `FORK_SYNC_APP_PRIVATE_KEY` |
| **Security scan trigger** | `workflow_run` (auto-triggers after sync completes) | `on: pull_request` (triggered by PR creation) |
| **Maintenance** | `sync-upstream` and `security-scan` are standalone -- use `--force-update` to propagate changes | All 3 workflows are thin callers -- updates propagate automatically |
| **When to use** | Most teams, personal accounts, quick setup | Orgs with an existing GitHub App, teams needing fully centralized workflow logic |

**Use `--no-app`** (recommended for most users):

```bash
./fork-action.sh some-vendor/deploy-action --tag v2.0.0 --org my-org --no-app
```

**Use app mode** (omit `--no-app`):

```bash
./fork-action.sh some-vendor/deploy-action --tag v2.0.0 --org my-org
```

See [App vs No-App Comparison](app-vs-noapp-comparison.md) for a detailed breakdown.

---

## Setting Up a GitHub App (App Mode Only)

Skip this section if using `--no-app`.

The sync-upstream workflow uses a GitHub App token to create PRs. This allows the security scan to auto-trigger on new PRs (a regular `GITHUB_TOKEN` can't trigger `on: pull_request` workflows). Corp-Dev will need to assist with this section. The secrets can be set as org-level secrets so all forks inherit them.

### 1. Create the App

1. Go to **GitHub Settings > Developer settings > GitHub Apps > New GitHub App**
   - For an org: `https://github.com/organizations/YOUR-ORG/settings/apps/new`
   - For a personal account: `https://github.com/settings/apps/new`

2. Fill in the basics:
   - **App name**: `fork-sync` (or any name you prefer)
   - **Homepage URL**: Your org's GitHub URL
   - **Webhook**: Uncheck "Active" (not needed)

3. Set permissions (under **Repository permissions**):
   - **Contents**: Read & write
   - **Issues**: Read & write
   - **Pull requests**: Read & write
   - **Metadata**: Read-only (auto-selected)

4. Under **Where can this app be installed?**, select:
   - "Only on this account" (recommended)

5. Click **Create GitHub App**.

### 2. Note the App ID

After creation, you'll land on the app's settings page. The **App ID** is displayed near the top (e.g., `1234567`). Save this -- you'll need it as a repo secret.

### 3. Generate a Private Key

1. Scroll down to **Private keys**
2. Click **Generate a private key**
3. A `.pem` file downloads automatically
4. Save this file securely -- you'll need its contents as a repo secret

### 4. Install the App

1. (for your account) Go to Your account Settings > Integrations > Applications
   (Or for an org) Organization Settings > Installed GitHub Apps
2. Click Configure next to the app
3. Change the repository access

### 5. Add Secrets to Your Fork

Each forked repo needs two secrets:

```bash
# Set the App ID
gh secret set FORK_SYNC_APP_ID --repo YOUR-ORG/forked-action

# Set the private key (paste the full .pem contents when prompted)
gh secret set FORK_SYNC_APP_PRIVATE_KEY --repo YOUR-ORG/forked-action < path/to/private-key.pem
```

Or set them as **org-level secrets** so all forks inherit them:

```bash
gh secret set FORK_SYNC_APP_ID --org YOUR-ORG --visibility all
gh secret set FORK_SYNC_APP_PRIVATE_KEY --org YOUR-ORG --visibility all < path/to/private-key.pem
```

---

## Step 1: Fork an Action

### No-App Mode

```bash
./fork-action.sh some-vendor/deploy-action --tag v2.0.0 --org my-org --no-app
```

### App Mode

```bash
./fork-action.sh some-vendor/deploy-action --tag v2.0.0 --org my-org
```

Both modes perform the same steps:

- Creates `my-org/deploy-action` as a GitHub fork
- Adds an `upstream-tracking` branch
- Copies workflows (`sync-upstream.yml`, `sync-tags.yml`, `security-scan.yml`)
- Generates `FORK_MANIFEST.json` with upstream provenance
- Adds `CODEOWNERS` for review enforcement
- Creates required labels (`upstream-sync`, `needs-security-review`, etc.)
- Enables branch protection (1 reviewer + `security-scan` status check required)
- Creates an annotated tag `v2.0.0` pinned to the reviewed upstream commit

Output:

```
============================================================
  Fork Setup Complete
============================================================

  Fork URL:         https://github.com/my-org/deploy-action
  Upstream:         https://github.com/some-vendor/deploy-action
  Default branch:   main
  Tracking branch:  upstream-tracking
  Templates repo:   SamFleming-TylerTech/fork-sync-shared-workflow@v1
  Pinned tag:       v2.0.0

  Next steps:
    1. Review the fork
    2. Verify GitHub Actions are running
    3. No secrets required (using GITHUB_TOKEN).
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

1. Fast-forward merges `upstream-tracking` with upstream's latest
2. Opens a PR to your default branch with:
   - Diff stats
   - List of security-relevant file changes (action.yml, scripts, Dockerfiles)
   - Link to the upstream commit comparison
   - Review checklist
3. Security scan auto-triggers (via `workflow_run` in no-app mode, via PR event in app mode)

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

Compares upstream tags against fork tags. Detects three scenarios:

**Tag Mutation** -- upstream force-pushed a tag to a different commit:

```
[SECURITY ALERT] Upstream tag mutated: v2.0.0

Fork (pinned):     a1b2c3d...
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

Triggers automatically after sync-upstream completes. Runs two checks in parallel:

| Check | What it does |
|-------|-------------|
| `dependency-review` | Scans for new vulnerabilities in dependency changes |
| `diff-summary` | Posts a comment with changed file stats, flags action manifests, scripts, binaries |

After all checks complete, a `report-status` job posts a `security-scan` commit status on the PR head, satisfying the branch protection requirement.

**How it chains (no-app mode):**

```
sync-upstream completes
  -> workflow_run fires
    -> security-scan triggers
      -> find-pr discovers the open PR
      -> dependency-review, diff-summary run in parallel
      -> report-status posts commit status on PR
```

**How it chains (app mode):**

```
sync-upstream creates PR with app token
  -> on: pull_request fires
    -> security-scan triggers via reusable workflow
```

---

## Example: End-to-End (No-App Mode)

This example uses `acme/deploy-action` as the upstream and `SamFleming-TylerTech` as the fork target.

### Create the fork

```bash
./fork-action.sh acme/deploy-action --tag v1.0.1 --org SamFleming-TylerTech --no-app
```

No secrets needed -- the fork is ready to use immediately.

### Simulate upstream changes

In the upstream repo, a maintainer:
1. Pushes a new commit (adds a feature)
2. Force-pushes `v1.0.0` to a different commit (tag mutation)
3. Creates `v1.1.0` (new release)
4. Deletes `v1.0.1` (tag removal)

### Trigger the sync

```bash
gh workflow run sync-upstream.yml --repo my-org/deploy-action
gh workflow run sync-tags.yml    --repo my-org/deploy-action
```

### Results

| Artifact | What it shows |
|----------|--------------|
| Sync PR | Upstream sync with diff stats, security-relevant files, review checklist |
| PR checks | `security-scan: pass` status posted on PR head |
| PR comment | Security diff summary (files changed, lines added/removed, manifest/script/binary changes) |
| Issue: tag mutation | `v1.0.0` moved to a different commit with comparison link |
| Issue: new release | `v1.1.0` detected with security review checklist |
| Issue: tag deleted | `v1.0.1` removed from upstream, fork copy preserved |

---

## Example: End-to-End (App Mode)

This example uses `acme/deploy-action` as the upstream and `SamFleming-TylerTech` as the fork target.

### Create the fork

```bash
./fork-action.sh acme/deploy-action --tag v1.0.1 --org SamFleming-TylerTech
```

### Add secrets

```bash
REPO="my-org/deploy-action"

# Use the set-secrets.sh helper
./set-secrets.sh "$REPO" --app-id 1234567 --app-key path/to/private-key.pem
```

### Simulate upstream changes

Same as no-app example above.

### Trigger the sync

```bash
gh workflow run sync-upstream.yml --repo my-org/deploy-action
gh workflow run sync-tags.yml    --repo my-org/deploy-action
```

### Results

Same artifacts as no-app mode. The only difference is the PR author (GitHub App bot vs `github-actions[bot]`) and the security scan triggers via `on: pull_request` instead of `workflow_run`.

---

## How It Scales

### App Mode

The caller workflows in each fork are thin -- they just reference reusable workflows:

```yaml
# In the fork: .github/workflows/sync-upstream.yml
jobs:
  sync:
    uses: SamFleming-TylerTech/fork-sync-shared-workflow/.github/workflows/sync-upstream.yml@v1
    with:
      upstream_owner: some-vendor
      upstream_repo: deploy-action
    secrets: inherit
```

All the logic lives in `fork-sync-shared-workflow`. When you fix a bug or add a feature there:
- Tag it as `v1` (floating tag)
- Every fork picks up the change on the next run
- Zero per-fork maintenance

### No-App Mode

`sync-upstream.yml` and `security-scan.yml` are standalone workflows (not thin callers). `sync-tags.yml` remains a thin caller and auto-updates.

To push workflow updates to existing no-app forks:

```bash
./fork-action.sh some-vendor/deploy-action --existing --force-update --org my-org --no-app
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

# Add sync infra to an existing fork (no-app)
./fork-action.sh some-vendor/deploy-action --existing --org my-org --no-app

# Update sync infra (overwrite workflows, manifest)
./fork-action.sh some-vendor/deploy-action --existing --force-update --org my-org --no-app

# Verify fork setup
./verify-repo.sh my-org/deploy-action
```
