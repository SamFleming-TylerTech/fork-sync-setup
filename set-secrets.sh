#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# set-secrets.sh
#
# Sets FORK_SYNC_APP_ID and FORK_SYNC_APP_PRIVATE_KEY secrets on a fork repo.
#
# Usage:
#   ./set-secrets.sh <org/repo> --app-id <id> --app-key <path-to-pem>
#
# Examples:
#   ./set-secrets.sh SamFleming-TylerTech/demo-action --app-id 2933758 --app-key ~/private-key.pem
###############################################################################

if [[ $# -lt 5 ]] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    echo "Usage: ./set-secrets.sh <org/repo> --app-id <id> --app-key <path-to-pem>"
    exit 1
fi

REPO="$1"; shift
APP_ID=""
APP_KEY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-id)  APP_ID="$2";  shift 2 ;;
        --app-key) APP_KEY="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "${APP_ID}" ]]; then
    echo "Error: --app-id is required" >&2; exit 1
fi

if [[ -z "${APP_KEY}" ]]; then
    echo "Error: --app-key is required" >&2; exit 1
fi

if [[ ! -f "${APP_KEY}" ]]; then
    echo "Error: PEM file not found: ${APP_KEY}" >&2; exit 1
fi

echo "Setting secrets on ${REPO}..."
gh secret set FORK_SYNC_APP_ID --repo "${REPO}" --body "${APP_ID}"
echo "  ✓ FORK_SYNC_APP_ID"

gh secret set FORK_SYNC_APP_PRIVATE_KEY --repo "${REPO}" < "${APP_KEY}"
echo "  ✓ FORK_SYNC_APP_PRIVATE_KEY"

echo "Done."
