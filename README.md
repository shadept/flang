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

This produces the compiler at `dist/<platform>/flang` (e.g. `dist/osx-x64/flang`, `dist/linux-x64/flang`, `dist/win-x64/flang.exe`).

## Usage

```sh
# Compile
flang hello.f

# Compile with optimizations
flang --release hello.f -o hello

# Run tests in a file
flang test myfile.f
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
