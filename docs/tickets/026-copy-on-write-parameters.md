# RFC-026: Copy-on-write parameters - elide the shadow when nothing writes or escapes

**Type:** Compiler mechanism (lowering) + language rule (casts)
**Status:** Landed 2026-08-30 - all four parts, with three deviations recorded below
**Depends on:** None
**Relates to:** spec §3.2 (function arguments), §5.4 (casting), §3.6 (safety model)

## Summary

`lower.f` copies every aggregate parameter into a fresh slot unconditionally. Spec
§3.2 already promises the copy appears only on first write. Close the gap.

1. **Copy on write or escape, not on entry.** A by-value aggregate parameter is
   bound to the caller's pointer. The shadow appears only if the body writes to
   it or lets its address escape.
2. **`&` means intent, not mechanism.** `fn f(self: S)` and `fn f(self: &S)`
   emit the same code for a read-only body. `&` in a signature communicates
   intent to mutate or retain; everything is already passed by pointer.
3. **Escape analysis is intraprocedural.** Taint the parameter slot, propagate
   through derived pointers, classify uses. Callee signatures are the whole
   interprocedural input; no callee body is ever read.
4. **`usize as &T` becomes a hard error.** Fabricating a reference from an
   integer is what lets a laundered parameter address come back and mutate the
   caller. `&T as usize` warns and stays available.
5. **The guarantee is testable from inside the language.** Address identity
   stays observable, address mutation does not.

## Motivation

`is_none` on `Option(ComptimeCtx)` compiles to a 48-byte memcpy in order to read
a 4-byte tag:

```c
int8_t std__option__is_0none__...(void* v0) {
    _Alignas(8) unsigned char __slot1[48];
    void* v1 = (void*)__slot1;
    memcpy(v1, v0, (size_t)((uint64_t)48));
    int32_t v6; memcpy(&v6, v1, sizeof(int32_t));
    ...
```

`ComptimeCtx` is two `String`s and two `bool`s, so `Option(ComptimeCtx)` is 48
bytes: an `i32` tag at 0, payload at 8. The body only reads the tag.

The site is [lower.f:1391](../../lib/flang_driver/src/lower.f), unconditional for
every aggregate parameter:

```
cur.memcpy(slot, param_ops[i], Operand.IntConst(lay.size as i64))
env.bind_aggregate(decl.params[i].name, slot, pty.*)
```

This is a conformance bug, not a missing optimization. The file header at line 18
already states the intent, implemented as always-copy.

The cost is not only the memcpy. `Option` is monomorphized, so there is one of
these per instantiation, and the shadow forces the value to have an address.

## Design

### 1. The rule

Copy a by-value aggregate parameter only when the body:

- writes to it, or
- lets its address escape.

Escape means: passed as an argument to a `&` parameter, stored into anything
outliving the expression, or returned. A local `&p` used only for reads is not an
escape, and neither is a `p.field` read.

`&` used purely for read-only sharing stays valid and costs nothing, except when
the argument is itself a by-value parameter. There the escape rule fires. The
hatch is to declare the outer parameter `&` too, which states the same intent one
level up.

### 2. The analysis

Intraprocedural, one worklist pass over the function's FIR. Taint the parameter's
slot, propagate to anything derived from it (gep, pointer copies through locals),
classify the uses:

| Use of a tainted operand | Result |
|---|---|
| load from it | allowed |
| store to it | write, copy |
| call argument, stored, returned | escape, copy |
| anything unrecognized | copy |

Aliases must be tracked, so this is not a syntactic check on `&p`:

```
fn f(s: S) {
    let x = &s
    const y = x
    bar(y)          // escape
}
```

The pass never reads a callee body. `bar`'s signature decides, which is what
keeps it cheap.

### 3. Casts

The analysis is defeated by laundering an address through an integer:

```
let x = &s
let y = x as usize
smuggle(y as &S)    // taint lost, mutation reaches the caller
```

Close the return trip, not the outbound one:

| Cast | Rule |
|---|---|
| `usize as &T` | hard error, E2122 |
| `&T as usize` | warning, W2004, suppressible |
| `&T as &U` | unchanged, vtables and allocator internals need it |

Address *identity* stays observable (compare two `usize`s), address *mutation*
does not. The split is deliberate: it keeps the elision visible from inside the
language, so the guarantee is enforceable rather than aspirational.

Since `&T as usize` survives, neither pointer ordering nor a null primitive is a
prerequisite for this work.

**One stdlib site breaks**, its `as &u8` half now being an error:
`allocator.f:492,507`, `(base as usize + header_size + aligned_offset) as &u8`
becomes `base + (header_size + aligned_offset)`. `&T + usize` already works, see
`core/hash.f:50` and `core/string.f:123`.

**Sites that keep working and take a suppression**, all legitimate:

| Site | Use |
|---|---|
| `std/string.f:451` | null check; references are not nullable, a raw ref still needs the escape hatch |
| `std/allocator.f:375,377` | containment check on `memory.ptr` / `state.buffer.ptr` |
| `std/allocator.f:283` | pointer identity assertion in a test |
| `std/process.f:207,213` | argv addresses pushed into a `List(usize)` |

### 4. `#allow(CODE)`

There is no general suppression syntax today: shadowing uses a `_` prefix, unused
uses the `-W` flag, both ad-hoc. W2004 needs one.

```
#allow(W2004)
let mem_start = memory.ptr as usize
```

Before a declaration it suppresses within that declaration:

```
#allow(W2004)
fn is_null(p: &u8) bool { return p as usize == 0 }
```

Several codes as `#allow(W2004, W1002)`.

Rust's shape (`#[allow(lint)]`), not TypeScript's (`// @ts-ignore`): `#`
directives already exist and parse (§7.6), and unknown ones already warn (W2003),
so this is an incremental parse change. The comment form would make comments
semantic, and they are trivia today in the parser, the formatter and the LSP.

Deferred until a call site wants them: file-level allow, `deny`/`warn` level
control, and a lint for an `#allow` that suppressed nothing.

## Testing

`memcpy_count()` already exists in `lower.f` and three tests assert on it, so the
FIR side is an assertion change, not new machinery.

**Three existing tests flip**, they currently pin the always-copy behaviour:

| Test | Body | Change |
|---|---|---|
| `lower.f:7711` | `fn get_x(p: Pt) i32 { return p.x }` | 1 -> 0, title inverts |
| `lower.f:7748` | `fn f(p: Pt) i32 { let q = p  q.x = 9  return p.x }` | 2 -> 1, comment loses the spill half |
| `lower.f:7952` | enum parameter match | gains `memcpy_count(f) == 0` |

7748's real subject, that the `let` copy is what protects `p`, survives and gets
sharper.

**New FIR cases:** escape into a `&` parameter asserts 1; a non-escaping local
`&p` asserts 0; an escape reached through an alias chain asserts 1; a write
asserts 1.

**New harness tests**, behavioural so they score under either compiler. They need
`#allow(W2004)`:

```
fn inner(p: &S) usize { return p as usize }
fn outer(self: S) usize { return inner(&self) }

outer(s) != (&s as usize)   // the trigger, green today, must stay green
```

Plus the plain semantics tests, which pass today and must keep passing: callee
mutation of a by-value parameter is invisible to the caller, including through an
escape.

The `reads(s) == (&s as usize)` half was planned here and dropped - see "§3's
observable guarantee did not survive the whitelist" below.

## Documentation

- §3.2 gains the escape clause. The current sentence, "on first write to a
  parameter, the compiler inserts a shadow copy", is what produced the
  always-copy implementation. It also states the guarantee positively.
- §5.4 gains the three cast directions.
- `docs/syntax.md` gains the `S` vs `&S` style note, next to the existing
  FLang-vs-Rust disambiguation.
- `docs/error-codes.md` gains E2122 and W2004.

## What actually landed

Five things differ from the design above.

**The analysis runs on the AST, before the prologue is emitted.**
`lib/flang_driver/src/param_escape.f` answers "does this body write through the parameter, or let
its address outlive the expression it appears in" from the checked AST, and `lower_function_body`
consults it while binding parameters. A read-only aggregate parameter is bound straight to the
caller's pointer, so it never has bytes of its own at any point in the pipeline.

Deciding before emitting, rather than emitting a copy and deleting it afterwards, is what makes the
by-pointer parameter a real borrow instead of an optimized-away copy. It is also the seam RFC-028
needs: a moved argument becomes one more reason not to emit the copy, not a second mechanism laid
over the top.

An earlier revision ran the analysis on FIR as a post-pass (`param_elision.f`, now deleted). FIR
made classification total for free - twelve instruction forms cover every construct, because
desugars, operators, UFCS receivers and template expansions all arrive as loads, stores, geps and
calls - but it can only ever delete a copy that was already emitted.

**The AST classification is a whitelist, and deliberately narrower.** Only a bare identifier read,
a field read with no recorded `op_deref` hops, a whole-value call argument, a `match` on the
parameter (arm bindings alias it and join the tracked name set) and `return p` keep the caller's
pointer. Everything else that so much as mentions the parameter forces the copy, including every
implicit `&` the checker records: user operators, `op_index`, `op_try`, the iterator protocol and
UFCS receivers. Missing a case costs a memcpy, never correctness. The `Expr`, `Stmt` and `Pattern`
matches are total - no `_` arm - so a new AST variant is an E2031 build error here rather than a
silent miscompile.

**§3's observable guarantee did not survive the whitelist.** §3 closes the `usize as &T` return trip
so that address *identity* stays observable and "the guarantee is enforceable rather than
aspirational", and §Testing turns that into `reads(s) == (&s as usize)`. `&self` is an `AddressOf`,
which the whitelist refuses, so a body that reads its own address still gets the shadow - and the
only way to observe elision from inside the language is the very form that suppresses it. Elision is
therefore pinned at the FIR level instead, by the `memcpy_count` tests in `lower.f`; the harness test
`ownership/param_copy_on_write.f` keeps the behavioural half (a write never reaches the caller, an
escaped address is distinct storage) and asserts nothing about address identity.

E2122 still earns its keep: it is what makes a future `&p as <integer>` whitelist entry sound, since
an address that leaves as an integer provably cannot return as a writable reference. Whether to add
that entry is deferred - it widens the whitelist, and the default branch is always the safe answer.

The escape table is implemented as written, which makes `let x = &p` a copy: storing a tainted
address is an escape whatever is done with it later. §2's prose sentence "a local `&p` used only
for reads is not an escape" contradicts its own table and was not implemented. Tracking taint
through a local slot is an alias analysis through memory; the table's answer is sound and needs no
worklist.

**E2122 needed a null exemption.** "One stdlib site breaks" was 161. The dominant pattern is
`0usize as &T`, which is how a null reference is spelled while the language has no null primitive -
`List`, `Dict`, `StringBuilder` and `Deque` all null their buffer on teardown. A literal `0` is
therefore exempt: a zero can never carry the address of a live value, so it cannot defeat the
analysis. The `let zero: usize = 0` spelling of the same idiom was normalized to the literal across
the stdlib and the parser. Two sites were genuine laundering and took the pointer-arithmetic fix -
`allocator.f`'s two, plus `projector.f`'s `slice_str`, which the design did not know about.

A null primitive would retire the exemption. Until one exists, `0 as &T` is load-bearing.

**`#allow` is declaration-level only.** The statement-level form of §4 is not implemented; naming
the code on the enclosing declaration covers every site in the tree. Several codes per directive
works as designed.

## Measured

Compiler compiling itself, on darwin-arm64, with the analysis disabled (every parameter shadowed)
against the AST analysis as it stands:

| | no elision | AST analysis |
|---|---|---|
| `memcpy` calls in the emitted C | 100780 | 98778 |
| stage C | 20193571 B | 19952638 B |

2002 parameter copies removed. `is_none` on an `Option(Slice(u8))` reads the tag straight out of the
caller's pointer with no `_Alignas` slot, which was the motivating case:

```c
int8_t std__option__is_0none__core__option__Option_core__slice__Slice_u8__ret_bool(void* v0) {
    int8_t v2 = 0;
    int32_t v5; memcpy(&v5, v0, sizeof(int32_t));
```

Stage binary size is not comparable between those two columns: disabling the analysis also makes
the whole walk dead code, which the compiler strips.

The FIR post-pass measured 100071 -> 98557 on win-x64 on an older tree, so its 1514 is not directly
comparable to the 2002 above - different platform, and this branch also carries RFC-027. Measured
the same way on the same tree, the AST whitelist is expected to elide *fewer* copies than the FIR
pass did: it refuses every form it has not been taught, where FIR saw through desugars for free.
That is the trade accepted for deciding before emitting.

## Separate bug

A payload-less `None` arm copies the whole scrutinee:

```c
m_arm9:;
    _Alignas(8) unsigned char __slot13[48];
    memcpy(v13, v1, (size_t)((uint64_t)48));
```

`None` has no payload and the arm binds nothing, so the copy has no reader.
Related to fb665d4, which did not cover the no-binding case.

RESOLVED. It does not reproduce: `v1` in that snippet was the parameter shadow, so the arm was
copying out of a slot that no longer exists. A payload-less arm over a local scrutinee emits no copy
either.

## Implementation order

Any. `#allow` lands last on purpose: W2004 is then a real warning to test the
suppression against rather than a synthetic one. Until it lands, the four
legitimate stdlib sites warn.

No open questions.
