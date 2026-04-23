#!/usr/bin/env bash
# Build Dawn (webgpu_dawn) for tvOS — device + simulator — packaged as xcframework.
#
# Mirrors Dawn's upstream Apple build recipe (.github/workflows/ci.yml +
# .github/workflows/dawn-ci.cmake) using the ios-cmake toolchain at the same
# pinned commit. Substitutes tvOS PLATFORM tokens (TVOS / SIMULATOR_TVOS /
# SIMULATORARM64_TVOS) for the iOS ones (OS64 / SIMULATOR64 / SIMULATORARM64).
#
# Host: macOS with Xcode + command-line tools.
#
# Output:
#   <repo_root>/build-tvos-debug/webgpu_dawn.xcframework
#   <repo_root>/build-tvos-release/webgpu_dawn.xcframework
#
# Per-slice intermediate builds (kept for inspection):
#   <repo_root>/build-tvos-{debug,release}-{device,sim_arm64,sim_x86_64}/
#
# Pinned version comes from <repo_root>/dawn-version.
#
# Env overrides:
#   DAWN_VERSION             Version string (default: contents of dawn-version)
#   DAWN_TAG                 Git tag (default: v${DAWN_VERSION})
#   DAWN_GIT_URL             Dawn clone URL (default: https://github.com/google/dawn.git)
#   DAWN_SRC_DIR             Existing Dawn source tree to reuse
#   BUILD_TYPES              Space-separated list (default: "Debug Release")
#   TVOS_DEPLOYMENT_TARGET   Min tvOS version (default: 14.0, matches Dawn iOS target)
#   IOS_CMAKE_COMMIT         leetal/ios-cmake pinned commit
#                            (default: matches Dawn upstream)
#   JOBS                     Parallel jobs (default: sysctl hw.ncpu)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "ERROR: tvOS builds require a macOS host (Xcode)" >&2
    exit 1
fi

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
TVOS_DEPLOYMENT_TARGET="${TVOS_DEPLOYMENT_TARGET:-14.0}"
IOS_CMAKE_COMMIT="${IOS_CMAKE_COMMIT:-6fa909e133b92343db2d099e0478448c05ffec1a}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

TOOLCHAIN_FILE="${CACHE_DIR}/ios-cmake-${IOS_CMAKE_COMMIT}.cmake"
DAWN_CI_CACHE="${DAWN_SRC_DIR}/.github/workflows/dawn-ci.cmake"

echo "==> dawn-exotic tvOS build"
echo "    repo root:    ${REPO_ROOT}"
echo "    dawn version: ${DAWN_VERSION}"
echo "    dawn tag:     ${DAWN_TAG}"
echo "    dawn source:  ${DAWN_SRC_DIR}"
echo "    deployment:   tvOS ${TVOS_DEPLOYMENT_TARGET}"
echo "    toolchain:    ${TOOLCHAIN_FILE}"
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

# 2. Dawn checkout
if [[ ! -d "${DAWN_SRC_DIR}/.git" ]]; then
    echo "==> Cloning Dawn ${DAWN_TAG}"
    mkdir -p "$(dirname "${DAWN_SRC_DIR}")"
    git clone --depth 1 --branch "${DAWN_TAG}" "${DAWN_GIT_URL}" "${DAWN_SRC_DIR}"
fi

# 3. gclient bootstrap + sync
if [[ ! -f "${DAWN_SRC_DIR}/.gclient" ]]; then
    cp "${DAWN_SRC_DIR}/scripts/standalone.gclient" "${DAWN_SRC_DIR}/.gclient"
fi
if [[ ! -f "${DAWN_SRC_DIR}/third_party/abseil-cpp/CMakeLists.txt" ]]; then
    echo "==> gclient sync"
    (cd "${DAWN_SRC_DIR}" && gclient sync --no-history --shallow --jobs "${JOBS}")
fi

# 4. ios-cmake toolchain (Dawn upstream uses leetal/ios-cmake at this commit)
if [[ ! -f "${TOOLCHAIN_FILE}" ]]; then
    echo "==> Downloading ios-cmake toolchain (${IOS_CMAKE_COMMIT})"
    curl --fail --location --show-error --silent \
        "https://raw.githubusercontent.com/leetal/ios-cmake/${IOS_CMAKE_COMMIT}/ios.toolchain.cmake" \
        --output "${TOOLCHAIN_FILE}"
fi

if [[ ! -f "${DAWN_CI_CACHE}" ]]; then
    echo "ERROR: missing ${DAWN_CI_CACHE}" >&2
    exit 1
fi

# Common cmake args matching Dawn's upstream Apple recipe:
#   -DDAWN_MOBILE_BUILD=apple   triggers Dawn's mobile cache path
#   -C dawn-ci.cmake            shared mobile/static config (samples off, etc.)
#   -DCMAKE_TOOLCHAIN_FILE=...  ios-cmake toolchain
#   -DENABLE_BITCODE=OFF -DENABLE_ARC=OFF -DENABLE_VISIBILITY=OFF
common_cmake_flags=(
    -G Ninja
    -DDAWN_MOBILE_BUILD=apple
    -C "${DAWN_CI_CACHE}"
    -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN_FILE}"
    -DDEPLOYMENT_TARGET="${TVOS_DEPLOYMENT_TARGET}"
    -DENABLE_BITCODE=OFF
    -DENABLE_ARC=OFF
    -DENABLE_VISIBILITY=OFF
)

# Build a single (build_type, slice, PLATFORM) combination.
build_slice() {
    local build_type="$1" slice="$2" platform="$3"
    local lower
    lower="$(printf '%s' "${build_type}" | tr '[:upper:]' '[:lower:]')"
    local build_dir="${REPO_ROOT}/build-tvos-${lower}-${slice}"

    echo
    echo "==> Configuring ${build_type}/${slice} (PLATFORM=${platform}) -> ${build_dir}"
    cmake -S "${DAWN_SRC_DIR}" -B "${build_dir}" \
        "${common_cmake_flags[@]}" \
        -DPLATFORM="${platform}" \
        -DCMAKE_BUILD_TYPE="${build_type}"

    echo "==> Building webgpu_dawn (${build_type}/${slice})"
    cmake --build "${build_dir}" --target webgpu_dawn -j "${JOBS}"

    local lib="${build_dir}/src/dawn/native/libwebgpu_dawn.a"
    if [[ ! -f "${lib}" ]]; then
        echo "ERROR: expected output not found: ${lib}" >&2
        exit 1
    fi
    echo "==> Slice built: ${lib} ($(du -h "${lib}" | cut -f1))"
}

for build_type in ${BUILD_TYPES}; do
    lower="$(printf '%s' "${build_type}" | tr '[:upper:]' '[:lower:]')"

    # Three slices, matching Dawn's iOS layout but targeting tvOS SDKs.
    build_slice "${build_type}" "device"     "TVOS"
    build_slice "${build_type}" "sim_arm64"  "SIMULATORARM64_TVOS"
    build_slice "${build_type}" "sim_x86_64" "SIMULATOR_TVOS"

    # lipo simulator slices into one fat .a (xcodebuild requires one lib per SDK).
    sim_dir="${REPO_ROOT}/build-tvos-${lower}-simulator"
    sim_lib="${sim_dir}/libwebgpu_dawn.a"
    mkdir -p "${sim_dir}"
    echo
    echo "==> Lipo-ing simulator slices -> ${sim_lib}"
    lipo -create \
        "${REPO_ROOT}/build-tvos-${lower}-sim_arm64/src/dawn/native/libwebgpu_dawn.a" \
        "${REPO_ROOT}/build-tvos-${lower}-sim_x86_64/src/dawn/native/libwebgpu_dawn.a" \
        -output "${sim_lib}"

    # Assemble xcframework.
    xcfw="${REPO_ROOT}/build-tvos-${lower}/webgpu_dawn.xcframework"
    mkdir -p "$(dirname "${xcfw}")"
    rm -rf "${xcfw}"
    echo
    echo "==> Assembling ${xcfw}"
    xcodebuild -create-xcframework \
        -library "${REPO_ROOT}/build-tvos-${lower}-device/src/dawn/native/libwebgpu_dawn.a" \
        -library "${sim_lib}" \
        -output "${xcfw}"
    echo "==> Built: ${xcfw}"
done

echo
echo "==> Done."
