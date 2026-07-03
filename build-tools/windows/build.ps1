# Build Dawn (webgpu_dawn) for Windows x86_64 with the OpenGL backend enabled.
#
# Why a separate Windows build (vs. consuming google/dawn's CI prebuilt):
#   The official Dawn-*-windows-latest-Release.tar.gz is built with only the
#   D3D12 / D3D11 / Vulkan backends. DAWN_ENABLE_DESKTOP_GL and
#   DAWN_ENABLE_OPENGLES are OFF, so the shipped webgpu_dawn.lib contains no
#   OpenGL backend at all (0 GL/EGL/WGL symbols). On virtualized GPUs such as
#   VMware SVGA 3D, which expose hardware OpenGL (vm3dgl64.dll) but no usable
#   D3D12/Vulkan device, Dawn then falls back to the WARP software rasterizer.
#   This build turns the desktop-GL / GLES backends on so WEBGPU_BACKEND=opengl
#   can drive the vendor GL ICD and reach the virtual GPU.
#
# Dependency fetch: unlike the *nix scripts (depot_tools + gclient), Windows
# uses Dawn's standalone tools/fetch_dawn_dependencies.py. depot_tools' git
# shim + git-cache path is fragile in headless CI (gclient sync dies in
# cache_dir with WinError 2); the standalone fetcher uses plain system git and
# is the documented lightweight path for CMake-only builds (docs/building.md).
#
# Build: cmake -G Ninja, compiled with MSVC. An MSVC dev environment must be on
# PATH: the CI job sets it up via ilammy/msvc-dev-cmd; locally, run this from an
# "x64 Native Tools Command Prompt for VS" (or dot-source vcvars64.bat first) so
# `cl` and `ninja` resolve. Requires system `git` and `python` on PATH.
#
# Output:
#   <repo_root>/release/dawn-windows-x86_64-<type>-<version>.tar.gz
#     (lib/webgpu_dawn.lib + include/, matching the *nix install layout)
#
# Env overrides mirror the *nix scripts:
#   DAWN_VERSION   Version string (default: contents of dawn-version)
#   DAWN_TAG       Git tag (default: v${DAWN_VERSION})
#   DAWN_GIT_URL   Dawn clone URL (default: https://github.com/google/dawn.git)
#   DAWN_SRC_DIR   Existing Dawn source tree to reuse
#   BUILD_TYPES    Space-separated list (default: "Release"; Debug Dawn on
#                  Windows is very large, so Release only by default)
#   JOBS           Parallel jobs (default: %NUMBER_OF_PROCESSORS%)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Checked {
    param([Parameter(Mandatory)][scriptblock]$Script, [string]$What = 'command')
    & $Script
    if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE)" }
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path

$VersionFile = Join-Path $RepoRoot 'dawn-version'
$DawnVersion = $env:DAWN_VERSION
if ([string]::IsNullOrWhiteSpace($DawnVersion)) {
    if (-not (Test-Path $VersionFile)) {
        throw "$VersionFile not found and DAWN_VERSION not set"
    }
    $DawnVersion = (Get-Content $VersionFile -Raw).Trim()
}

$DawnTag    = if ($env:DAWN_TAG)     { $env:DAWN_TAG }     else { "v$DawnVersion" }
$DawnGitUrl = if ($env:DAWN_GIT_URL) { $env:DAWN_GIT_URL } else { 'https://github.com/google/dawn.git' }

$CacheDir   = Join-Path $RepoRoot '.cache'
$DawnSrcDir = if ($env:DAWN_SRC_DIR) { $env:DAWN_SRC_DIR } else { Join-Path $CacheDir "dawn-$DawnVersion" }
$BuildTypes = if ($env:BUILD_TYPES) { $env:BUILD_TYPES -split '\s+' } else { @('Release') }
$Jobs       = if ($env:JOBS) { $env:JOBS } else { $env:NUMBER_OF_PROCESSORS }

Write-Host "==> dawn-exotic windows build (fetch_dawn_dependencies)"
Write-Host "    repo root:    $RepoRoot"
Write-Host "    dawn version: $DawnVersion"
Write-Host "    dawn tag:     $DawnTag"
Write-Host "    dawn url:     $DawnGitUrl"
Write-Host "    dawn source:  $DawnSrcDir"
Write-Host "    build types:  $($BuildTypes -join ' ')"
Write-Host "    jobs:         $Jobs"

# 1. Dawn checkout at the tagged release
if (-not (Test-Path (Join-Path $DawnSrcDir '.git'))) {
    Write-Host "==> Cloning Dawn $DawnTag"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DawnSrcDir) | Out-Null
    Invoke-Checked { git clone --depth 1 --branch $DawnTag $DawnGitUrl $DawnSrcDir } 'git clone dawn'
}

# 2. Fetch third-party deps with Dawn's standalone fetcher (no depot_tools).
#    Populates third_party/ using plain system git; skip if already present.
if (-not (Test-Path (Join-Path $DawnSrcDir 'third_party\abseil-cpp\CMakeLists.txt'))) {
    Write-Host "==> Fetching Dawn dependencies (fetch_dawn_dependencies.py --shallow)"
    Push-Location $DawnSrcDir
    try {
        Invoke-Checked { python tools/fetch_dawn_dependencies.py --shallow } 'fetch_dawn_dependencies'
    } finally { Pop-Location }
}

# 3. Build (mirrors the *nix scripts: -C dawn-ci.cmake, full build, install, tar)
$DawnCiCache = Join-Path $DawnSrcDir '.github\workflows\dawn-ci.cmake'
if (-not (Test-Path $DawnCiCache)) { throw "missing $DawnCiCache" }

New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot 'release') | Out-Null

foreach ($buildType in $BuildTypes) {
    $lower    = $buildType.ToLower()
    $buildDir = Join-Path $RepoRoot "build-windows-x86_64-$lower"

    Write-Host ""
    Write-Host "==> Configuring $buildType -> $buildDir"
    # -C dawn-ci.cmake gives the lean upstream config (samples/tests off, D3D +
    # Vulkan on). We add the OpenGL backends on top; command-line -D overrides
    # the -C cache. D3D11/D3D12/Vulkan are re-asserted ON so this artifact is a
    # strict superset of the stock Windows build. DAWN_SUPPORTS_CXX_MODULES=OFF
    # skips the C++20 module target, whose generate step fails under MSVC/Ninja
    # (no module dependency scanner wired). Ninja + MSVC (cl) from the dev
    # environment already on PATH.
    Invoke-Checked { cmake -S $DawnSrcDir -B $buildDir -G Ninja `
        -C $DawnCiCache `
        -DCMAKE_BUILD_TYPE=$buildType `
        -DCMAKE_C_COMPILER=cl `
        -DCMAKE_CXX_COMPILER=cl `
        -DDAWN_ENABLE_D3D11=ON `
        -DDAWN_ENABLE_D3D12=ON `
        -DDAWN_ENABLE_VULKAN=ON `
        -DDAWN_ENABLE_DESKTOP_GL=ON `
        -DDAWN_ENABLE_OPENGLES=ON `
        -DDAWN_SUPPORTS_CXX_MODULES=OFF } 'cmake configure'

    Write-Host "==> Building (full $buildType)"
    Invoke-Checked { cmake --build $buildDir -j $Jobs } 'cmake build'

    $lib = Join-Path $buildDir 'src\dawn\native\webgpu_dawn.lib'
    if (-not (Test-Path $lib)) { throw "expected output not found: $lib" }
    $sizeMb = [math]::Round((Get-Item $lib).Length / 1MB, 1)
    Write-Host "==> Built: $lib (${sizeMb} MB)"

    # Package: install + tar (mirrors the *nix "Package" step / layout).
    $stage    = "dawn-windows-x86_64-$lower-$DawnVersion"
    $stageDir = Join-Path $RepoRoot "release\$stage"
    if (Test-Path $stageDir) { Remove-Item -Recurse -Force $stageDir }
    Invoke-Checked { cmake --install $buildDir --prefix $stageDir } 'cmake install'
    Push-Location (Join-Path $RepoRoot 'release')
    try {
        Invoke-Checked { cmake -E tar cvzf "$stage.tar.gz" $stage } 'tar'
    } finally { Pop-Location }
    Remove-Item -Recurse -Force $stageDir
    Write-Host "==> Packaged: release\$stage.tar.gz"
}

Write-Host ""
Write-Host "==> Done."
