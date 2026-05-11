# flang_fmt

FLang source formatter. Lossless: walks the CST, rewrites trivia under a
fixed style policy, re-emits source.

## Build

```
flang build           # from inside tools/flang_fmt/
```

## Use

```
build/flang_fmt file.f [...]
```
