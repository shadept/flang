# flang_typer

Type system as a library. Owns the `Type` ADT, the unification engine,
polymorphic schemes, coercion rules, nominal/function registries, and
the AST-walking checker. Produces an immutable `TypeCheckResult` consumed
by lowering and the LSP.

See [`docs/tickets/017-typer-as-library.md`](../../docs/tickets/017-typer-as-library.md)
for the design rationale and the layout of each source file.

## Layering

```
flang_typer
  ├── data layer        type.f, well_known.f, scheme.f,
  │                     substitution.f, union_find.f
  ├── engine            inference_engine.f
  ├── coercion          coercion.f
  ├── registries        nominal_registry.f, function_registry.f,
  │                     visibility.f
  ├── checker support   env.f, inference_results.f, reporter.f,
  │                     error_codes.f
  ├── checker           checker.f, checker_expr.f, checker_stmt.f,
  │                     checker_decl.f, checker_pattern.f
  ├── specialization    specialization.f
  └── result            result.f
```
