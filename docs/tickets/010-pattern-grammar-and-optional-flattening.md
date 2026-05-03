# RFC-010: Pattern Grammar Extensions and `?.` Flattening

**Type:** Language semantics + type checker
**Status:** Proposed
**Depends on:** RFC-007 (Option as enum), RFC-006 §5 (match arm syntax)

## Summary

Two connected improvements to pattern matching and optional chaining:

1. **Pattern grammar extensions:** or-patterns (`A | B`), guard clauses (`pat if cond`), tuple destructuring (`(a, b)`), struct destructuring (`Point { x, y }`), range patterns (`0..10`, `0..=10`, `..0`, `1..`), plus a documented exhaustiveness model for the full grammar.
2. **`?.` lifts and flattens:** chained optional access never produces nested `Option(Option(...))`. `a?.b?.c` always yields `Option(typeof c)`, even if `b` itself returns `Option`.

**Deferred to a future RFC:** Kotlin-style smart casting (narrowing the matched value's type inside an arm body) was originally bundled here. It needs deeper design — interaction with mutability, aliasing, the not-yet-built type-narrowing pipeline, and an `is`-style operator that would share the same machinery. Removed from this RFC; users continue to use the bound payload name (`Some(v) => use(v)`) until smart casting gets its own design pass.

## Motivation

### Pattern grammar

Today's pattern grammar is minimal: unit variant, payload binding, qualified, nested, wildcard, literal, `else`. Real code shows the gaps:

- **Or-patterns:** matching multiple variants with the same body requires duplicating the arm body. Common for "any error variant collapses to `false`."
- **Guards:** matching a variant *and* a condition requires nested `if` inside the arm. Verbose.
- **Tuple/struct destructuring:** when matching on a `(i32, bool)` or a `Point`, manually accessing `.0`/`.1` or `.x`/`.y` inside the arm is noise.
- **Ranges:** sign-dispatch (`< 0` / `== 0` / `> 0`), small-keypad dispatch (`'0'..='9'`), and bucketed thresholds need a checkable form. Guards can express them but are opaque to exhaustiveness; ranges encode the same information in a form the checker understands.

### `?.` flattening

Today `a?.b?.c` where `b` returns `Option(B)` produces `Option(Option(C))` — annoying to work with. Per Q18, the chain should auto-flatten so the result is always `Option(typeof c)`. JS/TS semantics, plus monadic `bind`-style flattening for already-Option intermediates.

## Design

### Pattern grammar

#### Or-patterns

```
expr match {
    Red | Green | Blue => { /* body */ }
    Other => { /* body */ }
}
```

- `|` separates alternatives. All alternatives must bind the same variable names with the same types.
- Disallowed: `Some(x) | None => { use(x) }` — `x` not bound on the `None` side. Error E20XX.
- Allowed: `Some(x) | Other(x) => { use(x) }` if `x` has the same type in both.

#### Guard clauses

```
expr match {
    Move(x, y) if x > 0 and y > 0 => { /* body */ }
    Move(_, _) => { /* fallback */ }
    else => { /* default */ }
}
```

- `if cond` follows the pattern, before `=>`.
- Guard expression must be `bool`.
- Multiple arms with the same pattern are allowed if they have different guards. The first matching arm wins.
- Guards are arbitrary expressions and **do not contribute to exhaustiveness** — see "Exhaustiveness" below. For checkable numeric coverage, use range patterns rather than guards.

#### Tuple destructuring

```
let pair: (i32, bool) = (42, true)
pair match {
    (0, _) => { /* body */ }
    (n, true) => { /* body */ }
    (_, false) => { /* body */ }
}
```

#### Struct destructuring

```
point match {
    Point { x = 0, y = 0 } => { /* body */ }     // literal in field position
    Point { x, y } => { /* body */ }              // bind both fields
    Point { x, y = 0 } => { /* body */ }          // bind x, literal-match y
}
```

- Field-position rules: bare ident binds the field as a variable; `name = pattern` recurses into the pattern (literal or nested binding).
- Per Q17 (strict construction): destructuring patterns must mention every field of the struct. Partial destructuring uses `..`: `Point { x, .. }` binds `x`, ignores rest.

#### Range patterns

```
n match {
    ..0      => "negative",
    0        => "zero",
    1..=9    => "small positive",
    10..100  => "medium",
    100..    => "large",
}
```

- `a..b` — half-open: matches `x` where `a <= x < b`. Same shape as the existing range expression.
- `a..=b` — fully closed: matches `x` where `a <= x <= b`. New token `..=` (lexer change).
- `..b` — open-bottom half-open: matches `x` where `x < b`.
- `a..` — open-top: matches `x` where `x >= a`.
- `..` — fully open: matches anything. Same as `_` in this context. Disallowed in pattern position to avoid duplication with `_`.

**Allowed scrutinee types:** any totally-ordered scalar — `i8`/`i16`/`i32`/`i64`, `u8`/`u16`/`u32`/`u64`, `usize`/`isize`, `char`, `byte`. Floating-point types are forbidden in range patterns (NaN breaks total ordering). String range patterns are forbidden.

**Bound endpoints** must be compile-time constants of the scrutinee's type, or coercible to it (literal integer with a fitting target). Variable bounds are forbidden — `x..y` where `x`, `y` are runtime values is not a pattern (it would shadow variable patterns and break exhaustiveness reasoning). Use a guard (`n if n >= x and n < y =>`) for runtime ranges.

**Empty / inverted ranges** (`5..3`, `5..=4`) are a compile error E20XX, not a silently-never-matching arm.

**Disambiguation: `..` in patterns has two meanings, by position.**

| Position | Meaning |
|---|---|
| Inside a struct pattern, as a field-list element (`Point { x, .. }`) | Rest-fields marker: "ignore unmentioned fields." |
| As a value-position pattern over a scalar scrutinee (`..0`, `1..10`, `..`) | Range pattern over the scrutinee. |

These don't collide because struct patterns can only contain field-list elements (which are `name`, `name = pat`, or `..`), and scalar patterns can never appear inside `{ }`. The grammar disambiguates locally; no lookahead heuristics needed.

### Exhaustiveness

A `match` is **exhaustive** iff every value of the scrutinee's type is matched by at least one arm. The check runs after type-checking, before lowering.

**Per-type coverage rules:**

| Scrutinee type | Exhaustive when… |
|---|---|
| Enum (sum type) | Every variant covered (by name); each variant's payload sub-patterns are exhaustive in turn. |
| Tuple `(A, B, …)` | The Cartesian product of arms covers every position. Practical sufficient form: a wildcard or variable in each position. |
| Struct `Point { x, y }` | Every field is covered (FLang structs have known fields; wildcard or variable per field suffices). |
| Bool | Both `true` and `false` arms, or `_`/`else`. |
| Integer / `char` / `byte` | The set of literal arms and range patterns tiles the type's full domain. See "Bounded scalars are finite" below. |
| Floating-point | Only `_`/`else` exhausts (NaN, ±0, ±inf, every other bit pattern — not enumerable in the pattern grammar). |
| String | Only `_`/`else` exhausts. Strings are infinite; literal arms can never cover all values. |

**Bounded scalars are finite.** This is the user's instinct, made precise: every FLang integer type has a compile-time-known bit width and therefore a finite domain. `i32` has exactly 2³² values. Range patterns are how the user *expresses* coverage of that domain in a form the checker understands. The user's example becomes:

```
n match {
    ..0   => "negative",
    0     => "zero",
    1..   => "positive",
}
```

The checker sees three patterns over `i32`, computes their union as the union of disjoint intervals `[i32::MIN, 0) ∪ {0} ∪ [1, i32::MAX]`, observes that this equals the full `i32` domain, and accepts the match as exhaustive. **No `_` arm needed.** Same logic for `u8`, `char`, `byte`, etc. — bounded ordered scalars are tileable by ranges.

**Guards do not contribute to exhaustiveness.** This is the one rule that surprises users:

```
n match {
    Some(i) if i > 0  => ...
    Some(i) if i == 0 => ...
    Some(i) if i < 0  => ...    // E20XX: non-exhaustive — `Some(_)` may be unmatched
    None              => ...
}
```

The checker rejects this even though, as the user correctly observes, `i > 0 || i == 0 || i < 0` covers all integers. The reason is **the rule, not the example**: guards are arbitrary boolean expressions. The same syntactic position can hold `i > 0` or `is_prime(i)` or `external_lookup(i)`, and the checker has no way to distinguish "tautologically covers the domain" from "happens to cover the domain in this specific case" without a general theorem prover. The conservative rule — guards never count — is checkable and predictable.

The fix is to use range patterns, which *are* checkable:

```
n match {
    Some(1..)  => "positive",     // checker: [1, i32::MAX]
    Some(0)    => "zero",         // checker: {0}
    Some(..0)  => "negative",     // checker: [i32::MIN, 0)
    None       => ...,
}
```

This is exhaustive without any guard or wildcard. The rule line: **use guards for arbitrary conditions, ranges for checkable ones.** When you find yourself reaching for a guard to express a numeric region, reach for a range instead.

**Or-patterns** count as the union of their alternatives:

```
n match {
    1 | 2 | 3 => ...,    // covers {1, 2, 3}
    4..       => ...,
    ..1       => ...,
}                         // exhaustive over i32
```

**Reachability (unreachable-arm detection).** After each arm, the checker tracks the residual uncovered space. If a later arm's pattern is fully contained in the already-covered space, that arm is **unreachable** and emitted as a warning, not an error.

```
n match {
    ..10   => ...,
    5      => ...,    // warning: unreachable, covered by `..10`
    10..   => ...,
}
```

**Algorithm.** Maranget's "useful clauses" matrix algorithm, the standard reference implementation used by Rust, OCaml, and Scala. It handles all pattern forms in this RFC uniformly: variants, literals, ranges (as integer intervals), tuples (column-wise recursion), structs (column-wise per field), or-patterns (split into alternatives), wildcards, and guards (treated as not subtracting from the residual). On non-exhaustive matches it produces a **witness** — a concrete uncovered value like `Some(Point { x = 0, y = _ })` — for the error message.

**Error and warning codes** (registered in `docs/error-codes.md`):

- `E20XX` non-exhaustive match (with witness).
- `E20XX` empty / inverted range pattern.
- `E20XX` range pattern on disallowed type (float, string).
- `E20XX` or-pattern alternatives bind different names or types.
- `E20XX` range bound is not a compile-time constant.
- `W20XX` unreachable arm (covered by earlier arms).
- `W20XX` guard is statically `true` or `false`.

### `?.` lifts and flattens

`a?.b?.c` where each step may project to a plain field, a method call, or another `Option`:

- If `a: None` → result is `None`.
- If `a: Some(av)` → evaluate `av.b`. If the result is `Option(B)`, use it directly; if it's a plain `B`, wrap as `Some(B)`. Continue.
- Each subsequent `?.` follows the same rule.
- Final result type is `Option(typeof_final_step)`, never `Option(Option(...))`.

Concrete cases:

| Expression | Types | Result |
|---|---|---|
| `opt?.field` | `opt: Option(T)`, `T.field: U` | `Option(U)` |
| `opt?.method()` | `opt: Option(T)`, `T.method() U` | `Option(U)` |
| `opt?.field` | `opt: Option(T)`, `T.field: Option(U)` | `Option(U)` (flattened) |
| `a?.b?.c` | `a: Option(A)`, `A.b: Option(B)`, `B.c: C` | `Option(C)` |
| `a?.b?.c` | `a: Option(A)`, `A.b: Option(B)`, `B.c: Option(C)` | `Option(C)` (flattened) |

Sub-rules:

- Method dispatch resolves on the unwrapped `T`, not on `Option(T)`.
- Auto-deref through `op_deref` applies after the optional unwrap.
- Assignment through `?.` is forbidden: `opt?.field = v` is E20XX. Use `match` or explicit unwrap.
- `?.` only on `Option(T)`. `Result(T, E)?.field` is E20XX with a hint to use `.map(...)`.

## Migration

### Pattern grammar

- Or-patterns, guards, tuple destructuring, struct destructuring are additive. Existing patterns keep working.
- Tests: add coverage for each new pattern form. Important to lock exhaustiveness rules early.

### `?.` flattening

- Behavior change for code where the user *expected* `Option(Option(T))`. Audit current `?.` chains; the flattening rule may change inferred types.
- Likely safe for most code — nested-Option results are awkward and rare. But this is a real semantics change; flag it in the changelog.

## Implementation phases

1. **Or-patterns first.** Smallest, immediately useful. Type checker validates same-binding rule.
2. **Guards.** Parser + type checker. Cleanly orthogonal to exhaustiveness once the guards-don't-count rule is set.
3. **Tuple destructuring.** Trivial given tuples desugar to anonymous structs.
4. **Struct destructuring.** Largest grammar chunk; field-position pattern syntax.
5. **Range patterns.** New `..=` token (lexer change), pattern-position parser branch shared with the existing range expression code, range-aware coverage in the exhaustiveness checker.
6. **Maranget-style exhaustiveness checker.** Replace the current ad-hoc check with the matrix algorithm so the new pattern forms get correct coverage and witness reporting in one pass.
7. **`?.` flattening.** Modify the lowering of `?.` to inspect projected type and skip re-wrap when already `Option`. Extend to method-call form (`opt?.foo()`).

## Open questions

1. **`..` in tuple patterns.** Should `..` work in tuple patterns (`(a, b, ..)` for "first two of a longer tuple")? Distinct from range patterns: this is rest-fields-in-a-tuple, not a scalar range. Recommendation: yes, for consistency with struct patterns. Defer until first real need.
2. **`@` aliasing.** Originally planned to be replaced by smart casting. Now that smart casting is deferred, revisit whether `@` aliasing (`x @ Some(_)`) is needed in the meantime, or whether the bound-payload form is enough until the smart-casting RFC lands.
3. **Or-pattern with guards.** `A(x) | B(x) if x > 0 => { ... }` — guard sees `x` from either branch. Allowed? Recommendation: yes, since `x` has a single unified type across both alternatives.
4. **Range patterns over `usize`/`isize`.** Coverage analysis needs to know the bit width. On a 32-bit target, `0..2_000_000_000` followed by `2_000_000_000..` exhausts `usize`; on a 64-bit target, it doesn't. Recommendation: the checker treats `usize`/`isize` ranges as cross-platform-safe (require `_` to be exhaustive) unless the user opts into target-specific exhaustiveness. Decide before phase 6.
