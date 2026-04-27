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


As a concrete example, Yetty (https://yetty.dev, https://github.com/zokrezyl/yetty) is a terminal emulator built entirely on WebGPU using Dawn. It runs on tvOS, Raspberry Pi (aarch64), and Linux x86_64 (X11 + Wayland) with a fully GPU-driven rendering pipeline.
