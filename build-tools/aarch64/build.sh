#!/usr/bin/env bash
# Build Dawn (webgpu_dawn) for Linux aarch64 in Debug and Release configs.
#
# Follows the official Dawn build flow (docs/building.md):
#   1. Install depot_tools
#   2. Clone Dawn at the tagged release (from GitHub mirror — that's where
#      version tags like v20260410.140140 actually exist)
#   3. Bootstrap with scripts/standalone.gclient
#   4. gclient sync to fetch all deps
#   5. cmake -G Ninja + ninja webgpu_dawn
#
# Output:
#   <repo_root>/build-aarch64-debug/src/dawn/native/libwebgpu_dawn.a
#   <repo_root>/build-aarch64-release/src/dawn/native/libwebgpu_dawn.a
#
# Pinned version comes from <repo_root>/dawn-version.
#
# Env overrides:
#   DAWN_VERSION   Version string (default: contents of dawn-version)
#   DAWN_TAG       Git tag (default: v${DAWN_VERSION})
#   DAWN_GIT_URL   Dawn clone URL (default: https://github.com/google/dawn.git)
#   DAWN_SRC_DIR   Existing Dawn source tree to reuse
#   BUILD_TYPES    Space-separated list (default: "Debug Release")
#   JOBS           Parallel jobs (default: nproc)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

VERSION_FILE="${REPO_ROOT}/dawn-version"
if [[ -z "${DAWN_VERSION:-}" ]]; then
    if [[ ! -f "${VERSION_FILE}" ]]; then
        echo "ERROR: ${VERSION_FILE} not found and DAWN_VERSION not set" >&2
        exit 1
    fi
    DAWN_VERSION="$(tr -d '[:space:]' < "${VERSION_FILE}")"
fi

DAWN_TAG="${DAWN_TAG:-v${DAWN_VERSION}}"
DAWN_GIT_URL="${DAWN_GIT_URL:-https://github.com/google/dawn.git}"

CACHE_DIR="${REPO_ROOT}/.cache"
DEPOT_TOOLS_DIR="${CACHE_DIR}/depot_tools"
DAWN_SRC_DIR="${DAWN_SRC_DIR:-${CACHE_DIR}/dawn-${DAWN_VERSION}}"
BUILD_TYPES="${BUILD_TYPES:-Debug Release}"
JOBS="${JOBS:-$(nproc)}"

echo "==> dawn-exotic aarch64 build (depot_tools)"
echo "    repo root:    ${REPO_ROOT}"
echo "    dawn version: ${DAWN_VERSION}"
echo "    dawn tag:     ${DAWN_TAG}"
echo "    dawn url:     ${DAWN_GIT_URL}"
echo "    dawn source:  ${DAWN_SRC_DIR}"
echo "    depot_tools:  ${DEPOT_TOOLS_DIR}"
echo "    build types:  ${BUILD_TYPES}"
echo "    jobs:         ${JOBS}"

# 1. depot_tools
if [[ ! -x "${DEPOT_TOOLS_DIR}/gclient" ]]; then
    echo "==> Cloning depot_tools"
    mkdir -p "${CACHE_DIR}"
    rm -rf "${DEPOT_TOOLS_DIR}"
    git clone --depth 1 \
        https://chromium.googlesource.com/chromium/tools/depot_tools.git \
        "${DEPOT_TOOLS_DIR}"
fi
export PATH="${DEPOT_TOOLS_DIR}:${PATH}"
export DEPOT_TOOLS_UPDATE=0

# 2. Dawn checkout at the tagged release
if [[ ! -d "${DAWN_SRC_DIR}/.git" ]]; then
    echo "==> Cloning Dawn ${DAWN_TAG}"
    mkdir -p "$(dirname "${DAWN_SRC_DIR}")"
    git clone --depth 1 --branch "${DAWN_TAG}" "${DAWN_GIT_URL}" "${DAWN_SRC_DIR}"
fi

# 3. Bootstrap gclient
if [[ ! -f "${DAWN_SRC_DIR}/.gclient" ]]; then
    echo "==> Bootstrapping standalone.gclient"
    cp "${DAWN_SRC_DIR}/scripts/standalone.gclient" "${DAWN_SRC_DIR}/.gclient"
fi

# 4. gclient sync (fetch all deps). Skip if already populated.
if [[ ! -f "${DAWN_SRC_DIR}/third_party/abseil-cpp/CMakeLists.txt" ]]; then
    echo "==> gclient sync"
    (cd "${DAWN_SRC_DIR}" && gclient sync --no-history --shallow --jobs "${JOBS}")
fi

# 5. Build (mirrors upstream Dawn desktop CI: -C dawn-ci.cmake, full build, install, tar)
DAWN_CI_CACHE="${DAWN_SRC_DIR}/.github/workflows/dawn-ci.cmake"
if [[ ! -f "${DAWN_CI_CACHE}" ]]; then
    echo "ERROR: missing ${DAWN_CI_CACHE}" >&2
    exit 1
fi

for build_type in ${BUILD_TYPES}; do
    lower="${build_type,,}"
    build_dir="${REPO_ROOT}/build-aarch64-${lower}"

    echo
    echo "==> Configuring ${build_type} -> ${build_dir}"
    cmake -S "${DAWN_SRC_DIR}" -B "${build_dir}" -G Ninja \
        -C "${DAWN_CI_CACHE}" \
        -DCMAKE_BUILD_TYPE="${build_type}" \
        -DDAWN_USE_WAYLAND=ON \
        -DDAWN_USE_X11=ON

    echo "==> Building (full ${build_type})"
    cmake --build "${build_dir}" -j "${JOBS}"

    lib="${build_dir}/src/dawn/native/libwebgpu_dawn.a"
    if [[ ! -f "${lib}" ]]; then
        echo "ERROR: expected output not found: ${lib}" >&2
        exit 1
    fi
    echo "==> Built: ${lib} ($(du -h "${lib}" | cut -f1))"

    # Package: install + tar (mirrors upstream Dawn ci.yml "Package" step)
    stage="dawn-linux-aarch64-${lower}-${DAWN_VERSION}"
    rm -rf "${REPO_ROOT}/release/${stage}" "${REPO_ROOT}/release/${stage}.tar.gz"
    mkdir -p "${REPO_ROOT}/release"
    cmake --install "${build_dir}" --prefix "${REPO_ROOT}/release/${stage}"
    (cd "${REPO_ROOT}/release" && cmake -E tar cvzf "${stage}.tar.gz" "${stage}")
    rm -rf "${REPO_ROOT}/release/${stage}"
    echo "==> Packaged: ${REPO_ROOT}/release/${stage}.tar.gz"
done

echo
echo "==> Done."
