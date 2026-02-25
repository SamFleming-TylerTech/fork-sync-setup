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
- A GitHub App installed on the target org/user (see [Setting Up a GitHub App](#setting-up-a-github-app) below)

---

## Setting Up a GitHub App (Requires corp-dev assistance)

Once this is part of our org we will loose the ability to configure this.

The sync-upstream workflow uses a GitHub App token to create PRs. This is what allows the security scan to auto-trigger on new PRs (a regular `GITHUB_TOKEN` can't trigger other workflows). Corp-Dev will need to assist with this section, 5. Add Secrets to Your Fork will need to be set up as a recurring task for each new fork. The secret could also be a global variable that could be assigned.

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

```bash
./fork-action.sh some-vendor/deploy-action --tag v2.0.0 --org my-org
```

This:
- Creates `my-org/deploy-action` as a GitHub fork
- Adds an `upstream-tracking` branch
- Copies caller workflows (`sync-upstream.yml`, `sync-tags.yml`, `security-scan.yml`)
- Generates `FORK_MANIFEST.json` with upstream provenance
- Adds `CODEOWNERS` for review enforcement
- Enables branch protection (1 reviewer + security-scan check required)
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
  Templates repo:   SamFleming-TylerTech/fork-action-sync-templates@v1
  Pinned tag:       v2.0.0

  Next steps:
    1. Review the fork
    2. Verify GitHub Actions are running
    3. Add FORK_SYNC_APP_ID and FORK_SYNC_APP_PRIVATE_KEY secrets
    4. Reference the pinned tag in workflows:
         uses: my-org/deploy-action@v2.0.0
============================================================
```

### Create Required Labels

The sync workflows create issues and PRs with specific labels. Create them once per repo:

```bash
REPO="my-org/deploy-action"

gh label create "upstream-sync"           --repo "$REPO" --color "0E8A16" --description "PR syncing upstream changes"
gh label create "needs-security-review"   --repo "$REPO" --color "D93F0B" --description "Requires security review before merge"
gh label create "upstream-release"        --repo "$REPO" --color "1D76DB" --description "New upstream release detected"
gh label create "security-alert"          --repo "$REPO" --color "B60205" --description "Security alert - tag mutation detected"
gh label create "upstream-tag-deleted"    --repo "$REPO" --color "FBCA04" --description "Upstream tag was deleted"
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
3. Security scan auto-triggers on the PR

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
- [ ] Run CodeQL or static analysis
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

Runs three checks in parallel:

| Check | What it does |
|-------|-------------|
| `dependency-review` | Scans for new vulnerabilities in dependency changes |
| `codeql` | Static analysis with security-extended queries |
| `diff-summary` | Posts a comment with changed file stats, flags action manifests, scripts, binaries |

---

## Example: End-to-End

This example uses `uprightbass360/demo-action` as the upstream and `SamFleming-TylerTech` as the fork target.

### Create the fork

```bash
./fork-action.sh uprightbass360/demo-action --tag v1.0.1 --org SamFleming-TylerTech
```

### Add secrets and labels

```bash
REPO="SamFleming-TylerTech/demo-action"

gh secret set FORK_SYNC_APP_ID --repo "$REPO"
gh secret set FORK_SYNC_APP_PRIVATE_KEY --repo "$REPO" < private-key.pem

gh label create "upstream-sync"         --repo "$REPO" --color "0E8A16"
gh label create "needs-security-review" --repo "$REPO" --color "D93F0B"
gh label create "upstream-release"      --repo "$REPO" --color "1D76DB"
gh label create "security-alert"        --repo "$REPO" --color "B60205"
gh label create "upstream-tag-deleted"  --repo "$REPO" --color "FBCA04"
```

### Simulate upstream changes

In the upstream repo, a maintainer:
1. Pushes a new commit (adds a feature)
2. Force-pushes `v1.0.0` to a different commit (tag mutation)
3. Creates `v1.1.0` (new release)
4. Deletes `v1.0.1` (tag removal)

### Trigger the sync

```bash
gh workflow run sync-upstream.yml --repo SamFleming-TylerTech/demo-action
gh workflow run sync-tags.yml    --repo SamFleming-TylerTech/demo-action
```

### Results

| Artifact | What it shows |
|----------|--------------|
| PR #2 | Upstream sync with diff stats, security-relevant files, review checklist |
| PR checks | dependency-review, codeql, diff-summary -- all auto-triggered |
| Issue: tag mutation | `v1.0.0` changed from `6939ca1` to `90f9792` with comparison link |
| Issue: new release | `v1.1.0` detected with security review checklist |
| Issue: tag deleted | `v1.0.1` removed from upstream, fork copy preserved |

---

## How It Scales

The caller workflows in each fork are thin -- they just reference reusable workflows:

```yaml
# In the fork: .github/workflows/sync-upstream.yml
jobs:
  sync:
    uses: SamFleming-TylerTech/fork-action-sync-templates/.github/workflows/sync-upstream.yml@v1
    with:
      upstream_owner: some-vendor
      upstream_repo: deploy-action
    secrets: inherit
```

All the logic lives in `fork-action-sync-templates`. When you fix a bug or add a feature there:
- Tag it as `v1` (floating tag)
- Every fork picks up the change on the next run
- Zero per-fork maintenance

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
```
