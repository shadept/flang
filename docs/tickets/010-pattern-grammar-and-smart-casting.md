# RFC-010: Pattern Grammar Extensions, Smart Casting, and `?.` Flattening

**Type:** Language semantics + type checker
**Status:** Proposed
**Depends on:** RFC-007 (Option as enum), RFC-006 §5 (match arm syntax)

## Summary

Three connected improvements to pattern matching and optional chaining:

1. **Pattern grammar extensions:** or-patterns (`A | B`), guard clauses (`pat if cond`), tuple destructuring (`(a, b)`), struct destructuring (`Point { x, y }`).
2. **Kotlin-style smart casting:** inside a match arm or after an `is`-style narrowing, the matched value is automatically narrowed to the variant's payload type — no manual rebinding required.
3. **`?.` lifts and flattens:** chained optional access never produces nested `Option(Option(...))`. `a?.b?.c` always yields `Option(typeof c)`, even if `b` itself returns `Option`.

## Motivation

### Pattern grammar

Today's pattern grammar is minimal: unit variant, payload binding, qualified, nested, wildcard, literal, `else`. Real code shows the gaps:

- **Or-patterns:** matching multiple variants with the same body requires duplicating the arm body. Common for "any error variant collapses to `false`."
- **Guards:** matching a variant *and* a condition requires nested `if` inside the arm. Verbose.
- **Tuple/struct destructuring:** when matching on a `(i32, bool)` or a `Point`, manually accessing `.0`/`.1` or `.x`/`.y` inside the arm is noise.

### Smart casting

After `opt match { Some(v) => { ... } }`, the user has access to `v` (the bound payload). They lose access to `opt` as `Some(T)` — `opt` retains its original `Option(T)` type even though we know it's `Some` inside this branch. Kotlin's smart casting fills the gap: inside the arm, `opt` is narrowed to `Some(T)`, and methods/fields on the variant are reachable directly.

This composes with pattern grammar: in `Move(x, y) if x > 0 => { ... }`, both the `Move` variant binding and the guard's truth narrow the matched value within the body.

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
- Exhaustiveness checking: a guarded arm doesn't count as covering the variant. The user must provide an unguarded fallback or `else`.

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
- Per Q17 (strict construction): destructuring patterns must mention every field of the struct. Partial destructuring uses `..`: `Point { x, .. }` binds `x`, ignores rest. (This is the one place `..` makes sense in patterns; doesn't generalize to range patterns yet.)

### Smart casting

When the type checker proves a value's narrowed type inside a branch, references to that value see the narrowed type:

```
opt match {
    Some(v) => {
        // opt: Some(T) here (narrowed)
        // v: T (bound payload, same as opt.value if there were such accessor)
    }
    None => {
        // opt: None here (narrowed; no payload to access)
    }
}
```

Narrowing applies in:

- Match arm bodies (per pattern).
- The truthy branch of `if expr is Variant { ... }` once an `is`-style operator lands (parked separately).
- Guard-clause bodies: `Some(x) if x > 0 => { ... }` — `opt` narrowed to `Some` inside both the guard expression and the body.

Narrowing rules:

- Only applies to values whose type is a sum type (enum) when the pattern fixes the variant.
- Only applies if the narrowed name is the original matched expression (or an alias of it). Doesn't propagate through arbitrary expressions.
- Doesn't combine across or-patterns: `Some(x) | Other(x)` doesn't narrow to a single variant — the bound `x` is the only unified view.

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

### Smart casting

- Additive. Code that doesn't rely on narrowing keeps working.
- Examples that manually rebind (`Some(v) => { use(v) }`) still work. New code can use `Some(_) => { /* use opt narrowed */ }` style.

### `?.` flattening

- Behavior change for code where the user *expected* `Option(Option(T))`. Audit current `?.` chains; the flattening rule may change inferred types.
- Likely safe for most code — nested-Option results are awkward and rare. But this is a real semantics change; flag it in the changelog.

## Implementation phases

1. **Or-patterns first.** Smallest, immediately useful. Type checker validates same-binding rule.
2. **Guards.** Parser + type checker. Exhaustiveness checking interaction is the tricky part.
3. **Tuple destructuring.** Trivial given tuples desugar to anonymous structs.
4. **Struct destructuring.** Largest implementation chunk; field-position pattern grammar.
5. **Smart casting.** Hooks into the existing type-narrowing pipeline (which doesn't fully exist yet — this is its first real use case).
6. **`?.` flattening.** Modify the lowering of `?.` to inspect projected type and skip re-wrap when already `Option`.

## Open questions

1. **`..` in patterns.** Used for "ignore remaining struct fields." Should it also work in tuple patterns (`(a, b, ..)` for "first two of a longer tuple")? Recommendation: yes, for consistency. Defer until first real need.
2. **Range patterns.** `0..10 => { ... }` matching any int in range. Per Q12, deferred. Revisit when bytewise/character matching shows up in real code.
3. **`@` aliasing.** Per Q12, replaced by smart casting. Confirm there's no lingering need — if smart casting handles all cases that `@` would, `@` stays out of the grammar permanently.
4. **Smart-casting through method calls.** If a method returns a narrowing predicate (e.g., `opt.is_some()` returning `bool`), should the type checker narrow `opt` in the truthy branch? Kotlin does this via "contracts." Probably defer to a future RFC; for now, narrowing only happens through pattern matches and `is`-style operators.
5. **Or-pattern with guards.** `A(x) | B(x) if x > 0 => { ... }` — guard sees `x` from either branch. Allowed? Recommendation: yes, since `x` has a single unified type across both alternatives.
