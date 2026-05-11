# dump_tokens

Smoke-test consumer for the `flang_parser` library. Loads a `.f` file, runs
the lexer, prints the token stream.

Exists to validate the library-dependency mechanism end-to-end: every change
to `flang_parser`'s public surface should keep this building.

## Build

```
flang build           # from inside tools/dump_tokens/
```

## Use

```
build/dump_tokens path/to/file.f
```
