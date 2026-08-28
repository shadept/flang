# FLang

A statically-typed language that transpiles to C. Personal project for language design exploration.

> **Alpha** — not production ready. Expect breaking changes.

## Example

```
import core.io

pub fn main() i32 {
    println("hello, world!")
    return 0
}
```

## Getting started

### Just want to use it?

Grab the latest [release](https://github.com/shadept/flang/releases) —
`flang-<platform>.zip` carries the compiler and the stdlib it needs. Unzip it,
put the directory on your `PATH`, and skip to [Usage](#usage). You still need a
C compiler installed (GCC, Clang, or MSVC): FLang emits C99 and hands it to
your toolchain to produce the binary.

### Building from source

FLang is self-hosted — the compiler is written in FLang and compiles itself —
so a clean clone bootstraps from `boot/<platform>/`, which carries the compiler
as committed, generated C99 (the **bootstrap seed**). No prior FLang binary is
needed, and nothing outside the repo is downloaded.

**You need:** a C compiler (GCC, Clang, or MSVC) and
[.NET 10+](https://dotnet.microsoft.com/download). The C compiler builds the
seed and every binary after it; .NET runs only this repo's own scripts
(`build.cs`, `test.cs`, `test-all.cs`, `promote.cs`), never the compiler itself.

### 1. Clone

```sh
git clone https://github.com/shadept/flang.git
cd flang
```

### 2. Cold-start the seed

This compiles ~20 MB of generated C and takes a minute or two. You do this
**once per clone** — pick the line for your platform:

```sh
# run ONE of these, then return to the repo root
cd boot/linux-x64    && make       # Linux x64
cd boot/darwin-arm64 && make       # macOS ARM64
cd boot/win-x64      && build.bat  # Windows x64 - from a VS developer prompt

cd ../..
```

That produces `flang-seed`, a working compiler.

### 3. Build the compiler with itself

```sh
dotnet run build.cs
```

The seed builds the current sources and the result installs as
`dist/<platform>/flang` (e.g. `dist/linux-x64/flang`). From here on `build.cs`
builds with that installed compiler; the seed is only needed for another cold
start.

### 4. Check it works

```sh
cd examples/hello-world
../../dist/linux-x64/flang build   # ..\..\dist\win-x64\flang.exe on Windows
./build/hello-world
```

`dotnet run test.cs` runs the full language test suite if you want more
assurance.

Add `dist/<platform>/` to your `PATH` to use `flang` directly, as the examples
below do.

### Notes

- Re-running `dotnet run build.cs` with no source changes takes about two
  seconds; it skips the rebuild unless something under `compiler/`, `lib/` or
  `stdlib/` is newer. Pass `--force` to rebuild regardless.
- A `git worktree` gets tracked files only, so it has no `dist/` and no
  `flang-seed` — cold-start the seed again inside it, or point it at a compiler
  you already built.
- The seed changes only through `dotnet run promote.cs`, which gates on the
  stage-2 = stage-3 fixpoint and a green test suite. See `boot/README.md`.

## Usage

```sh
flang build hello.f              # compile a single file
flang build                      # compile a project (flang.toml) from its root
flang check                      # type-check only, including `test {}` bodies
flang test                       # run the project's `test {}` blocks
flang fmt                        # format the project (--check writes nothing)
flang lsp                        # language server over stdio
```

The CLI is `flang <command> [options]` — options are parsed against the command
they follow, so they come after it (`flang build -r`, not `flang -r build`).

## Documentation

- [Language specification](docs/spec.md)
- [Syntax quick reference](docs/syntax.md)
- [Architecture](docs/architecture.md)
- [Self-host status](docs/self-host.md)
- [Examples](examples/)
- [Error codes](docs/error-codes.md)
- [Known issues](docs/known-issues.md)

## Platform support

| Platform | Status |
|----------|--------|
| macOS (x64, arm64) | Tested |
| Linux (x64) | Tested (CI) |
| Windows (x64) | Tested (CI) |

## License

[MIT](LICENSE)

## Contributing

This is a personal project. I'm not accepting contributions at this time. Feel free to fork.
