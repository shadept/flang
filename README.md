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

## Build from source

Requires [.NET 10+](https://dotnet.microsoft.com/download) and a C compiler (GCC, Clang, or MSVC).

```sh
git clone https://github.com/shadept/flang.git
cd flang
dotnet run build.cs
```

One command bootstraps the whole chain: it publishes the C# reference compiler,
builds the self-hosted compiler with it, and installs that as the default. Two
binaries land in `dist/<platform>/` (e.g. `dist/darwin-arm64`, `dist/linux-x64`,
`dist/win-x64`):

| Binary | What it is |
|--------|------------|
| `flang` | **The default compiler** — self-hosted, written in FLang |
| `flang-ref` | The C# reference compiler, used to bootstrap `flang` |

Each binary names itself in `--version` and `--help`, so there is no guessing
which one you are holding.

The self-hosted CLI is not yet at feature parity with the reference: it has
`build`, `fmt`, `lsp`, `cst` and `tokens`, but no `test` runner, no `-o`, no
`--release` and no bare-file form. Reach for `flang-ref` when you need those.

Re-running `dotnet run build.cs` after no source changes takes about two
seconds; it skips the self-hosted rebuild unless something under `bootstrap/`,
`lib/`, `stdlib/` or `src/` is newer. Pass `--force` to rebuild regardless.

### Building from the seed (C compiler only)

`boot/<platform>/` carries the self-hosted compiler as committed, generated
C99 — a bootstrap seed that needs no .NET and no prior FLang binary:

```sh
cd boot/linux-x64 && make        # build.bat on Windows (VS dev prompt)
cd ../../bootstrap
../boot/linux-x64/flang-seed -r -s ../stdlib build
```

That is the whole chain: the seed builds the current compiler from source.
The seed only changes through `dotnet run promote.cs`, which gates on the
stage-2 = stage-3 fixpoint and a green test suite — see `boot/README.md`.

## Usage

```sh
# Compile a project (flang.toml) or a single file
flang build hello.f

# Reference-only, for now
flang-ref hello.f                       # bare-file compile
flang-ref --release hello.f -o hello    # optimizations and output path
flang-ref test myfile.f                 # run `test {}` blocks in a file
```

## Documentation

- [Language specification](docs/spec.md)
- [Syntax quick reference](docs/syntax.md)
- [Architecture](docs/architecture.md)
- [Roadmap](docs/roadmap.md)
- [Examples](examples/)
- [Error codes](docs/error-codes.md)

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
