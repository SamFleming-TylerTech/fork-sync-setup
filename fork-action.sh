#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# fork-action.sh
#
# Automated script for forking third-party GitHub Actions into the
# tyler-technologies-oss organization with sync infrastructure.
#
# Deploys sync workflows, security scanning, and tag monitoring.
#
# Usage:
#   ./fork-action.sh <upstream_owner/repo> [--tag <tag>] [--existing]
#
# Examples:
#   ./fork-action.sh peter-evans/create-pull-request --tag v7.0.8
#   ./fork-action.sh irongut/CodeCoverageSummary --existing --tag v1.3.0
#   ./fork-action.sh owner/repo --existing --force-update --org SamFleming-TylerTech
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORK_ORG="${FORK_ORG:-tyler-technologies-oss}"
TEMPLATES_REPO="${TEMPLATES_REPO:-SamFleming-TylerTech/fork-sync-shared-workflow}"
TEMPLATES_REF="${TEMPLATES_REF:-v1}"
FORK_IS_PERSONAL=false
TEMP_DIR=""

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

info()    { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET}    $*"; }
success() { echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $*"; }
warn()    { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET}    $*"; }
error()   { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET}   $*" >&2; }

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------
cleanup() {
    if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
        info "Cleaning up temp directory: ${TEMP_DIR}"
        rm -rf "${TEMP_DIR}"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------
print_usage() {
    cat <<'USAGE'
fork-action.sh - Fork third-party GitHub Actions with sync infrastructure

USAGE:
    ./fork-action.sh <upstream_owner/repo> [OPTIONS]

ARGUMENTS:
    upstream_owner/repo    The upstream GitHub Action to fork (e.g. peter-evans/create-pull-request)

OPTIONS:
    --org <org>            Target GitHub org or user (default: tyler-technologies-oss, or FORK_ORG env var)
    --tag <tag>            Pin a specific upstream tag in the fork (e.g. v7.0.8)
    --existing             Operate on an already-forked repo in the target org/user
    --force-update         Force overwrite existing sync infrastructure (use with --existing)
    --templates-repo <r>   Central templates repo (default: SamFleming-TylerTech/fork-sync-shared-workflow, or TEMPLATES_REPO env var)
    --templates-ref <ref>  Central templates ref/tag (default: v1, or TEMPLATES_REF env var)
    --help                 Show this help message and exit

EXAMPLES:
    # Fork a new action and pin a tag:
    ./fork-action.sh peter-evans/create-pull-request --tag v7.0.8

    # Add sync infrastructure to an existing fork:
    ./fork-action.sh irongut/CodeCoverageSummary --existing --tag v1.3.0

    # Fork to a personal account or different org:
    ./fork-action.sh owner/repo --org my-github-username

    # Fork without pinning a tag (sync infrastructure only):
    ./fork-action.sh actions/checkout

    # Force update sync infrastructure on an existing fork:
    ./fork-action.sh owner/repo --existing --force-update

    # Use a different templates repo and version:
    ./fork-action.sh owner/repo --templates-repo my-org/my-templates --templates-ref v2

WHAT THIS SCRIPT DOES:
    1. Forks (or validates an existing fork of) the upstream repo into the target org.
    2. Clones the fork to a temporary directory and adds the upstream remote.
    3. Creates an 'upstream-tracking' branch from the default branch.
    4. Copies workflow files (sync-upstream, sync-tags, security-scan).
    5. Generates a FORK_MANIFEST.json with upstream tracking metadata.
    6. Copies a CODEOWNERS file for review enforcement.
    7. Commits and pushes the sync infrastructure to the default branch.
    8. Enables GitHub Actions on the fork.
    9. Creates required labels for sync workflows (upstream-sync, security-alert, etc.).
   10. Configures branch protection (1 required reviewer, security-scan status check).
   11. If --tag is specified, creates an annotated tag in the fork referencing the upstream SHA.

PREREQUISITES:
    - gh CLI installed and authenticated (https://cli.github.com)
    - Write access to the target GitHub organization
    - Workflow template files present in the script directory:
        .github/workflows/caller-sync-upstream.yml
        .github/workflows/caller-sync-tags.yml
        .github/workflows/caller-security-scan.yml
        templates/FORK_MANIFEST.json
        templates/CODEOWNERS
USAGE
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
UPSTREAM_SLUG=""
TAG=""
EXISTING=false
FORCE_UPDATE=false

parse_args() {
    if [[ $# -eq 0 ]]; then
        print_usage
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                print_usage
                exit 0
                ;;
            --org)
                if [[ $# -lt 2 ]]; then
                    error "--org requires a value (e.g. --org tyler-technologies-oss)"
                    exit 1
                fi
                FORK_ORG="$2"
                shift 2
                ;;
            --tag)
                if [[ $# -lt 2 ]]; then
                    error "--tag requires a value (e.g. --tag v1.3.0)"
                    exit 1
                fi
                TAG="$2"
                shift 2
                ;;
            --existing)
                EXISTING=true
                shift
                ;;
            --force-update)
                FORCE_UPDATE=true
                shift
                ;;
            --templates-repo)
                if [[ $# -lt 2 ]]; then
                    error "--templates-repo requires a value (e.g. --templates-repo my-org/my-templates)"
                    exit 1
                fi
                TEMPLATES_REPO="$2"
                shift 2
                ;;
            --templates-ref)
                if [[ $# -lt 2 ]]; then
                    error "--templates-ref requires a value (e.g. --templates-ref v2)"
                    exit 1
                fi
                TEMPLATES_REF="$2"
                shift 2
                ;;
            -*)
                error "Unknown option: $1"
                print_usage
                exit 1
                ;;
            *)
                if [[ -n "${UPSTREAM_SLUG}" ]]; then
                    error "Unexpected positional argument: $1"
                    print_usage
                    exit 1
                fi
                UPSTREAM_SLUG="$1"
                shift
                ;;
        esac
    done

    if [[ -z "${UPSTREAM_SLUG}" ]]; then
        error "Missing required argument: upstream_owner/repo"
        print_usage
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------
validate_slug() {
    if [[ ! "${UPSTREAM_SLUG}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
        error "Invalid repo slug '${UPSTREAM_SLUG}'. Expected format: owner/repo"
        exit 1
    fi
}

check_prerequisites() {
    info "Checking prerequisites..."

    # gh CLI installed
    if ! command -v gh &>/dev/null; then
        error "gh CLI is not installed. Install it from https://cli.github.com"
        exit 1
    fi

    # gh authenticated
    if ! gh auth status &>/dev/null; then
        error "gh CLI is not authenticated. Run 'gh auth login' first."
        exit 1
    fi
    success "gh CLI is installed and authenticated."

    # Access to org or personal account
    if gh api "orgs/${FORK_ORG}" --silent 2>/dev/null; then
        success "Access to ${FORK_ORG} organization confirmed."
    elif gh api "users/${FORK_ORG}" --silent 2>/dev/null; then
        FORK_IS_PERSONAL=true
        local current_user
        current_user="$(gh api user --jq '.login' 2>/dev/null)"
        if [[ "${current_user}" != "${FORK_ORG}" ]]; then
            error "Target '${FORK_ORG}' is a personal account but you are authenticated as '${current_user}'."
            error "You can only fork to your own account or an org you belong to."
            error "Switch accounts with: gh auth switch --user ${FORK_ORG}"
            exit 1
        fi
        success "Target is personal account: ${FORK_ORG}"
    else
        error "Cannot access '${FORK_ORG}' as an organization or user."
        exit 1
    fi

    # Upstream repo exists
    if ! gh repo view "${UPSTREAM_SLUG}" --json name --jq '.name' &>/dev/null; then
        error "Upstream repository '${UPSTREAM_SLUG}' does not exist or is not accessible."
        exit 1
    fi
    success "Upstream repository '${UPSTREAM_SLUG}' exists."
}

check_template_files() {
    local missing=false
    local required_files=(
        ".github/workflows/caller-sync-upstream.yml"
        ".github/workflows/caller-sync-tags.yml"
        ".github/workflows/caller-security-scan.yml"
        "templates/FORK_MANIFEST.json"
        "templates/CODEOWNERS"
    )

    for f in "${required_files[@]}"; do
        if [[ ! -f "${SCRIPT_DIR}/${f}" ]]; then
            error "Required template file missing: ${SCRIPT_DIR}/${f}"
            missing=true
        fi
    done

    if [[ "${missing}" == "true" ]]; then
        error "One or more template files are missing. See --help for the list of required files."
        exit 1
    fi
    success "All template files present."
}

# ---------------------------------------------------------------------------
# Core operations
# ---------------------------------------------------------------------------
UPSTREAM_OWNER=""
UPSTREAM_REPO=""
DEFAULT_BRANCH=""
CLONE_DIR=""

split_slug() {
    UPSTREAM_OWNER="${UPSTREAM_SLUG%%/*}"
    UPSTREAM_REPO="${UPSTREAM_SLUG##*/}"
}

fork_or_validate() {
    if [[ "${EXISTING}" == "true" ]]; then
        info "Validating existing fork: ${FORK_ORG}/${UPSTREAM_REPO}"
        if ! gh repo view "${FORK_ORG}/${UPSTREAM_REPO}" --json name --jq '.name' &>/dev/null; then
            error "Fork '${FORK_ORG}/${UPSTREAM_REPO}' does not exist. Remove --existing to create it."
            exit 1
        fi
        success "Existing fork '${FORK_ORG}/${UPSTREAM_REPO}' verified."
    else
        info "Forking ${UPSTREAM_SLUG} into ${FORK_ORG}..."
        if gh repo view "${FORK_ORG}/${UPSTREAM_REPO}" --json name --jq '.name' &>/dev/null; then
            warn "Fork '${FORK_ORG}/${UPSTREAM_REPO}' already exists. Proceeding as if --existing."
            EXISTING=true
        else
            if [[ "${FORK_IS_PERSONAL}" == "true" ]]; then
                gh repo fork "${UPSTREAM_SLUG}" --clone=false
            else
                gh repo fork "${UPSTREAM_SLUG}" --org "${FORK_ORG}" --clone=false
            fi
            success "Fork created: ${FORK_ORG}/${UPSTREAM_REPO}"

            # Give GitHub a moment to finalize the fork
            info "Waiting for fork to become available..."
            local retries=0
            while ! gh repo view "${FORK_ORG}/${UPSTREAM_REPO}" --json name &>/dev/null; do
                retries=$((retries + 1))
                if [[ ${retries} -ge 30 ]]; then
                    error "Timed out waiting for fork to become available."
                    exit 1
                fi
                sleep 2
            done
            success "Fork is available."
        fi
    fi
}

clone_fork() {
    TEMP_DIR="$(mktemp -d)"
    CLONE_DIR="${TEMP_DIR}/${UPSTREAM_REPO}"
    info "Cloning fork to ${CLONE_DIR}..."

    gh repo clone "${FORK_ORG}/${UPSTREAM_REPO}" "${CLONE_DIR}" -- --quiet
    success "Fork cloned."

    info "Adding upstream remote..."
    git -C "${CLONE_DIR}" remote add upstream "https://github.com/${UPSTREAM_SLUG}.git" 2>/dev/null || {
        # Remote may already exist (e.g. gh fork auto-adds it)
        git -C "${CLONE_DIR}" remote set-url upstream "https://github.com/${UPSTREAM_SLUG}.git"
    }
    git -C "${CLONE_DIR}" fetch upstream --quiet
    success "Upstream remote configured: ${UPSTREAM_SLUG}"
}

detect_default_branch() {
    info "Detecting default branch..."
    DEFAULT_BRANCH="$(gh repo view "${FORK_ORG}/${UPSTREAM_REPO}" --json defaultBranchRef --jq '.defaultBranchRef.name')"
    if [[ -z "${DEFAULT_BRANCH}" ]]; then
        error "Could not detect default branch for ${FORK_ORG}/${UPSTREAM_REPO}."
        exit 1
    fi
    success "Default branch: ${DEFAULT_BRANCH}"
}

create_upstream_tracking_branch() {
    info "Creating upstream-tracking branch..."

    # Check if branch already exists on remote
    if git -C "${CLONE_DIR}" ls-remote --heads origin upstream-tracking | grep -q upstream-tracking; then
        warn "Branch 'upstream-tracking' already exists on remote. Skipping creation."
        return 0
    fi

    # Create from the default branch
    git -C "${CLONE_DIR}" checkout -b upstream-tracking "origin/${DEFAULT_BRANCH}" --quiet
    git -C "${CLONE_DIR}" push -u origin upstream-tracking --quiet
    success "Branch 'upstream-tracking' created and pushed."

    # Switch back to default branch
    git -C "${CLONE_DIR}" checkout "${DEFAULT_BRANCH}" --quiet
}

copy_and_substitute_workflows() {
    info "Copying caller workflow files..."

    local workflow_dir="${CLONE_DIR}/.github/workflows"
    mkdir -p "${workflow_dir}"

    # Map caller templates to their deployed names
    local -A caller_map=(
        ["caller-sync-upstream.yml"]="sync-upstream.yml"
        ["caller-sync-tags.yml"]="sync-tags.yml"
        ["caller-security-scan.yml"]="security-scan.yml"
    )

    for src_name in "${!caller_map[@]}"; do
        local dst_name="${caller_map[${src_name}]}"
        local src="${SCRIPT_DIR}/.github/workflows/${src_name}"
        local dst="${workflow_dir}/${dst_name}"

        cp "${src}" "${dst}"

        # Substitute placeholders
        sed -i "s|__UPSTREAM_OWNER__|${UPSTREAM_OWNER}|g" "${dst}"
        sed -i "s|__UPSTREAM_REPO__|${UPSTREAM_REPO}|g" "${dst}"
        sed -i "s|__DEFAULT_BRANCH__|${DEFAULT_BRANCH}|g" "${dst}"
        sed -i "s|__TEMPLATES_REPO__|${TEMPLATES_REPO}|g" "${dst}"
        sed -i "s|__TEMPLATES_REF__|${TEMPLATES_REF}|g" "${dst}"

        success "  Copied and configured: .github/workflows/${dst_name}"
    done
}

generate_fork_manifest() {
    info "Generating FORK_MANIFEST.json..."

    local src="${SCRIPT_DIR}/templates/FORK_MANIFEST.json"
    local dst="${CLONE_DIR}/FORK_MANIFEST.json"

    # Get current upstream HEAD SHA
    local upstream_sha
    upstream_sha="$(git ls-remote "https://github.com/${UPSTREAM_SLUG}.git" "refs/heads/${DEFAULT_BRANCH}" | awk '{print $1}')"
    if [[ -z "${upstream_sha}" ]]; then
        error "Could not resolve upstream HEAD SHA for ${UPSTREAM_SLUG} branch ${DEFAULT_BRANCH}."
        exit 1
    fi

    local sync_date
    sync_date="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    cp "${src}" "${dst}"

    sed -i "s|__UPSTREAM_OWNER__|${UPSTREAM_OWNER}|g" "${dst}"
    sed -i "s|__UPSTREAM_REPO__|${UPSTREAM_REPO}|g" "${dst}"
    sed -i "s|__DEFAULT_BRANCH__|${DEFAULT_BRANCH}|g" "${dst}"
    sed -i "s|__UPSTREAM_SHA__|${upstream_sha}|g" "${dst}"
    sed -i "s|__SYNC_DATE__|${sync_date}|g" "${dst}"
    sed -i "s|__FORK_ORG__|${FORK_ORG}|g" "${dst}"
    sed -i "s|__TEMPLATES_REPO__|${TEMPLATES_REPO}|g" "${dst}"
    sed -i "s|__TEMPLATES_REF__|${TEMPLATES_REF}|g" "${dst}"

    success "FORK_MANIFEST.json generated (upstream SHA: ${upstream_sha:0:12})."
}

copy_codeowners() {
    info "Copying CODEOWNERS..."

    local src="${SCRIPT_DIR}/templates/CODEOWNERS"
    local dst="${CLONE_DIR}/CODEOWNERS"

    cp "${src}" "${dst}"
    success "CODEOWNERS copied."
}

sync_infra_exists() {
    # Check if sync infrastructure is already deployed in the fork
    [[ -f "${CLONE_DIR}/FORK_MANIFEST.json" ]] && \
    [[ -f "${CLONE_DIR}/CODEOWNERS" ]] && \
    [[ -f "${CLONE_DIR}/.github/workflows/sync-upstream.yml" ]] && \
    [[ -f "${CLONE_DIR}/.github/workflows/sync-tags.yml" ]]
}

commit_and_push() {
    info "Committing sync infrastructure..."

    # In --existing mode, skip if sync infra is already deployed (unless --force-update)
    if [[ "${EXISTING}" == "true" ]] && sync_infra_exists && [[ "${FORCE_UPDATE}" != "true" ]]; then
        warn "Sync infrastructure already present in fork. Skipping file update."
        warn "Use --force-update to overwrite existing sync infrastructure."
        return 0
    fi

    git -C "${CLONE_DIR}" add \
        .github/workflows/sync-upstream.yml \
        .github/workflows/sync-tags.yml \
        .github/workflows/security-scan.yml \
        FORK_MANIFEST.json \
        CODEOWNERS

    # Check if there are changes to commit
    if git -C "${CLONE_DIR}" diff --cached --quiet; then
        warn "No changes to commit (sync infrastructure may already be present)."
        return 0
    fi

    git -C "${CLONE_DIR}" commit -m "chore: add fork sync infrastructure" --quiet
    git -C "${CLONE_DIR}" push origin "${DEFAULT_BRANCH}" --quiet
    success "Sync infrastructure committed and pushed to ${DEFAULT_BRANCH}."
}

enable_github_actions() {
    info "Enabling GitHub Actions on the fork..."

    gh api -X PUT "repos/${FORK_ORG}/${UPSTREAM_REPO}/actions/permissions" \
        -f enabled=true \
        -f allowed_actions=all \
        --silent 2>/dev/null || true

    success "GitHub Actions enabled."

    # GitHub disables issues on forks by default; sync-tags needs them for alerts
    info "Enabling issues on the fork..."
    gh api "repos/${FORK_ORG}/${UPSTREAM_REPO}" \
        --method PATCH \
        -f has_issues=true \
        --silent 2>/dev/null || true

    success "Issues enabled."

    # Enable vulnerability alerts (activates Dependency Graph for dependency-review-action)
    info "Enabling vulnerability alerts and dependency graph..."
    gh api "repos/${FORK_ORG}/${UPSTREAM_REPO}/vulnerability-alerts" \
        --method PUT \
        --silent 2>/dev/null || true

    success "Vulnerability alerts enabled."
}

create_labels() {
    info "Creating required labels..."

    local repo="${FORK_ORG}/${UPSTREAM_REPO}"
    local -A labels=(
        ["upstream-sync"]="0E8A16|PR syncing upstream changes"
        ["needs-security-review"]="D93F0B|Requires security review before merge"
        ["upstream-release"]="1D76DB|New upstream release detected"
        ["security-alert"]="B60205|Security alert - tag mutation detected"
        ["upstream-tag-deleted"]="FBCA04|Upstream tag was deleted"
    )

    for name in "${!labels[@]}"; do
        local color="${labels[${name}]%%|*}"
        local description="${labels[${name}]#*|}"
        if gh label create "${name}" --repo "${repo}" --color "${color}" --description "${description}" 2>/dev/null; then
            success "  Label created: ${name}"
        else
            warn "  Label '${name}' already exists. Skipping."
        fi
    done
}

configure_branch_protection() {
    info "Configuring branch protection for '${DEFAULT_BRANCH}'..."

    gh api "repos/${FORK_ORG}/${UPSTREAM_REPO}/branches/${DEFAULT_BRANCH}/protection" \
        --method PUT \
        --silent \
        --input - <<EOF
{
    "required_status_checks": {
        "strict": true,
        "contexts": [
            "security-scan"
        ]
    },
    "enforce_admins": true,
    "required_pull_request_reviews": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews": true
    },
    "restrictions": null
}
EOF

    success "Branch protection configured (1 reviewer, security-scan required, enforced for admins)."
}

create_tag() {
    if [[ -z "${TAG}" ]]; then
        return 0
    fi

    info "Processing tag: ${TAG}"

    # Verify tag exists upstream
    local tag_sha
    tag_sha="$(git ls-remote --tags "https://github.com/${UPSTREAM_SLUG}.git" "refs/tags/${TAG}" | awk '{print $1}')"

    if [[ -z "${tag_sha}" ]]; then
        # Try the dereferenced tag (annotated tags show ^{} entries)
        tag_sha="$(git ls-remote --tags "https://github.com/${UPSTREAM_SLUG}.git" "refs/tags/${TAG}^{}" | awk '{print $1}')"
    fi

    if [[ -z "${tag_sha}" ]]; then
        error "Tag '${TAG}' does not exist in upstream '${UPSTREAM_SLUG}'."
        error "Available tags (most recent 10):"
        git ls-remote --tags "https://github.com/${UPSTREAM_SLUG}.git" | tail -10 | awk '{print "  " $2}' | sed 's|refs/tags/||' >&2
        exit 1
    fi

    success "Upstream tag '${TAG}' found at SHA: ${tag_sha:0:12}"

    # Fetch the upstream tag objects so the SHA is available locally
    git -C "${CLONE_DIR}" fetch upstream "refs/tags/${TAG}:refs/tags/upstream-${TAG}" --quiet 2>/dev/null || true

    # Check if tag already exists in the fork's remote
    if git -C "${CLONE_DIR}" ls-remote --tags origin "refs/tags/${TAG}" | grep -q "refs/tags/${TAG}$"; then
        warn "Tag '${TAG}' already exists in the fork. Skipping tag creation."
        return 0
    fi

    local fork_date
    fork_date="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    # Force-create annotated tag (replaces any lightweight tag inherited from upstream fetch)
    if git -C "${CLONE_DIR}" tag -l "${TAG}" | grep -q "^${TAG}$"; then
        info "Replacing local tag '${TAG}' (inherited from upstream) with annotated tag..."
    fi

    # Create annotated tag at the upstream SHA (-f replaces any existing local tag)
    git -C "${CLONE_DIR}" tag -f -a "${TAG}" "${tag_sha}" \
        -m "Forked tag ${TAG} from ${UPSTREAM_SLUG}

Upstream SHA: ${tag_sha}
Fork date: ${fork_date}
Source: https://github.com/${UPSTREAM_SLUG}/releases/tag/${TAG}

Requires security review before use in CI/CD pipelines."

    git -C "${CLONE_DIR}" push origin "refs/tags/${TAG}" --quiet
    success "Tag '${TAG}' created and pushed to fork."
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
    echo ""
    echo -e "${COLOR_BOLD}============================================================${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  Fork Setup Complete${COLOR_RESET}"
    echo -e "${COLOR_BOLD}============================================================${COLOR_RESET}"
    echo ""
    echo -e "  ${COLOR_CYAN}Fork URL:${COLOR_RESET}         https://github.com/${FORK_ORG}/${UPSTREAM_REPO}"
    echo -e "  ${COLOR_CYAN}Upstream:${COLOR_RESET}         https://github.com/${UPSTREAM_SLUG}"
    echo -e "  ${COLOR_CYAN}Default branch:${COLOR_RESET}   ${DEFAULT_BRANCH}"
    echo -e "  ${COLOR_CYAN}Tracking branch:${COLOR_RESET}  upstream-tracking"
    echo -e "  ${COLOR_CYAN}Templates repo:${COLOR_RESET}   ${TEMPLATES_REPO}@${TEMPLATES_REF}"

    if [[ -n "${TAG}" ]]; then
        echo -e "  ${COLOR_CYAN}Pinned tag:${COLOR_RESET}       ${TAG}"
    fi

    echo ""
    echo -e "  ${COLOR_BOLD}Sync infrastructure added:${COLOR_RESET}"
    echo "    - .github/workflows/sync-upstream.yml  (standalone, uses GITHUB_TOKEN)"
    echo "    - .github/workflows/sync-tags.yml      (caller -> ${TEMPLATES_REPO}@${TEMPLATES_REF})"
    echo "    - .github/workflows/security-scan.yml  (workflow_run trigger, uses GITHUB_TOKEN)"
    echo "    - FORK_MANIFEST.json"
    echo "    - CODEOWNERS"
    echo "    - Labels: upstream-sync, needs-security-review, upstream-release, security-alert, upstream-tag-deleted"
    echo ""
    echo -e "  ${COLOR_BOLD}Next steps:${COLOR_RESET}"
    echo "    1. Review the fork: https://github.com/${FORK_ORG}/${UPSTREAM_REPO}"
    echo "    2. Verify GitHub Actions are running: https://github.com/${FORK_ORG}/${UPSTREAM_REPO}/actions"
    echo "    3. No secrets required (uses GITHUB_TOKEN)."

    if [[ -n "${TAG}" ]]; then
        echo "    4. Reference the pinned tag in workflows:"
        echo "         uses: ${FORK_ORG}/${UPSTREAM_REPO}@${TAG}"
    else
        echo "    4. Pin a specific tag for CI/CD usage:"
        echo "         ./fork-action.sh ${UPSTREAM_SLUG} --existing --tag <tag>"
    fi

    echo ""
    echo -e "${COLOR_BOLD}============================================================${COLOR_RESET}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    validate_slug
    split_slug
    check_prerequisites
    check_template_files

    fork_or_validate
    clone_fork
    detect_default_branch
    create_upstream_tracking_branch
    copy_and_substitute_workflows
    generate_fork_manifest
    copy_codeowners
    commit_and_push
    enable_github_actions
    create_labels
    configure_branch_protection
    create_tag

    print_summary
}

main "$@"
