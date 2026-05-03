# RFC-006: Syntax Cleanup — Quick Wins

**Type:** Syntax / Documentation / Small parser changes
**Status:** Proposed
**Depends on:** None

## Summary

Bundle of small syntax decisions from the May 2026 grilling review. Each item is a localized parser, lexer, or doc change. Larger chunks (Option-as-enum, `op_try`, declaration-form unification, pattern grammar, template DSL extensions, `?.` flattening) are tracked in their own RFCs.

## Items

Each item lists the rule, where it lives today, and the action required.

### 1. `for` loop — drop optional parens (Q1)

- **Rule:** `for x in xs { ... }`. The form `for (x in xs) { ... }` is invalid.
- **Today:** Both forms are accepted. Examples mix them ([snake/src/main.f:128](../../examples/snake/src/main.f:128) uses parens, [tree/src/main.f](../../examples/tree/src/main.f) does not).
- **Action:** Parser rejects `for (`. Migrate examples to bare form. Update [docs/syntax.md:143](../syntax.md:143).
- **Note:** `if (cond)` and `while (cond)` keep working — the parens are part of the expression, not the keyword form.

### 2. spec.md is canonical; syntax.md is stale (Q2)

- **Rule:** spec.md is the source of truth. syntax.md exists as a quick reference and must mirror spec.md.
- **Today:** The two operator tables disagree (syntax.md tops at level 11, spec.md at level 12; shifts missing from syntax.md; `char`/`void`/`never` missing from syntax.md primitives).
- **Action:** Sweep syntax.md to match spec.md. Add a header to syntax.md noting it's a derived reference.

### 3. `as` precedence — high (Q3)

- **Rule:** `as` is a postfix typed operator at the highest binary level (above `* / %`). `a + b as i32` parses as `a + (b as i32)`.
- **Today:** Parser already does this; spec doesn't document it.
- **Action:** Add `as` to the precedence table in spec.md §5.1 at the top.

### 4. `match` precedence — lowest (Q4)

- **Rule:** Postfix `match` binds looser than every binary operator. `a + b match { ... }` parses as `(a + b) match { ... }`.
- **Today:** Undocumented.
- **Action:** Add `match` at the bottom of the precedence table; add an example.

### 5. Match arm syntax — `pattern => { body }`, no commas (Q5)

- **Rule:** Every arm body is braced; arrow required. Arms separated by newline or `}`. No comma-separated arms.
- **Today:** Parser accepts comma-separated and brace-less forms. Examples mix all three.
- **Action:** Parser rejects bare-expression arms (`A => 1`); requires `A => { 1 }`. Removes comma-as-separator. Migrate examples (drop trailing commas, brace bare-expression arms).
- **Reason:** Hard `}` terminator avoids the greedy-parser swallow trap when literal patterns land.

### 6. Trailing commas allowed everywhere (Q9)

- **Rule:** Trailing commas allowed in any comma-separated list (function calls, struct literals, enum variant lists, parameter lists, generic params). Tuple `(x,)` keeps its 1-tuple meaning.
- **Today:** Underspecified per construct.
- **Action:** Parser accepts trailing commas uniformly. Spec.md adds one paragraph documenting the rule.

### 7. No labels for `break` / `continue` (Q10)

- **Rule:** `break` / `continue` always target innermost loop. No `break label` syntax.
- **Action:** None — this is status quo, just noting it's intentional.

### 8. `#` directive prefix — status quo (Q11)

- **Rule:** `#` keeps doing all jobs (directives, generators, conditionals). `@` reserved as a candidate for future split.
- **Action:** None — noting the decision.

### 9. No call-site type annotation syntax (Q13)

- **Rule:** No turbofish, no `[T]` type-arg list. Inference resolves type parameters; if it can't, user adds an explicit binding annotation (`let x: T = ...`).
- **Action:** None — status quo. Noting the decision so it doesn't get re-proposed.

### 10. No raw / multi-line string literals (Q14)

- **Rule:** Only `"..."` with escape sequences. No `r"..."`, no `"""..."""`.
- **Action:** None — defer until real pain materializes.

### 11. Numeric literal suffix — closed primitive list (Q15)

- **Rule:** Valid suffixes are exactly the primitive integer/float type names (`i8 i16 i32 i64 isize u8 u16 u32 u64 usize f32 f64`). `_` is a separator anywhere inside a number. `42_pixels` is an invalid identifier (digit-led), not a number with suffix.
- **Today:** Underspecified.
- **Action:** Lexer enforces the closed list. Spec.md §2.11 documents the rule, including the `_` separator and the digit-led-identifier error.

### 12. Range — `..` only, no `..=` (Q16)

- **Rule:** `..` is sugar for `Range(T)`, half-open `[start, end)`. No `..=`. No open-ended slicing forms (defer).
- **Action:** Update syntax.md to reference spec.md's range definition. No lexer change for `..=` (it's not a token).

### 13. Strict struct construction — all fields required (Q17)

- **Rule:** Every field must be assigned in a struct literal. `Point { x = 10 }` is an error if `Point` has more fields. `Marker { }` only valid for zero-field structs. `.{}` invalid (no fields → no inferable type).
- **Today:** Underspecified.
- **Action:** Type checker enforces. New error code (suggest E2050 or next free) "struct literal missing field `<name>`". Spec.md §2.4 documents.
- **Future:** Field-level defaults (`field: T = expr`) are a separate possible feature, not part of this rule.

### 14. Anonymous struct types — not first-class (Q19)

- **Rule:** `.{ ... }` value literals exist and require target type from context. Anonymous struct *types* parse only as RHS of `type` aliases and as generator-arg positions; they are not first-class type expressions.
- **Today:** Matches current parser behavior.
- **Action:** Spec.md §2.2 clarifies the restriction. Diagnostic for context-less `.{}` suggests "add a type annotation."

### 15. Lambda parameter inference (Q22)

- **Rule:** Lambdas mirror anon-struct rules. Parameter types must be inferable from context (callback to typed parameter, return type of enclosing function, explicit lambda annotation, or explicit variable annotation). No-context lambdas error.
- **Today:** Documented vaguely as "context available."
- **Action:** Tighten spec.md §7.3 wording. Diagnostic for no-context lambda points to the annotation fix.

### 16. Imports — flat, non-transitive (Q23)

- **Rule:** `import path` brings module's `pub` items into scope as bare names. Non-transitive: importing B does not expose B's imports. Overload resolution handles same-named imports; truly ambiguous calls error at the call site. No aliases, no selective imports, no relative paths.
- **Today:** Matches behavior; non-transitivity is not explicitly stated.
- **Action:** Spec.md §6 explicitly states non-transitivity and overload-handles-ambiguity. Document the recommended `all.f` pattern for "import everything in a folder."
- **Future:** Folder-glob imports (`import std.*`) parked.

### 17. Visibility — two-level only (Q24)

- **Rule:** `pub` (visible outside file) or file-private. No `pub` on individual fields. No properties (neither UFCS-method-pair nor C#-style declaration syntax). External "mutation" of struct state is by re-construction.
- **Today:** Matches current model. Scoped mutability (file-private writes) is documented as planned; not yet implemented (verified: no cross-file field-write check exists in [HmTypeChecker.Expressions.cs](../../src/FLang.Semantics/HmTypeChecker.Expressions.cs)).
- **Action:** None now for visibility itself. Scoped-mutability enforcement remains a separate planned task. When it lands, expect a migration sweep.

### 18. Comments — `//` only (Q25)

- **Rule:** `//` line comments only. No `/* */`, no `///`. Editor tooling handles "comment out a block."
- **Today:** Implemented; undocumented.
- **Action:** Spec.md adds a one-line "Comments: `//` to end of line." Lexer rejects `/*` and `*/` explicitly (or just doesn't recognize them — confirm current behavior).

### 19. `defer` — block-scoped, args at-defer (Q27)

- **Rule:** `defer expr` runs at the end of the enclosing **block**, not function. Arguments captured at defer-statement time, not at execution time. LIFO within each block.
- **Today:** Underspecified.
- **Action:** Verify current implementation matches; spec.md adds explicit semantics.

### 20. Tuple field naming — no reservation (Q28)

- **Rule:** User struct fields can be named anything, including `_0`, `_1`. Tuples generate `__0`, `__1` (double-underscore prefix matching the existing `__inner`/`__allocator` convention).
- **Today:** Tuples generate `_0`, `_1` per spec; risks collision with user-defined fields.
- **Action:** Lower tuples to `__N` instead of `_N`. Update [docs/spec.md:55](../spec.md:55) (tuple desugaring). User-facing access via `t.0` unchanged — desugar updates from `t._0` to `t.__0`.

### 21. No loop `else` (Q29)

- **Rule:** Python-style `for ... else` / `while ... else` does not exist.
- **Action:** None — noting the decision.

### 22. Blocks are always expressions (Q30)

- **Rule:** A `{ ... }` block is an expression. Its value is the value of its last expression, or unit if the last position is a statement. Standalone `let x = { foo(); 42 }` is valid.
- **Today:** Used inside `if`/`match`/lambda bodies; standalone use undocumented.
- **Action:** Spec.md states the uniform rule. Type checker confirms standalone block expressions work.

## Implementation order

Start with documentation-only items (2, 3, 4, 7, 8, 9, 10, 12, 17, 19, 20, 21, 22) to lock in the spec. Then parser changes (1, 5, 6, 18). Then type-checker changes (13, 14, 15). Then lowering change (20 — tuple `__N`).

## Out of scope

These items got their own RFCs from the same review:

- RFC-007: Option-to-enum migration + `null` as `Option.None` (Q7)
- RFC-008: Single declaration form `type Name = struct(T) { ... }` (Q6)
- RFC-009: `op_try` early-return operator (Q8)
- RFC-010: `?.` lifts and flattens; pattern grammar extensions (Q12, Q18). Smart casting deferred to a future RFC.
- RFC-011: Template DSL extensions — `#elif`, `#let`, `#match` (Q26)
