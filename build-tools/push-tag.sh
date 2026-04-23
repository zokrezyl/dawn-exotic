#!/usr/bin/env bash
# Create and push a git tag matching the version in <repo_root>/dawn-version.
# The tag is "v${VERSION}" (e.g., v20260410.140140).
#
# Env overrides:
#   REMOTE   Git remote to push to (default: origin)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REMOTE="${REMOTE:-origin}"

VERSION_FILE="${REPO_ROOT}/dawn-version"
if [[ ! -f "${VERSION_FILE}" ]]; then
    echo "ERROR: ${VERSION_FILE} not found" >&2
    exit 1
fi

VERSION="$(tr -d '[:space:]' < "${VERSION_FILE}")"
if [[ -z "${VERSION}" ]]; then
    echo "ERROR: ${VERSION_FILE} is empty" >&2
    exit 1
fi
TAG="v${VERSION}"

cd "${REPO_ROOT}"

if ! git remote get-url "${REMOTE}" >/dev/null 2>&1; then
    echo "ERROR: git remote '${REMOTE}' not configured" >&2
    exit 1
fi

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    echo "ERROR: tag ${TAG} already exists locally" >&2
    exit 1
fi

if git ls-remote --tags --exit-code "${REMOTE}" "refs/tags/${TAG}" >/dev/null 2>&1; then
    echo "ERROR: tag ${TAG} already exists on ${REMOTE}" >&2
    exit 1
fi

echo "==> Creating annotated tag ${TAG} at $(git rev-parse --short HEAD)"
git tag -a "${TAG}" -m "dawn ${VERSION}"

echo "==> Pushing ${TAG} to ${REMOTE}"
git push "${REMOTE}" "${TAG}"

echo "==> Done. Tag ${TAG} pushed to ${REMOTE}."
