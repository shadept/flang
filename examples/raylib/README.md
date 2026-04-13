# Raylib Demo

Demonstrates FLang's C FFI binding generation with [raylib](https://www.raylib.com/).

## Prerequisites

Install raylib:

```bash
# macOS
brew install raylib

# Ubuntu/Debian
sudo apt install libraylib-dev

# Or build from source: https://github.com/raysan5/raylib
```

## Build & Run

```bash
# macOS with Homebrew
flang -I $(brew --prefix raylib)/include/raylib.h \
      -L $(brew --prefix raylib)/lib/libraylib.a \
      --link "-framework CoreVideo" \
      --link "-framework IOKit" \
      --link "-framework Cocoa" \
      --link "-framework GLUT" \
      --link "-framework OpenGL" \
      main.f
./main

# Linux
flang -I /usr/include/raylib.h -L /usr/lib/libraylib.a main.f
./main
```

The compiler automatically:
1. Parses `raylib.h` and generates `vendor/raylib.f` with foreign bindings
2. Compiles `main.f` (which imports the generated bindings)
3. Links against `libraylib.a`

## What it does

Opens an 800x450 window with:
- A blue rectangle
- A red ball you can move with arrow keys
- Text overlay

Exercises FFI features: foreign functions, foreign structs (`Color`, `Rectangle`), and enum constants (`KEY_*`).
