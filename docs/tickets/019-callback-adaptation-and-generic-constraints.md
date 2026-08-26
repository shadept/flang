# 019 — Deferred designs from the lambda/stdlib-combinator milestone

Status: open design notes (2026-08-20). Successor to ticket 018's
"promotion" thread after the `$F` duck-typing decision. Each section is
an independent design; revisit once real stdlib-combinator usage has
accumulated.

## 1. Argument adaptation (the copy-vs-ref endgame)

Today NO adaptation exists at call sites: a value-mode callable
(`fn(T)`) only matches value invocation `f(x)`, a ref-mode callable
(`fn(&T)`) only matches `f(&x)`. The stdlib settled on value-mode
(§7.3), which is copy-free for read-only callbacks thanks to the
implicit-ref copy-on-write ABI (§3.2). Two candidate endgames, one of
which would let a single combinator body accept every callback shape:

- **Auto-ref** (`f(x)` adapts a place of type `T` to a `&T` param):
  uniform with UFCS receiver adaptation, priced like `Ref = 1` in
  overload scoring — but it hides a potential *mutation* channel at
  plain call sites, which cuts against "refs mean mutability intent".
- **Deref-copy** (`f(&x)` adapts `&T` to a `T` param by copying through
  the pointer): the benign direction — it hides only a copy. Pairs with
  combinators that pass `f(&e.key, &e.value)`-style refs; unannotated
  lambdas then infer *ref-mode* params, resurrecting the scalar
  ergonomics problem (`k.* > 2`, the `ref + int` pointer-arithmetic
  hazard).

Related: an `iter_ref` iterator family yielding `&K`/`&V` into
container storage (zero-copy for real, unlike refs to the loop-local
entry copy) — its mutation-visibility questions overlap with auto-ref.

**Preferred mechanism (user-proposed, 2026-08-20): deref coercion via
`op_deref` — promoted to its own implementation ticket, docs/tickets/020.** Instead of an ad-hoc `&T → T` rule, generalize the
EXISTING op_deref chain (already used for field access, UFCS receivers
— `TryUfcsOpDerefCall` / `deref_retry` — and `op_call` chaining) to
argument positions, with `&T`'s built-in deref as the primitive base
case. At an argument-unify failure, walk the arg's deref chain: param
`&Y` reachable → insert borrows (zero copy; `Rc(Big)` elements flow
into `fn(&Big)` callbacks); param `Y` by value → borrow + copy-through
(value-mode semantics, §3.2 COW). This is Rust's deref coercion —
opt-in per type, one semantic family, per-hop overload cost — not
C++'s open-ended conversion operators. Open sub-decisions: (a) whether
the *value* leg is allowed to copy owned types out of shared storage
(tension with the "explicit `.clone()`, no hidden costs" Rc design
stance; the borrow leg has no such problem), (b) the chain only peels —
`T → &T` auto-ref stays a separate rule with its own visibility
question, (c) `op_deref(&OwnedString) &String` needs a layout spike
before promising `&String → &str`-style view ergonomics. Estimated
~1.5–2 days per compiler by extending the receiver machinery.

## 2. Generic constraints (callable-shape bounds)

`filter(it: $I, f: $F)` accepts ANY `f`; a wrong-shaped callable only
errors deep inside `next` at instantiation. A constraint syntax
(`$F: fn(T) bool`-ish) would move the error to the call site and turn
`$F` slots into documented contracts — C++-concepts motivation, HM
implementation. Also subsumes the "no-context lambda in a `$F` slot"
diagnosis (the bound provides the context).

### 2.1 Direction: contracts over required functions

Contracts, not traits. Every protocol in the language is already
function-existence — `iter`/`next`, `op_eq`, `op_deref`, `op_call` — so a
bound names that requirement rather than introducing a new kind of entity.
Rust's `Fn`/`FnMut`/`FnOnce` split does not carry over: it encodes move
semantics and `&mut` aliasing, and FLang closures capture by value with
read-only captures (E2112), so every one of them is `Fn`. The split becomes
relevant only if `&local` capture-by-reference lands, and then as a property
of the capture mode.

Inline form, the primitive:

```
pub fn map(self: &List($T), f: $F, allocator: &Allocator? = null) List($U)
    where F: { op_call(T) U }
```

Named form, sugar over it — `Self` is the constrained type, and a `$`-bound
variable inside the body carries across lines:

```
contract Iterator($T) {
    iter(&Self) $S      // binds S
    next(&S) T?         // uses S, solves T
}

fn filter(it: $I, f: $F) $I
    where I: Iterator($T), F: { op_call(T) bool }
```

### 2.2 The two properties that constrain the implementation

**A contract must PIN, not merely check.** This is where FLang has to diverge
from C++ concepts, which are predicates evaluated at instantiation: they
improve diagnostics and feed nothing back into inference (C++ leans on `auto`
parameters getting their type from the call instead). Here the whole point is
the other direction — `where F: { op_call(T) U }` has to push `T` into the
lambda's parameter *before its body is checked*. A check-only contract leaves
the current failure exactly as it is: a lambda whose parameter type is decided
by whichever call in its body resolves first, and which stops inferring when
that call has more than one candidate (see the `$F` entry in
`docs/known-issues.md`).

**A contract variable is bound by unification, so input and output need no
separate syntax.** In `map`, `T` arrives known from `self` while `U` appears
nowhere but the return type — the caller never supplies it, `f` determines it.
Both are ordinary vars: whatever the contract does not otherwise bind, it
solves. That is an associated type in Rust terms, obtained without
associated-type machinery, and it is what lets the same syntax reach the
iterator adapters of §3/§5 — `$S` and `$T` above are solved, not supplied,
which is precisely the "cannot express that `A` IS `I`'s element type" gap.

At a use site the sigil picks which: `Iterator($T)` binds a fresh element
type, `Iterator(String)` requires it to be `String`. Same rule as `fn f(x: $T)
T`, where `$T` introduces and bare `T` refers back — no new scoping concept.

### 2.3 A shape a contract would describe (not a correctness gap)

`std.iter`'s adapters cannot say what they yield: `FilterIter(I, F)` names the
inner iterator and the predicate, and the element type is "whatever `I`
yields", which no signature can state. `next(self: &FilterIter($I, $F)) $T?`
leaves it to inference, which resolves it correctly on its own - a free return
variable is a working feature, not a defect.

`I: Iterator($T)` would let the type be named rather than reconstructed. That
is an expressiveness argument, not a correctness one.

### 2.4 Side effect worth having

`scheme_specificity` calls itself "a tuned heuristic standing in for a real
constraint system", and the spec's worked example is `any(&Dict($K,$V), $F)`
beating `any($I, $F)`. With bounds, a constrained `$F` is genuinely more
specific than an unconstrained one, so ranking can become a subset test over
bounds instead of a count of concrete type constructors.

### 2.5 Unresolved

- `Self` as the name of the constrained type inside a contract body, or
  something else.
- Whether `where` clauses are order-free (unification says yes) or required to
  read in dependency order.
- Whether `f: Fn(T, U)` in parameter position is worth having as sugar for
  `f: $F where F: Fn(T, U)`. It reads better, but it hides that `F` is the
  type and `Fn(T, U)` is a bound on it.
- Whether contracts are discharged only at the call site or re-verified at
  instantiation.
- What an unsatisfied contract reports, and against which of several
  candidate overloads.
- Whether a contract may require a function that is itself generic.
- Migration: every `$F`/`$I` slot in `std.list` / `std.iter` / `std.sort`
  gains a bound, and that changes overload ranking (2.3) — so it wants Gate A
  and the stage fixpoint green, not just the harness.
- **2.3 can invert the lazy-fallback pick.** The eager/lazy overload pair
  (`docs/spec.md` §7.3) relies on specificity TYING between `fallback: T` and
  `fallback: $F`, so that the value form wins on quantifier count. Once a bound
  counts toward specificity, `$F where F: { op_call() T }` is more specific
  than a bare `T`, and the lazy form starts winning — which silently invokes a
  fallback that should have been returned, in exactly the case where `T` is
  itself callable. Decide deliberately whether bounds outrank an unconstrained
  concrete parameter, and treat
  `tests/harness/option/unwrap_or_overload_pick.f` as the guard.

## 3. Higher-kinded type parameters

`ZipLongestIter = struct(I, J, A, B)` cannot express that `A` IS `I`'s
element type; `struct(I(A), J(B))` (type-constructor parameters) would.
Not an inference problem — HM handles it — the open question is
syntax. Same shape recurs for any adapter that must name both an
iterator and its element.

## 4. Overloaded / generic function names as first-class values

`a.map(deinit)` — an overloaded name in a `$F` slot has no context to
pick an overload; today it's an error (the reference ICEs, see
known-issues "Overloaded Functions Can't Be Used As First-Class
Values"). The agreed direction: defer the pick to instantiation — bind
the slot to an unresolved overload-set, resolve against the concrete
argument types at the instantiation's internal call site (the same
machinery instantiation-time lambda-param pinning already uses). Wanted
by the user as a near-term follow-up: "a.map(deinit) is very natural to
write".

## 5. Iterator `flat_map`

The adapter must store an inner iterator whose type is only knowable by
calling `f` — constructor-time inference can't name it. Needs either
deferred/instantiation-time struct-field typing or the constraint
system (2). `List.flat_map` covers the materialized case meanwhile.

## 6. Template-eager-check boundaries (reference compiler)

Generic bodies are checked eagerly at template-declaration time, so
operations that need a *resolved* type fail on `$F`-call results even
though every instantiation would succeed:

- `!f(x)` — "No operator `!`" (workaround: `let ok: bool = f(x)`),
- `op_cmp(key(a), key(b))` — ambiguous overload on metavars
  (workaround: compare with `<`),
- tuple-field access `p.0` on a metavar-typed lambda param.

Deferring these checks to instantiation (as the self-hosted compiler
does wholesale) would remove the workarounds sprinkled through
`std.list` / `std.iter` / `std.sort`.
