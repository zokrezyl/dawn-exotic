## Why


These builds aim to make Dawn usable on targets that are otherwise inconvenient to bring up, by providing ready-to-use artifacts for tvOS, Linux aarch64 (Raspberry Pi), and Linux x86_64 with full Wayland WSI support. The goal is to remove build friction and enable running the same WebGPU code across these environments with minimal setup.


### Linux x86_64

The official `google/dawn` CI builds the `Dawn-*-ubuntu-latest-Release.tar.gz`
artifact without `-DDAWN_USE_WAYLAND=ON`. Dawn's `CMakeLists.txt` defaults
`USE_WAYLAND` to `OFF` and only flips `USE_X11 ON` for UNIX, so the public
tarball has `DAWN_USE_WAYLAND` undefined. The `case SurfaceSourceWaylandSurface`
in `src/dawn/native/Surface.cpp` is `#if`-guarded behind that define, so on
native Wayland sessions any attempt to create a `WGPUSurface` fails at
`ValidateSurfaceDescriptor` with `"Unsupported sType"`. This repo rebuilds the
same pinned commit with both `-DDAWN_USE_X11=ON` and `-DDAWN_USE_WAYLAND=ON`
so Wayland sessions work alongside X11/XWayland.


### OpenGL backend (all platforms)

Every desktop artifact here is built with `-DDAWN_ENABLE_DESKTOP_GL=ON` and
`-DDAWN_ENABLE_OPENGLES=ON`. Those default `OFF` and are not enabled by
`dawn-ci.cmake`, so the stock `google/dawn` releases contain no OpenGL backend
whatsoever — inspecting the shipped library shows zero GL/EGL/WGL symbols.
That leaves `WEBGPU_BACKEND=opengl` with nothing to select. Enabling the GL
backends lets Dawn drive a vendor OpenGL ICD (via GLX/EGL on Linux, WGL on
Windows) on hosts where Vulkan/D3D12 are unavailable.


### Windows x86_64

The official `Dawn-*-windows-latest-Release.tar.gz` is built with the
D3D12 / D3D11 / Vulkan backends only. On virtualized GPUs such as VMware
SVGA 3D — which expose hardware OpenGL (`vm3dgl64.dll`) but no usable D3D12 or
Vulkan device — Dawn falls back to the WARP software rasterizer, so a
GPU-driven app renders entirely on the CPU. This build enables the desktop-GL
/ GLES backends on top of D3D + Vulkan (a strict superset of the stock build)
so `WEBGPU_BACKEND=opengl` can reach the virtual GPU's native GL ICD.

Built with depot_tools + `cmake -G Ninja` under MSVC (see
`build-tools/windows/build.ps1`); the CI job provisions the compiler with
`ilammy/msvc-dev-cmd`. Output: `dawn-windows-x86_64-release-<version>.tar.gz`
(`lib/webgpu_dawn.lib` + `include/`, matching the *nix install layout).


As a concrete example, Yetty (https://yetty.dev, https://github.com/zokrezyl/yetty) is a terminal emulator built entirely on WebGPU using Dawn. It runs on tvOS, Raspberry Pi (aarch64), and Linux x86_64 (X11 + Wayland) with a fully GPU-driven rendering pipeline.
