# SDL3 Demo

Calls [SDL 3.4](https://libsdl.org/) (tested with 3.4.20) through bindings `flang build` generates
from `SDL.h` into `vendor/SDL.f`.
A red square moves with the arrow keys; Escape or closing the window quits.

## Windows

Download `SDL3-devel-3.4.20-VC.zip` from the [release](https://github.com/libsdl-org/SDL/releases/tag/release-3.4.20) and extract it.

```sh
export SDL3_PATH=C:/path/to/SDL3-3.4.20
flang build
cp "$SDL3_PATH/lib/x64/SDL3.dll" build/
./build/sdl3.exe
```

## Linux

Install SDL3 (`libsdl3-dev`), then `flang build && ./build/sdl3`.
