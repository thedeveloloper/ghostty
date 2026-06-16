# Ghostty for Windows (proof of concept)

A minimal native Win32 host that embeds `libghostty` through its C API, the
same way the macOS app embeds it. It opens one window, creates a terminal
surface bound to the window's `HWND`, and lets the Direct3D 11 renderer inside
`libghostty` draw into it.

This is an early proof of concept: a single window, basic keyboard input (typed
text and Enter), and just enough action handling to function. Tabs, splits,
full keyboard/IME/clipboard handling, native chrome, and a settings UI are not
implemented yet.

## Building

1. Build `libghostty` from the repository root (this produces the DLL, the
   import library, and the header under `zig-out`):

   ```
   zig build -Dapp-runtime=none
   ```

2. Configure and build this host, pointing it at that output:

   ```
   cmake -S windows -B windows/build -DGHOSTTY_DIR=%CD%/zig-out
   cmake --build windows/build
   ```

   Place `ghostty.dll` (the `libghostty` shared library) next to the resulting
   `ghostty.exe`, or on the `PATH`, before running.

## Status

Verified to compile (the Zig core and renderer cross-compile for Windows, and
this host compiles against `ghostty.h`). It has not yet been run on Windows;
the end-to-end render/input path is validated there.
