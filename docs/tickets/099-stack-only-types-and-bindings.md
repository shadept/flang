# RFC-025: `#stack` types and stack-only bindings

**Type:** Language feature
**Status:** Draft
**Depends on:** RFC-014 (closures capture by value)
**Related:** RFC-005 (async runtime), RFC-012 (`Owned(T)` transfer tracking)

## Summary

Two things, one mechanism:

1. `#stack` on a struct declaration makes every value of that type stack-only:
   guaranteed to live in the current call frame, never storable anywhere that
   outlives it.
2. `#stack` on a single binding does the same to one variable of an ordinary
   type, on demand, without changing the type.

This is FLang's version of C#'s `ref struct` plus `scoped`, minus the parts that
only exist because of the CLR.

## Motivation

Some values are pointers into a frame that is about to disappear. A slice into a
local array. A handle to a computation whose bookkeeping lives in the enclosing
block. A cursor into a builder. If any of these are stored in a `List`, returned,
or captured by a lambda, the pointer outlives its referent and the program reads
freed memory. Today FLang has no way to say "this must not escape", so the rule
lives in a comment and the compiler cannot help.

C# hit the same wall with `Span<T>`:

> The `ref` modifier indicates that the *non_record_struct_declaration* declares
> a type whose instances are allocated on the execution stack. [...] instances
> [...] shall not be copied out of its safe-context.
> (C# spec §16.2.3)

The type-level form is the right default for types that are *always* frame-bound.
The binding-level form covers the far more common case: an ordinary type used in
one place where escape would be wrong.

---

# Part 1: external, how to use it

## 1.1 `#stack` on a type

```flang
type Cursor = #stack struct { _buf: &u8[], _pos: usize }
```

`#stack` sits where `#foreign` and `#simd` sit today (`docs/syntax.md`, Structs).
It is part of the type's identity: every `Cursor` anywhere is stack-only, and
callers cannot opt out.

## 1.2 `#stack` on a binding

```flang
const buf = make_buffer()          // ordinary Buffer, may be stored anywhere
#stack const view = buf.as_view()  // this binding only: cannot escape
```

The type of `view` is unchanged. What changes is the lifetime the checker
assigns to that binding: it narrows to the enclosing block, so any attempt to
store, return, or capture it fails.

This is the same trick as C#'s `scoped`, generalised. C# describes it as:

> The `scoped` modifier restricts the *ref-safe-to-escape* or *safe-to-escape*
> lifetime [...] to the current method. By adding the `scoped` modifier, you
> assert that your code doesn't extend the lifetime of the variable.

with two differences we make deliberately:

- C# allows `scoped` on a local of arbitrary type only when that local is a
  reference variable. We allow `#stack` on any binding, because the point is to
  express intent, and a narrower lifetime is never unsound.
- C# narrows to the current *method*. We narrow to the enclosing *block*, which
  is stricter and matches where `defer` and scoped cleanup already operate.

`#stack` is also valid on a parameter:

```flang
fn render(#stack ctx: &Context) { ... }
```

meaning the callee promises not to retain it, which in turn lets the caller pass
something frame-bound.

## 1.3 The rules

A stack-only value, whether by type or by binding:

| Rule | C# counterpart |
|---|---|
| Local binding only. Never a module-level `const`. | stack allocation only |
| Cannot be a field of a non-stack-only struct. Stack-only structs may hold stack-only fields. | "can't declare a `ref struct` as the type of a field in a class or a non-`ref struct`" |
| Cannot be stored in a container, unless that container is itself a `#stack` binding. | C# is stricter: arrays are always heap, so `ref struct` elements are banned outright. |
| Cannot be captured by a lambda. | "can't capture a `ref struct` variable in a lambda expression or a local function" |
| Cannot be a generic type argument, unless the resulting value is a `#stack` binding. `#stack let h = list(0, &a)` may hold handles; an unannotated `list` may not. | C# requires an explicit `where T : allows ref struct` opt-in on the type parameter. Our opt-in is at the use site instead. |
| Cannot be returned. No exceptions. | C# allows a return when the value's safe-context is wide enough. See §2.4 for why we do not. |

Note one C# restriction we do **not** inherit: C# forbids a `ref struct` from
being live across an `await`, because the async state machine hoists locals into
a heap object. FLang coroutines are stackful (RFC-005 §3.1): the frame stays put
across a suspension, so a stack-only value remains valid and no restriction is
needed.

## 1.4 Errors

Continuing the E2XXX semantic block (current max E2120):

| Code | Meaning |
|---|---|
| E2121 | stack-only value used as a field of a non-stack-only type |
| E2122 | stack-only value stored in a container that is not a `#stack` binding |
| E2123 | stack-only value captured by a lambda |
| E2124 | stack-only type used as a generic type argument outside a `#stack` binding |
| E2125 | stack-only value returned, or assigned to a binding outside its block |
| E2126 | `#stack` applied where it has no meaning (module-level `const`, type position) |

---

# Part 2: internal, how the checker enforces it

## 2.1 There is no lifetime analysis

Stated up front, because the obvious way to build this is wrong for FLang. The
checker does **not** compute a lifetime for every variable. There is no lattice,
no dataflow, no borrow checker, and no notion of what any ordinary value's scope
is. An earlier draft of this RFC imported C#'s four-value safe-context model and
arrived at exactly that, which is a cost the whole program pays for a guarantee
two constructs need.

Two questions replace it, both answerable locally:

1. **Is this type stack-only?** A property of the type, fixed at its declaration.
2. **Is this binding marked `#stack`?** A property of one `let`, `const`, or
   parameter, visible on the line where it appears.

Nothing else is inspected. Code with no stack-only types and no `#stack`
annotations is not analysed at all.

## 2.2 The type-level check

For a stack-only type `S`, reject these positions. Each is a question about a
type appearing somewhere, not about a value flowing somewhere:

| Position | Error |
|---|---|
| field of a non-stack-only struct | E2121 |
| element or type argument of a container that is not a `#stack` binding | E2122, E2124 |
| captured by a lambda | E2123 |
| return type | E2125 |
| module-level `const` | E2126 |

This is one flag bit per type, tested where types are already being checked. No
expression walk, no ordering, no fixpoint.

## 2.3 The binding-level check

For a binding marked `#stack`, walk its enclosing block once and reject any use
that moves the value out of it:

- assignment to a binding declared outside the block,
- `return`,
- capture by a lambda,
- passing as an argument to a parameter not itself marked `#stack`.

The scope of the walk is one block. Nothing interprocedural, no call graph. The
last rule is the trust boundary and the reason it stays local: a callee's
signature states whether it retains, so the caller never has to look inside it.

Cost is proportional to the number of annotated bindings, which is zero in code
that does not use the feature.

## 2.4 What this gives up

C#'s four-value lattice exists to answer one question we are not asking: when may
a `Span<T>` derived from a parameter be *returned*? Supporting that requires
knowing the lifetime of ordinary values, which is the expensive part. We forbid
returning outright (§1.3), and the apparatus disappears with it.

Three consequences, all acceptable:

- No `fn narrow(h: Deferred(T)) Deferred(T)` returning a derived handle. Handles
  are produced by `spawn` and consumed by `join`; nothing in between needs to
  return one.
- The compiler cannot prove a `#stack` binding's memory really is in the frame.
  It does not need to, see §2.5.
- A dangling `&local` is still writable. That was true before this RFC and is
  unchanged by it. `#stack` is not a memory-safety feature bolted on late; it is
  a scoped obligation with a narrow job.

## 2.5 Why not tracking provenance is still sound

The allocator chain is the case that looks like it needs the machinery:

```flang
let backing = [0u8; 8192]
let fba     = fixed_buffer_allocator(backing)
#stack const scratch = fba.allocator()
#stack let   handles = list(0, &scratch)
```

The checker has no idea that `handles`'s buffer lives inside `backing`. It cannot
see through `vtable.alloc`, and under §2.1 it is not even tracking `backing`.

**It does not need to.** The guarantee comes from the container, not from the
memory. `handles` is a `#stack` binding, so it cannot leave the block, so nothing
stored in it can leave either. That holds whatever allocator produced the bytes.
Write `list(0, &global_allocator)` under a `#stack` binding and it is still
sound, merely wasteful.

This is the load-bearing observation for the whole design: **escape is a property
of the binding, which the programmer states and the compiler checks locally.
Provenance is a property of the memory, which would have to be inferred.** Only
the first is needed.

The `#stack` on `scratch` is not required for handle safety. It buys
documentation, plus one genuine check: the allocator cannot be returned out of
the block where its buffer lives. That is worth having on its own, and the stdlib
already asks for it in a comment: "This allocator should not outlive the provided
buffer" (`stdlib/std/allocator.f`).

## 2.6 User-defined types

Nothing above is stdlib-specific, and nothing is inferred. A hand-written
`MyPool`, `RingBuffer`, or `Cursor` over a stack array gets the same treatment as
`FixedBufferAllocatorState`, because the compiler treats both as what they are:
ordinary types. If you want the escape guarantee on one, you annotate the
binding.

The deliberate omission is inference. The compiler does *not* decide a struct is
frame-bound because it happens to hold a slice. That would mean adding a field to
a struct could break a caller three modules away, with an error pointing at
neither. Annotation keeps the claim and the check in the same place.

The honest consequence: **the guarantee is only as strong as the annotations.**
`#stack` is a claim you make and the compiler verifies, not a property it
discovers. That is the trade this RFC picks, and it is the same trade `const`
already makes.

### What it still does not catch

Escape is not consumption. A handle dropped on the floor inside the block leaks
a result and possibly a task, and every rule in Part 2 is happy about it. That is
a separate must-consume obligation (§3.5).

## 2.7 Cost

A flag on types, plus a single-block walk for each annotated binding. No
interprocedural analysis, no fixpoint, no per-variable state. A file with no
stack-only types and no `#stack` markers costs nothing measurable.

## 2.8 Codegen

Nothing. A `#stack` struct lowers to an ordinary C99 struct in an automatic
variable, and a `#stack` binding lowers exactly as it would without the marker.
There is no tag, no runtime check, no representation change. The entire feature
is a front-end restriction: if the program type-checks, the generated C is what
you would have written by hand.

---

# Part 3: worked example, deferred values

A value whose computation has not finished yet goes by many names (promise,
future, task, task handle). They are the same concept, and picking the name and
the API is RFC-005's job, not this one. What matters here is *why* such a handle
wants `#stack`.

The handle is a pointer into bookkeeping owned by the block that created it. If
the handle escapes, the bookkeeping is gone before the read. So:

```flang
type Deferred = #stack struct(T) { _slot: &Slot(T) }
```

`concurrent` owns a frame-local slab of slots. Every `Deferred` produced inside
it is measured against that scope. Escape is E2125.

`parallel_sum` is the textbook example because it has to work three ways: split
once, split recursively, and fan out to N workers. If the rules only support the
first, they are not rules, they are a demo.

### 3.1 Split once

```flang
fn parallel_sum(data: i64[]) i64 {
    const mid = data.len / 2
    return concurrent {
        const a = spawn sum_slice(data[0..mid])
        const b = spawn sum_slice(data[mid..data.len])
        join(a) + join(b)
    }
}

fn sum_slice(s: i64[]) i64 {
    let total = 0
    for x in s { total += x }
    return total
}
```

The slices borrow `data`, which is a parameter and therefore caller-context. The
handles are declaration-block. The block yields `i64`, which is caller-context
and escapes freely. Nothing to reject.

### 3.2 Recursion

```flang
const SEQUENTIAL_CUTOFF: usize = 4096

fn parallel_sum(data: i64[]) i64 {
    if data.len <= SEQUENTIAL_CUTOFF { return sum_slice(data) }

    const mid = data.len / 2
    return concurrent {
        const a = spawn parallel_sum(data[0..mid])
        const b = spawn parallel_sum(data[mid..data.len])
        join(a) + join(b)
    }
}
```

The only change is that the spawned function is the same one. This composes for
free, and the reason is worth stating explicitly, because it is the property that
makes the whole design usable:

**A handle never crosses a frame boundary, at any depth.** Each recursive call
opens its own `concurrent` block on its own frame, with its own slab. Every
handle is joined before its block yields, and what the block yields is a plain
`i64`. The child's slices point into `data`, which the parent still owns, and the
parent cannot leave the block with tasks outstanding. So the escape checker has
nothing to say about recursion at all: depth does not appear in the analysis.

The cutoff is not part of the safety story, it is a performance guard. Without
it, a 1M-element input spawns roughly 500k tasks and scheduling dominates. With
it, the tree stops at a chunk size where the sequential loop is faster than the
handoff. Pick it by measurement, not by taste.

### 3.3 Iterative fan-out

Splitting in two is a poor fit when you know you have N workers. The direct
translation wants a collection of handles, which is where the rules earn their
keep. Handles are declaration-block; a `List` is caller-context; pushing one into
the other is E2122.

The idiomatic answer is not to hold the handles at all:

```flang
fn parallel_sum_chunked(data: i64[], workers: usize) i64 {
    const chunk = (data.len + workers - 1) / workers
    return concurrent {
        for i in 0..workers {
            const lo = i * chunk
            const hi = if lo + chunk < data.len { lo + chunk } else { data.len }
            spawn sum_slice(data[lo..hi])
        }
        sum_slice(join_all())
    }
}
```

`join_all()` waits for every task spawned in the block and yields the results as
an `i64[]` slice into the block's own slab. Two things fall out of that:

- The reduction is the same `sum_slice` from §3.1. Fan out, then fold the
  results with the function you already have.
- The returned slice is an ordinary type carrying a frame-bound lifetime. It is
  the on-demand case from §1.2, arising on its own: `join_all()` has a
  safe-context of declaration-block, so the binding is stack-only whether or not
  anyone writes `#stack`. Returning it is E2125. Keeping the results means
  copying them out, `join_all().to_list(&alloc)`.

Writing the marker by hand is allowed and reads as documentation:

```flang
#stack const results = join_all()
const total = sum_slice(results)
```

### 3.4 When you do need the handles

Heterogeneous tasks, where each result is used differently, still need
individual handles. With a fan-out known at compile time, a fixed array works,
because a `#stack` binding gives the array the same lifetime as its elements:

```flang
concurrent {
    #stack const hs = [spawn sum_slice(a), spawn sum_slice(b), spawn sum_slice(c)]
    join(hs[0]) + join(hs[1]) + join(hs[2])
}
```

This is the refinement noted in §1.3. The blanket C# rule ("never an array
element") exists because every C# array is on the heap. FLang's `[T; N]` is
inline, and the `#stack` marker on the binding is what makes it admissible: the
array cannot leave the block, so neither can what is in it.

When the count is data driven, the same reasoning extends to a growable
container:

```flang
concurrent {
    let backing = [0u8; 8192]
    let fba     = fixed_buffer_allocator(backing)
    #stack const scratch = fba.allocator()
    #stack let   handles = list(0, &scratch)

    for job in queue {
        if job.ready { handles.push(spawn run(job)) }
    }

    let total = 0
    for &h in handles { total += join(h.*) }
    total
}
```

`Dict` works identically for results wanted by key.

Note what the compiler does and does not check here (§2.5). It does not verify
that the list's buffer really lives in `backing`; it cannot see through
`vtable.alloc` and does not try. The `#stack` on `handles` is what makes this
sound, and it would be sound with any allocator. The fixed buffer is an
allocation choice, not a safety mechanism, and the `#stack` on `scratch` is
there to catch a different bug: returning an allocator whose buffer has died.
The stdlib asks for exactly that today, in a comment: "This allocator should not
outlive the provided buffer" (`stdlib/std/allocator.f`).

What this does not extend to is an *unbounded* fan-out with every handle
retained, since an unannotated `List` rejects handles (E2122). That is the
correct answer rather than a gap: unbounded concurrency holding unbounded
handles is a resource bug before it is a lifetime bug. Bound the buffer, stop
retaining handles, or bound the workers instead of the work. The full survey is
in [`docs/notes/concurrency-patterns.md`](../notes/concurrency-patterns.md).

### 3.5 What `#stack` still does not give you

It stops a handle outliving its frame. It says nothing about the handle being
*used*. A deferred value that is never joined is a silently lost result, and
`join_all` quietly papers over it. That is a separate must-consume obligation;
`Owned(T)` (RFC-012) already tracks exactly this kind of state, and whichever
type RFC-005 lands on should reuse it.

---

## Resolved decisions

**`defer` ordering.** `defer` is the last thing that runs before a block is
exited, from any exit path. At a `concurrent` block that means: outstanding joins
complete, then the block's value is produced, then defers run in LIFO order,
then control leaves. A defer can therefore safely read task results. No special
case for `concurrent`; this is just what `defer` already means.

**`concurrent` is an expression.** It yields the value of its final expression,
the same as `if` and `match`. This removes the need to declare a variable outside
the block and assign into it, which would have been the one construct guaranteed
to make handles escape.

**Relationship to RFC-005.** No conflict to resolve. RFC-005 owns the deferred
value type and its API surface. This RFC owns the escape analysis, and is a
precursor: whatever that type ends up being called, it needs `#stack` to be
sound.

## Deliberately not copied from C#

| C# feature | Why not |
|---|---|
| Boxing prohibition | FLang has no boxing. |
| `readonly ref struct`, `ref` / `ref readonly` fields | A four-way modifier matrix for one bit of information. `const` already covers immutability. |
| Interface implementation | We have no traits. `#interface` generates a vtable, which a stack-only type must not enter. |
| `allows ref struct` constraint | The opt-in moves to the use site: a `#stack` binding admits stack-only type arguments (§1.3). No constraint kind, no generic-body analysis. |
| Restriction across suspension points | Stackful coroutines make it unnecessary (§1.3). |
| The safe-context lattice, and lifetime analysis generally | The reason for it is returning derived references. We forbid returning instead (§2.4). |

## Open questions

1. Should `#stack` be inferable? Proposal: no, and not only for cost. Inference
   would mean adding a field to a struct silently changes what distant callers
   may do with it, with an error pointing at neither. The claim and the check
   belong on the same line.
2. Does `#stack` on a parameter belong in the function's public signature for
   overload resolution and ABI purposes, or is it callee-local? C# treats
   `scoped` as part of the signature. It has to be part of ours too, since §2.3
   depends on reading it from the callee's signature rather than its body.
   Confirm, then write it down.
3. A frame-bound container has nothing to release, since `fixed_dealloc` is a
   no-op and the buffer dies with the frame. RFC-016 (auto-deinit) should
   recognise that, or every one of these patterns emits a dead call.
4. `join_all()` (§3.3) is assumed, not specified. It needs a home in RFC-005
   along with the deferred type itself. Open sub-questions: what it does with a
   task that failed, and whether results come back in spawn order (they must,
   for the fold in §3.3 to be deterministic).
5. §2.3 rejects passing a `#stack` binding to a parameter that is not marked
   `#stack`. That is the conservative choice and it means annotating a chain of
   helpers to thread one handle down. Worth checking against real code before
   committing: if it is too noisy, the alternative is to allow the pass and
   accept that a callee could stash it, which gives up the guarantee.

## Sources

- [C# language specification, Structs](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/language-specification/structs) — §16.2.3 `ref` modifier, §16.8.15 safe context constraint.
- [`ref` structure types (C# reference)](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/builtin-types/ref-struct) — the restriction list.
- [Method parameters and modifiers (C# reference)](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/keywords/method-parameters) — safe-context and ref-safe-context definitions.
- [Declaration statements (C# reference)](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/statements/declarations) — `scoped`, and where it is implicit.
- [Constraints on type parameters (C#)](https://learn.microsoft.com/en-us/dotnet/csharp/programming-guide/generics/constraints-on-type-parameters) — `allows ref struct`.

Background notes on the C# feature in isolation: [`docs/notes/csharp-ref-struct.md`](../notes/csharp-ref-struct.md).
