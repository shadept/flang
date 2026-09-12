---
status: draft
type: language
created: 2026-09-01
relates: [RFC-028, RFC-026, RFC-020]
---

# RFC-030: Reference-form operator dispatch

## Summary

A non-copyable type cannot implement `==` today, for two reasons that share one
code path:

1. **Operator dispatch has no reference form.** `a op b` resolves `op_eq`,
   `op_cmp`, `op_add` and friends against the operand types exactly. An operator
   declared over `&T` is never found, and the comparison reports E2017.
2. **Operator operands skip the ownership check.** `==` on a non-copyable type
   copies both operands silently, where the same function called by name is
   E2124 twice.

Closing the second makes the first mandatory: once operands are checked, a
by-value operator over a non-copyable type is E2124 at every use, and an
operator over `&T` is the only spelling left.

A third change rides with them, because it is decided by the same code:
**`&T == &T` compares the pointees**, matching what `hash(&T)` already does.
Identity becomes a named call, `addr_eq`.

## Motivation

### The ownership hole

```flang
type Handle = struct {
    owned fd: i32
}

fn op_eq(a: Handle, b: Handle) bool {
    return a.fd == b.fd
}

fn main() i32 {
    let h = Handle { fd = 3 }
    let g = Handle { fd = 3 }

    let viaop   = h == g        // accepted
    let viacall = op_eq(h, g)   // E2124 twice

    return 0i32
}
```

```
error[E2124]: `h` cannot be copied here - write `move h`; `Handle` is not copyable: field `fd` is `owned`
  --> line 14
error[E2124]: `g` cannot be copied here - write `move g`; `Handle` is not copyable: field `fd` is `owned`
  --> line 14
```

Both diagnostics land on the spelled-out call; the operator form is silent.
`==` is the one place a non-copyable value crosses a by-value parameter
boundary unchecked, so every comparison of an owning struct mints two untracked
owners of the same resource. The hole is live: `FileHandle.fd` is annotated
(RFC-028 step 6). Nothing in tree declares an operator over an annotated type
yet, which is the only reason it has not fired.

### No reference form

The fix for the hole is to reject the by-value operator. That leaves the
non-copyable type with no way to declare `==` at all, because an
`op_eq(&T, &T)` is unreachable from `a == b`. RFC-028 step 1 records this as
the blocker on `OwnedString.op_eq`, and RFC-031 depends on it for every
`Dict(OwnedString, V)` in tree.

## Design

### The resolution ladder

`comparison()` in `lib/flang_typer/src/checker.f` resolves a comparison by
walking a ladder. Two rungs are added; everything else is unchanged.

```
0. both operands are references         -> peel to the pointee type       (new)
1. primitives and unresolved operands   -> builtin compare
2. payload-less enum ==/!=              -> builtin tag compare
3. op_eq(T, T)                          -> value form
4. op_eq(&T, &T)                        -> reference form                 (new)
5. derived: op_ne negated, then op_cmp  -> value form, then reference form
```

Rung 4 is a fallback, never a substitute. `String`'s by-value `op_eq` is a
16-byte copy and stays on rung 3; primitives never reach the ladder. A type
opts into the reference form by declaring it, which is what a non-copyable type
must do:

```flang
pub fn op_eq(a: &$T, b: &$T) bool
```

Rung 0 peels only when both operands are references. A mixed `&T == T` keeps
whatever behaviour it has today.

### Operands are ownership-checked

Operator operands route through the same check as call arguments. On rung 3 a
non-copyable operand is E2124, which is correct and is what forces rung 4 to
exist. The check reads `is_ref_form` off the recorded pick: a rung-4 operand is
addressed, not copied, so it is exempt.

### References compare as their pointee

Today `&T == &T` is address equality: the ladder is entered only when both
operands are nominal, so a reference operand takes the builtin compare before
any pick runs. After this ticket `&T == &T` is `T == T`. The ladder always runs
on the pointee type, and a reference operand simply arrives with its address in
hand.

This is the rule `hash` already follows. `hash(val: &$T)` is `hash(val.*)`, so
today a `Dict(&K, V)` hashes by pointee and compares by address. After this
ticket the two agree.

Identity is a named call:

```flang
pub fn addr_eq(a: &$T, b: &$T) bool {
    return (a as usize) == (b as usize)
}
```

```flang
let p: &Pt = &a
let q: &Pt = &b        // equal fields, distinct object

p == q             // op_eq(Pt, Pt) on the pointees  -> true
addr_eq(p, q)      // identity                       -> false
p.* == q.*         // the same as p == q
```

For a non-copyable `T`, `p == q` reaches rung 4 with `p` and `q` themselves as
the arguments. `lower_base_address` on `p.*` is `p`, so the reference form
costs nothing on a reference operand: no copy, no load.

## Implementation

### What already exists

`ResolvedOperator` carries `is_ref_form`
(`lib/flang_typer/src/inference_results.f`). It means "pass the operand by
address": lowering selects `lower_base_address` instead of `lower_adapted`
(`lib/flang_driver/src/lower.f`, the index-operator call path). The flag is
already set for `op_set_index`, `op_index_ref` and the `op_index` reference
pick. `comparison()` hardcodes `is_ref_form = false` at each of its three
record sites and never attempts a reference pick.

The addressing machinery is in place and proven. The work is two new rungs plus
the pieces the index path never needed.

### What the index path does not cover

1. **Both operands.** An index operator addresses `params[0]` only; the index
   argument stays value-form. A comparison addresses both sides. `is_ref_form`
   stays a single bool: the reference form addresses both operands or neither,
   since a mixed `op_eq(&T, T)` has no motivating use.
2. **Rvalue operands.** `a == make()` has no address to take. Index receivers
   are always place expressions, so this path has never needed a temporary.
   Either materialise one, or reject the shape with the constraint E2125
   already applies to a `move` of an rvalue.
3. **The derived rungs.** `op_ne` by negation and `op_cmp` for all six
   comparisons each need a reference variant, or a non-copyable type gets `==`
   but not `<`.
4. **Blanket overloads.** Adding adaptation to `operator_pick_2` alone is not
   enough. A flipped operand still unifies with a blanket operator's type
   variable, so the retry picks the blanket over the concrete overload the
   retry exists to reach. The reference pick runs as a distinct rung with its
   own candidate set, not as a re-run of the value pick with adapted argument
   types. No blanket operator exists in tree today; the test for this is the
   only place the shadowing can be observed.

### Existing code affected by the reference rule

Three sites rely on address equality and would change meaning silently, all in
`String`:

| site | today | under the new rule |
| --- | --- | --- |
| `core/string.f` `op_eq`, `a.ptr == b.ptr` fast path | address | compares first bytes; returns true on matching lengths |
| `core/string.f` `op_cmp`, same fast path | address | same |
| `std/string.f` `OwnedString.deinit`, `self.ptr == (0usize as &u8)` | null check | dereferences null |

They move to `addr_eq` first, as a pure refactor, before the semantics flip.

No generic site is affected. The only pointer-element container in tree,
`List(&Expr)` in `lower.f`, never compares elements, and every `== null` site
is `Option` equality.

## Sequencing

1. **`addr_eq` in `core`; the three `String` sites move to it.** Pure refactor:
   `addr_eq` is what `==` does on a reference today. Lands alone.
2. **Route operator operands through the ownership check.** Reveals the hole as
   E2124 on every by-value operator over a non-copyable type. Nothing in tree
   regresses: `FileHandle` declares no operators.
3. **Rung 0 and rung 4 in `comparison()`.** Peel reference operands to the
   pointee; add the reference pick with its own candidate set. One commit: rung
   0 without rung 4 makes `p == q` over a non-copyable `T` E2124 with no legal
   spelling.
4. **Address both operands in lowering**, including the rvalue decision.
5. **Extend the derived rungs** so `op_ne` and `op_cmp` reach the reference
   form.
6. **Convert `OwnedString.op_eq` to `&`**, closing RFC-028 step 1's last
   leftover.
7. **`docs/spec.md` 8.4** gains the reference rule and `addr_eq`.

Steps 2 and 3 are separable commits but ship in the same release: between them,
a by-value operator on a non-copyable type is an error with no legal
replacement.

## Tests

All under `tests/harness/operators/`.

**In tree now under `SKIP`, flipping to pass with the ticket:**

- `ref_eq_is_pointee` (EXIT 11): `p == q` over a copyable `T` with `op_eq(T, T)`
  compares the pointees; `addr_eq` is identity.
- `ref_form_op_eq` (EXIT 7): a non-copyable `T` declaring only `op_eq(&T, &T)`.
  `op_eq(&h, &g)` called directly, `h == g` through rung 4, and `p == q` on two
  references all reach it; `addr_eq` on distinct objects is false.

**Landing with the ticket:**

- `addr_eq_is_identity` (EXIT 1): same object true, equal-valued distinct
  objects false, null-cast pointer against null true. Lands with step 1 and
  passes today.
- `op_eq_by_value_on_noncopyable` (COMPILE-ERROR E2124): `h == g` with a
  by-value `op_eq`. Accepted today; rejected after step 2, matching the
  spelled-out call.
- `op_ne_from_ref_form` (EXIT 1): `h != g` negates a reference-form `op_eq`.
- `op_cmp_ref_form_derives_all` (EXIT 1): `<`, `>`, `<=`, `>=` from
  `op_cmp(&T, &T)`.
- `ref_form_over_blanket` (EXIT 1): a concrete `op_eq(&T, &T)` wins over a
  generic `op_eq($A, $A)`.
- `ref_form_rvalue_operand`: `h == make()` against a reference-form operator.
  Expectation follows the rvalue decision.
- `string_eq_still_value_form` (EXIT 1): `String == String` still picks rung 3,
  pinned by declaring both forms and asserting which one ran.

## Out of scope

- Reference forms for arithmetic operators. The ladder admits them, but nothing
  in tree needs one; comparison is what RFC-028 blocks on.
- `op_index` reference resolution, which already works.
- Structural auto-derivation of `op_eq`.

## Related documents

- `docs/known-issues.md`: "Operator Dispatch Has No Reference Form" and
  "Operator Operands Skip the Ownership Check" are both closed by this ticket.
- `docs/spec.md` 8.4: the reference rule and `addr_eq` are spec changes, not
  only ticket text.
