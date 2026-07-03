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
# Follows the official Dawn build flow (docs/building.md): depot_tools +
# gclient sync + cmake -G Ninja, compiled with MSVC. An MSVC dev environment
# must be on PATH: the CI job sets it up via ilammy/msvc-dev-cmd; locally, run
# this from an "x64 Native Tools Command Prompt for VS" (or dot-source
# vcvars64.bat first) so `cl` and `ninja` resolve.
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

$CacheDir      = Join-Path $RepoRoot '.cache'
$DepotToolsDir = Join-Path $CacheDir 'depot_tools'
$DawnSrcDir    = if ($env:DAWN_SRC_DIR) { $env:DAWN_SRC_DIR } else { Join-Path $CacheDir "dawn-$DawnVersion" }
$BuildTypes    = if ($env:BUILD_TYPES) { $env:BUILD_TYPES -split '\s+' } else { @('Release') }
$Jobs          = if ($env:JOBS) { $env:JOBS } else { $env:NUMBER_OF_PROCESSORS }

Write-Host "==> dawn-exotic windows build (depot_tools)"
Write-Host "    repo root:    $RepoRoot"
Write-Host "    dawn version: $DawnVersion"
Write-Host "    dawn tag:     $DawnTag"
Write-Host "    dawn url:     $DawnGitUrl"
Write-Host "    dawn source:  $DawnSrcDir"
Write-Host "    depot_tools:  $DepotToolsDir"
Write-Host "    build types:  $($BuildTypes -join ' ')"
Write-Host "    jobs:         $Jobs"

# 1. depot_tools
if (-not (Test-Path (Join-Path $DepotToolsDir 'gclient.bat'))) {
    Write-Host "==> Cloning depot_tools"
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
    if (Test-Path $DepotToolsDir) { Remove-Item -Recurse -Force $DepotToolsDir }
    Invoke-Checked { git clone --depth 1 `
        https://chromium.googlesource.com/chromium/tools/depot_tools.git `
        $DepotToolsDir } 'git clone depot_tools'
}
$env:PATH = "$DepotToolsDir;$env:PATH"
$env:DEPOT_TOOLS_UPDATE = '0'
# Use the locally-installed MSVC toolchain, not Google's internal package.
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
# depot_tools bootstraps its bundled Python/Git automatically on the first
# gclient invocation (the sync below), so no explicit priming step is needed.

# 2. Dawn checkout at the tagged release
if (-not (Test-Path (Join-Path $DawnSrcDir '.git'))) {
    Write-Host "==> Cloning Dawn $DawnTag"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DawnSrcDir) | Out-Null
    Invoke-Checked { git clone --depth 1 --branch $DawnTag $DawnGitUrl $DawnSrcDir } 'git clone dawn'
}

# 3. Bootstrap gclient
$GclientFile = Join-Path $DawnSrcDir '.gclient'
if (-not (Test-Path $GclientFile)) {
    Write-Host "==> Bootstrapping standalone.gclient"
    Copy-Item (Join-Path $DawnSrcDir 'scripts\standalone.gclient') $GclientFile
}

# 4. gclient sync (fetch all deps). Skip if already populated.
if (-not (Test-Path (Join-Path $DawnSrcDir 'third_party\abseil-cpp\CMakeLists.txt'))) {
    Write-Host "==> gclient sync"
    Push-Location $DawnSrcDir
    try {
        Invoke-Checked { & cmd /c "gclient sync --no-history --shallow --jobs $Jobs" } 'gclient sync'
    } finally { Pop-Location }
}

# 5. Build (mirrors the *nix scripts: -C dawn-ci.cmake, full build, install, tar)
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
    # strict superset of the stock Windows build. Ninja + MSVC (cl) from the
    # dev environment already on PATH.
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
