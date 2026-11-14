# Raylib Demo

Demonstrates FLang's C FFI binding generation with [raylib](https://www.raylib.com/).

## Prerequisites

Install raylib (tested with 6.2):

```bash
# macOS
brew install raylib

# Ubuntu/Debian
sudo apt install libraylib-dev

# Windows: download raylib-6.2_win64_msvc16.zip from
# https://github.com/raysan5/raylib/releases and extract it
```

## Build & Run

```bash
# macOS - set RAYLIB_PATH to your raylib installation
export RAYLIB_PATH=$(brew --prefix raylib)
flang build
./build/raylib-demo

# Windows
export RAYLIB_PATH=C:/path/to/raylib-6.2_win64_msvc16
flang build
cp "$RAYLIB_PATH/lib/raylib.dll" build/
./build/raylib-demo.exe

# Linux
flang build
./build/raylib-demo
```

`flang build` preprocesses the header `flang.toml` names, writes `vendor/raylib.f` (skipped while
the header is unchanged), then compiles `src/main.f` against it and links raylib. On Windows the
demo links the DLL's import library: the static `raylib.lib` expects the DLL C runtime.

## What it does

Opens an 800x450 window with:
- A blue rectangle
- A red ball you can move with arrow keys
- Text overlay

Exercises FFI features: foreign functions, foreign structs (`Color`, `Rectangle`), and enum constants (`KEY_*`).
