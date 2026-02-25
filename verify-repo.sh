#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# verify-repo.sh
#
# Validates that a forked GitHub Action repo has all required sync
# infrastructure, secrets, labels, and configuration in place.
#
# Usage:
#   ./verify-repo.sh <org/repo>
#
# Examples:
#   ./verify-repo.sh SamFleming-TylerTech/demo-action
#   ./verify-repo.sh tyler-technologies-oss/create-pull-request
###############################################################################

# ---------------------------------------------------------------------------
# Color output helpers (disabled when stdout is not a terminal)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    COLOR_RED='\033[0;31m'
    COLOR_GREEN='\033[0;32m'
    COLOR_YELLOW='\033[0;33m'
    COLOR_BLUE='\033[0;34m'
    COLOR_CYAN='\033[0;36m'
    COLOR_BOLD='\033[1m'
    COLOR_RESET='\033[0m'
else
    COLOR_RED=''
    COLOR_GREEN=''
    COLOR_YELLOW=''
    COLOR_BLUE=''
    COLOR_CYAN=''
    COLOR_BOLD=''
    COLOR_RESET=''
fi

pass()  { echo -e "  ${COLOR_GREEN}✓${COLOR_RESET} $*"; }
fail()  { echo -e "  ${COLOR_RED}✗${COLOR_RESET} $*"; }
warn()  { echo -e "  ${COLOR_YELLOW}⚠${COLOR_RESET} $*"; }
info()  { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET}    $*"; }

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

record_pass() { pass "$@"; PASS_COUNT=$((PASS_COUNT + 1)); }
record_fail() { fail "$@"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
record_warn() { warn "$@"; WARN_COUNT=$((WARN_COUNT + 1)); }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
print_usage() {
    cat <<'USAGE'
verify-repo.sh - Validate fork sync infrastructure

USAGE:
    ./verify-repo.sh <org/repo>

ARGUMENTS:
    org/repo    The forked GitHub Action repo to verify (e.g. my-org/deploy-action)

OPTIONS:
    --help      Show this help message and exit
USAGE
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
REPO=""

if [[ $# -eq 0 ]]; then
    print_usage
    exit 1
fi

case "$1" in
    --help|-h)
        print_usage
        exit 0
        ;;
    *)
        REPO="$1"
        ;;
esac

if [[ ! "${REPO}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    echo "Error: Invalid repo format '${REPO}'. Expected: org/repo" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
if ! command -v gh &>/dev/null; then
    echo "Error: gh CLI is not installed." >&2
    exit 1
fi

if ! gh auth status &>/dev/null; then
    echo "Error: gh CLI is not authenticated." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Check: Repository exists and is a fork
# ---------------------------------------------------------------------------
echo ""
echo -e "${COLOR_BOLD}Verifying: ${REPO}${COLOR_RESET}"
echo -e "${COLOR_BOLD}$(printf '=%.0s' {1..60})${COLOR_RESET}"

echo ""
echo -e "${COLOR_CYAN}Repository${COLOR_RESET}"

REPO_JSON="$(gh api "repos/${REPO}" 2>/dev/null || echo '{}')"

if [[ "${REPO_JSON}" == '{}' ]]; then
    record_fail "Repository ${REPO} does not exist or is not accessible"
    echo ""
    echo -e "${COLOR_RED}Cannot continue -- repository not found.${COLOR_RESET}"
    exit 1
fi

record_pass "Repository exists"

IS_FORK="$(echo "${REPO_JSON}" | jq -r '.fork')"
if [[ "${IS_FORK}" == "true" ]]; then
    PARENT="$(echo "${REPO_JSON}" | jq -r '.parent.full_name')"
    record_pass "Is a fork (upstream: ${PARENT})"
else
    record_warn "Not a GitHub fork (may be a manual copy)"
    PARENT=""
fi

# ---------------------------------------------------------------------------
# Check: Issues enabled
# ---------------------------------------------------------------------------
HAS_ISSUES="$(echo "${REPO_JSON}" | jq -r '.has_issues')"
if [[ "${HAS_ISSUES}" == "true" ]]; then
    record_pass "Issues enabled"
else
    record_fail "Issues disabled (sync-tags creates issues for alerts)"
fi

# ---------------------------------------------------------------------------
# Check: Branches
# ---------------------------------------------------------------------------
echo ""
echo -e "${COLOR_CYAN}Branches${COLOR_RESET}"

DEFAULT_BRANCH="$(echo "${REPO_JSON}" | jq -r '.default_branch_ref // .default_branch')"
BRANCHES="$(gh api "repos/${REPO}/branches" --jq '.[].name' 2>/dev/null || echo '')"

if echo "${BRANCHES}" | grep -qx "upstream-tracking"; then
    record_pass "upstream-tracking branch exists"
else
    record_fail "upstream-tracking branch missing"
fi

# ---------------------------------------------------------------------------
# Check: Workflow files
# ---------------------------------------------------------------------------
echo ""
echo -e "${COLOR_CYAN}Workflows${COLOR_RESET}"

REQUIRED_WORKFLOWS=("sync-upstream.yml" "sync-tags.yml" "security-scan.yml")

for wf in "${REQUIRED_WORKFLOWS[@]}"; do
    if gh api "repos/${REPO}/contents/.github/workflows/${wf}" --silent 2>/dev/null; then
        record_pass "${wf}"
    else
        record_fail "${wf} missing"
    fi
done

# ---------------------------------------------------------------------------
# Check: Sync files
# ---------------------------------------------------------------------------
echo ""
echo -e "${COLOR_CYAN}Sync Files${COLOR_RESET}"

for f in FORK_MANIFEST.json CODEOWNERS; do
    if gh api "repos/${REPO}/contents/${f}" --silent 2>/dev/null; then
        record_pass "${f}"
    else
        record_fail "${f} missing"
    fi
done

# ---------------------------------------------------------------------------
# Check: Labels
# ---------------------------------------------------------------------------
echo ""
echo -e "${COLOR_CYAN}Labels${COLOR_RESET}"

EXISTING_LABELS="$(gh label list --repo "${REPO}" --json name --jq '.[].name' 2>/dev/null || echo '')"

REQUIRED_LABELS=(
    "upstream-sync"
    "needs-security-review"
    "upstream-release"
    "security-alert"
    "upstream-tag-deleted"
)

for label in "${REQUIRED_LABELS[@]}"; do
    if echo "${EXISTING_LABELS}" | grep -qx "${label}"; then
        record_pass "${label}"
    else
        record_fail "${label} missing"
    fi
done

# ---------------------------------------------------------------------------
# Check: Secrets
# ---------------------------------------------------------------------------
echo ""
echo -e "${COLOR_CYAN}Secrets${COLOR_RESET}"

EXISTING_SECRETS="$(gh secret list --repo "${REPO}" --json name --jq '.[].name' 2>/dev/null || echo '')"

for secret in FORK_SYNC_APP_ID FORK_SYNC_APP_PRIVATE_KEY; do
    if echo "${EXISTING_SECRETS}" | grep -qx "${secret}"; then
        record_pass "${secret}"
    else
        record_fail "${secret} missing"
    fi
done

# ---------------------------------------------------------------------------
# Check: Branch protection
# ---------------------------------------------------------------------------
echo ""
echo -e "${COLOR_CYAN}Branch Protection${COLOR_RESET}"

BP_JSON="$(gh api "repos/${REPO}/branches/${DEFAULT_BRANCH}/protection" 2>/dev/null || echo '{}')"

if [[ "${BP_JSON}" == '{}' || "$(echo "${BP_JSON}" | jq -r '.message // empty')" == "Branch not protected" ]]; then
    record_fail "No branch protection on ${DEFAULT_BRANCH}"
else
    record_pass "Branch protection enabled on ${DEFAULT_BRANCH}"

    # Check required reviews
    REVIEW_COUNT="$(echo "${BP_JSON}" | jq -r '.required_pull_request_reviews.required_approving_review_count // 0')"
    if [[ "${REVIEW_COUNT}" -ge 1 ]]; then
        record_pass "Required reviewers: ${REVIEW_COUNT}"
    else
        record_fail "No required reviewers"
    fi

    # Check required status checks
    STATUS_CHECKS="$(echo "${BP_JSON}" | jq -r '.required_status_checks.contexts[]? // empty' 2>/dev/null || echo '')"
    if echo "${STATUS_CHECKS}" | grep -q "security-scan"; then
        record_pass "Required status check: security-scan"
    else
        record_fail "security-scan not in required status checks"
    fi

    # Check enforce admins
    ENFORCE_ADMINS="$(echo "${BP_JSON}" | jq -r '.enforce_admins.enabled // false')"
    if [[ "${ENFORCE_ADMINS}" == "true" ]]; then
        record_pass "Enforce admins: enabled"
    else
        record_warn "Enforce admins: disabled"
    fi
fi

# ---------------------------------------------------------------------------
# Check: Tags
# ---------------------------------------------------------------------------
echo ""
echo -e "${COLOR_CYAN}Tags${COLOR_RESET}"

FORK_TAGS="$(gh api "repos/${REPO}/tags" --jq '.[].name' 2>/dev/null || echo '')"
TAG_COUNT="$(echo "${FORK_TAGS}" | grep -c . 2>/dev/null || echo '0')"

if [[ "${TAG_COUNT}" -gt 0 ]]; then
    record_pass "${TAG_COUNT} tag(s) pinned: $(echo "${FORK_TAGS}" | tr '\n' ' ')"
else
    record_warn "No tags pinned"
fi

# ---------------------------------------------------------------------------
# Check: GitHub Actions enabled
# ---------------------------------------------------------------------------
echo ""
echo -e "${COLOR_CYAN}GitHub Actions${COLOR_RESET}"

ACTIONS_JSON="$(gh api "repos/${REPO}/actions/permissions" 2>/dev/null || echo '{}')"
ACTIONS_ENABLED="$(echo "${ACTIONS_JSON}" | jq -r '.enabled // false')"

if [[ "${ACTIONS_ENABLED}" == "true" ]]; then
    record_pass "GitHub Actions enabled"
else
    record_fail "GitHub Actions disabled"
fi

# ---------------------------------------------------------------------------
# Check: GitHub App installed
# ---------------------------------------------------------------------------
echo ""
echo -e "${COLOR_CYAN}GitHub App${COLOR_RESET}"

# Use the app's JWT to check installation -- fall back to checking if the
# secrets exist and a recent workflow successfully generated an app token.
# The simplest reliable check: look for a successful sync-upstream run,
# which only passes if the app token step succeeds.
# Direct API check requires app credentials, so we infer from workflow history.
APP_TOKEN_RUNS="$(gh run list --repo "${REPO}" --workflow sync-upstream.yml --limit 1 --json conclusion --jq '.[0].conclusion' 2>/dev/null || echo '')"
APP_SECRET_SET=false
if echo "${EXISTING_SECRETS}" | grep -qx "FORK_SYNC_APP_ID" && echo "${EXISTING_SECRETS}" | grep -qx "FORK_SYNC_APP_PRIVATE_KEY"; then
    APP_SECRET_SET=true
fi

if [[ "${APP_TOKEN_RUNS}" == "success" ]]; then
    record_pass "GitHub App working (last sync-upstream succeeded)"
elif [[ "${APP_SECRET_SET}" == "true" ]]; then
    record_warn "GitHub App secrets set but not yet verified (run sync-upstream to confirm)"
else
    record_fail "GitHub App not configured (secrets missing)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${COLOR_BOLD}$(printf '=%.0s' {1..60})${COLOR_RESET}"
TOTAL=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))

echo -ne "  ${COLOR_GREEN}${PASS_COUNT} passed${COLOR_RESET}"
if [[ ${FAIL_COUNT} -gt 0 ]]; then
    echo -ne "  ${COLOR_RED}${FAIL_COUNT} failed${COLOR_RESET}"
fi
if [[ ${WARN_COUNT} -gt 0 ]]; then
    echo -ne "  ${COLOR_YELLOW}${WARN_COUNT} warnings${COLOR_RESET}"
fi
echo "  (${TOTAL} checks)"

if [[ ${FAIL_COUNT} -eq 0 ]]; then
    echo ""
    echo -e "  ${COLOR_GREEN}${COLOR_BOLD}Fork is fully configured.${COLOR_RESET}"
else
    echo ""
    echo -e "  ${COLOR_RED}${COLOR_BOLD}Fork has ${FAIL_COUNT} issue(s) to fix.${COLOR_RESET}"
fi
echo ""

exit "${FAIL_COUNT}"
