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
