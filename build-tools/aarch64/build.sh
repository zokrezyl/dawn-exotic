#!/usr/bin/env bash
# Build Dawn (webgpu_dawn) for Linux aarch64 in Debug and Release configs.
#
# Output:
#   <repo_root>/build-aarch64-debug/src/dawn/native/libwebgpu_dawn.a
#   <repo_root>/build-aarch64-release/src/dawn/native/libwebgpu_dawn.a
#
# Pinned version comes from <repo_root>/dawn-version (single line, e.g. "20260410.140140").
#
# Env overrides:
#   DAWN_VERSION   Version string (default: contents of dawn-version)
#   DAWN_REF       Git ref to check out (default: v${DAWN_VERSION})
#   DAWN_GIT_URL   Dawn git URL (default: https://dawn.googlesource.com/dawn)
#   DAWN_SRC_DIR   Existing Dawn source tree to reuse (skips clone+fetch)
#   BUILD_TYPES    Space-separated list (default: "Debug Release")
#   JOBS           Parallel jobs for ninja (default: nproc)

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

DAWN_REF="${DAWN_REF:-v${DAWN_VERSION}}"
DAWN_GIT_URL="${DAWN_GIT_URL:-https://dawn.googlesource.com/dawn}"
DAWN_SRC_DIR="${DAWN_SRC_DIR:-${REPO_ROOT}/.cache/dawn-src}"
BUILD_TYPES="${BUILD_TYPES:-Debug Release}"
JOBS="${JOBS:-$(nproc)}"

echo "==> dawn-exotic aarch64 build"
echo "    repo root:    ${REPO_ROOT}"
echo "    dawn version: ${DAWN_VERSION}"
echo "    dawn ref:     ${DAWN_REF}"
echo "    dawn source:  ${DAWN_SRC_DIR}"
echo "    build types:  ${BUILD_TYPES}"
echo "    jobs:         ${JOBS}"

if [[ ! -d "${DAWN_SRC_DIR}/.git" && ! -f "${DAWN_SRC_DIR}/CMakeLists.txt" ]]; then
    echo "==> Cloning Dawn (${DAWN_REF})"
    mkdir -p "$(dirname "${DAWN_SRC_DIR}")"
    git clone --depth 1 --branch "${DAWN_REF}" "${DAWN_GIT_URL}" "${DAWN_SRC_DIR}"
fi

if [[ ! -d "${DAWN_SRC_DIR}/third_party/abseil-cpp" ]]; then
    echo "==> Fetching Dawn third_party dependencies"
    python3 "${DAWN_SRC_DIR}/tools/fetch_dawn_dependencies.py" --directory "${DAWN_SRC_DIR}"
fi

for build_type in ${BUILD_TYPES}; do
    lower="${build_type,,}"
    build_dir="${REPO_ROOT}/build-aarch64-${lower}"

    echo
    echo "==> Configuring ${build_type} -> ${build_dir}"
    cmake -S "${DAWN_SRC_DIR}" -B "${build_dir}" -G Ninja \
        -DCMAKE_BUILD_TYPE="${build_type}" \
        -DDAWN_USE_WAYLAND=ON \
        -DDAWN_USE_X11=ON \
        -DDAWN_ENABLE_VULKAN=ON \
        -DDAWN_BUILD_SAMPLES=ON

    echo "==> Building webgpu_dawn (${build_type})"
    cmake --build "${build_dir}" --target webgpu_dawn -j "${JOBS}"

    lib="${build_dir}/src/dawn/native/libwebgpu_dawn.a"
    if [[ ! -f "${lib}" ]]; then
        echo "ERROR: expected output not found: ${lib}" >&2
        exit 1
    fi
    echo "==> Built: ${lib} ($(du -h "${lib}" | cut -f1))"
done

echo
echo "==> Done."
