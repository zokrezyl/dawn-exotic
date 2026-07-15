#!/usr/bin/env bash
# Create and push a git tag matching the version in <repo_root>/dawn-version.
# The tag is "v${VERSION}" (e.g., v20260410.140140).
#
# Usage:
#   push-tag.sh [-f|--force]
#
# Options:
#   -f, --force   Force-recreate the tag. If the tag already exists locally
#                 or on the remote, delete it in both places first, then
#                 create and push it fresh. Deleting the remote tag before
#                 re-pushing makes GitHub emit a new tag-creation event, so
#                 the release build is triggered correctly.
#
# Env overrides:
#   REMOTE   Git remote to push to (default: origin)

set -euo pipefail

FORCE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--force)
            FORCE=1
            ;;
        -h|--help)
            grep '^#[^!]' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument '$1'" >&2
            echo "Usage: $(basename "${BASH_SOURCE[0]}") [-f|--force]" >&2
            exit 1
            ;;
    esac
    shift
done

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

LOCAL_EXISTS=0
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    LOCAL_EXISTS=1
fi

REMOTE_EXISTS=0
if git ls-remote --tags --exit-code "${REMOTE}" "refs/tags/${TAG}" >/dev/null 2>&1; then
    REMOTE_EXISTS=1
fi

if [[ "${FORCE}" -eq 0 ]]; then
    if [[ "${LOCAL_EXISTS}" -eq 1 ]]; then
        echo "ERROR: tag ${TAG} already exists locally (use -f to force-recreate)" >&2
        exit 1
    fi
    if [[ "${REMOTE_EXISTS}" -eq 1 ]]; then
        echo "ERROR: tag ${TAG} already exists on ${REMOTE} (use -f to force-recreate)" >&2
        exit 1
    fi
else
    if [[ "${REMOTE_EXISTS}" -eq 1 ]]; then
        echo "==> Deleting existing tag ${TAG} on ${REMOTE}"
        git push "${REMOTE}" ":refs/tags/${TAG}"
    fi
    if [[ "${LOCAL_EXISTS}" -eq 1 ]]; then
        echo "==> Deleting existing local tag ${TAG}"
        git tag -d "${TAG}"
    fi
fi

echo "==> Creating annotated tag ${TAG} at $(git rev-parse --short HEAD)"
git tag -a "${TAG}" -m "dawn ${VERSION}"

echo "==> Pushing ${TAG} to ${REMOTE}"
git push "${REMOTE}" "${TAG}"

echo "==> Done. Tag ${TAG} pushed to ${REMOTE}."
