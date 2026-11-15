---
type: language
created: 2026-11-15
linear: SH-97
relates: [RFC-005, RFC-014, RFC-033, RFC-037, RFC-039, RFC-099]
---

# RFC-045: Retained lambdas and a renamed `it`

## Summary

Two directives that `select` and `concurrent` need, each usable alone:

1. `#retained fn(P...) R` is a function type whose lambda keeps its frame in its closure object.
   The lambda's locals then live for the whole call that received it, so inner closures may
   capture them and run after the lambda has returned.
2. `#it(name)` on a parameter renames the parameter of an arrow-less lambda that fills it.

```flang
pub fn select(#it(on) body: #retained fn(&Selector($R))) R

const which = select {
    const bonus = 1234
    on(a.recv()) { bonus + it }      // runs after the body returned, reads `bonus`
    on(b.recv()) { 0 }
}
```

No `on =>`, no closing `on.wait()`, and no run-time check that the body called it.

## Motivation

Captures are by reference (RFC-033) and a lambda's locals live in its stack frame. A closure made
inside a lambda that captures those locals dangles once the lambda returns. Two stdlib functions
hand their lambda a handle that creates such closures:

- **`concurrent { s => ... }`**: a task capturing a body local outlives the body if the body
  returns first. RFC-005 D1a panics at run time when a body returns while a task it started
  still runs. That check is sound only on one worker.
- **`select { on => ... }`**: a handler capturing a body local runs after `wait`. The body must
  end with `on.wait()` (SH-90), so the handler runs while the body's frame is still alive; a body
  that returns without calling it panics.

Both are run-time rules for a lifetime the compiler can provide. The fix must not touch other
lambdas: `map`, `filter`, `fold` and every other callback keep their frames on the stack.

`select`'s body has one parameter, the selector, and names it every time (`select { on => ... }`).
`it` would read badly there, because handlers inside the body are arrow-less lambdas whose own
`it` is the received value. A callee that names the parameter once removes the ceremony from
every call.

## Design

### `#retained` function types

```
#retained fn(&Scope) R       // a function type, like `#foreign fn(...)`
```

`#retained` sits where `#foreign` sits in type position. It is part of the type, so a retained
value survives being forwarded and stored: `concurrent` hands its body to `run_scope` and stores
it in `RootSlot`, and both declare `#retained fn(&Scope) R`.

**The callee's promise.** The consumer chooses the mode: a function annotates its parameter
`#retained` because of what it does with the closure, as `#foreign` is chosen by what the callee
hands it to. A function that takes a `#retained fn` promises two things: it never
runs the value twice at once (no recursion through it, no two tasks running it), and nothing the
body creates outlives the function's own call. `select` and `concurrent` keep both by
construction. `map`, `sort` and the iterator adapters cannot keep the first, which is why the mode
is opt-in: one frame per closure object is sound only under that promise. Making every lambda
sound would need a frame per call, allocated on every call of any lambda whose locals an inner
closure captures.

**The frame.** A lambda converted to `#retained fn(...)` keeps its frame in its closure object:
its parameters, its locals in every block, and the closure objects of lambdas written inside it.
The closure object lives where any closure object lives (spec §7.3): in the frame of the function
that wrote the lambda. For a lambda written as an argument, everything the lambda's frame holds
outlives every inner closure the callee runs before it returns.

Which locals move is unobservable except through addresses, so the compiler moves only the ones
whose address is taken: captured by an inner lambda, borrowed with `&`, or a closure object
converted to a `fn` value. The rest stay C locals.

**Conversions.**

| From | To `#retained fn(P) R` | Why |
| --- | --- | --- |
| A lambda written where one is expected | yes | compiled with its frame in the closure |
| `#retained fn(P) R` value | yes | same type |
| `fn(P) R` value | no (new error) | its frame is on the stack |
| A named function | no (new error) | its frame is on the stack |
| `#foreign fn(P) R` | no | C code pointer, no environment |

A `#retained fn(P) R` converts to `fn(P) R`: the call is the same `{ code, env }` call, and where
the frame lives is the code's business. A lambda that captures nothing still gets an environment:
its frame.

`#retained` is refused on a bound (`where F: #retained fn(...)`, new error) and together with
`#foreign` (new error). A generic `$F` holds the closure object by value and may move it; a `fn`
value only borrows it, so the object stays where it was made while inner closures point into it.

**Deinit.** A retained closure has a deinit, which the caller runs once the call that received
it returns. Every `defer` the body reached runs there, in reverse order, instead of at the end of
its block. A body can then own what its tasks share:

```flang
concurrent {
    let seen = list(8)
    defer seen.deinit()               // in the deinit: after every task has finished
    scope.launch { seen.push(fetch(url_a)) }
    scope.launch { seen.push(fetch(url_b)) }
}
```

A `defer` the body never reached, for example after an early `?`, does not run.

**Overlapping calls.** The closure carries an in-call flag; a call entering while it is set
panics. A sequential second call starts with a fresh frame, as any call does.

**Loop bindings.** Out of scope. A loop binding captured by an inner closure is one field, rebound
each iteration, as it is one stack slot today: `for url in urls { scope.launch { fetch(url) } }` reads
the last `url` in every task. Every FLang lambda captures by reference, as C++'s `[&]` does, and
C++ has the same hazard; Go had it until 1.22 fixed it with per-iteration variables that its GC
frees. The fix for FLang is a choice of capture mode per lambda (copy or reference), which applies
to every lambda and is decided separately (SH-98). RFC-005 §9 keeps the risk until then.

**`#stack`.** RFC-099 forbids capturing a `#stack` binding, inside a retained lambda or not, so
the two do not interact. `Scope` and `Selector` may become `#stack` when RFC-099 lands; that
retires the remaining task-escape check (RFC-005 D3), not anything here.

### `#it(name)` on a parameter

```
pub fn select(#it(on) body: #retained fn(&Selector($R))) R
```

- A directive on a function parameter, written before its name. Parameters take no directives
  today; this is the first.
- An arrow-less lambda that fills the parameter names its one parameter `name` instead of `it`.
  `it` is then not bound in that lambda, so an outer `it` stays visible, and an inner arrow-less
  lambda binds its own `it` without shadowing `name`.
- A lambda with `=>` names its parameters itself; the directive has no effect on it.
- `name` shadows an outer binding of the same name, as `it` does.
- The parameter's type must be a callable of arity one: a function type, or a type parameter
  bounded by one. Any other arity is a new error. `name` is an identifier, not `_` and not a
  keyword.
- Overloads may differ in it; a lambda argument is checked after its call resolves (spec §7.3),
  so the chosen overload's parameter decides.

### What changes in the stdlib

- `select(#it(on) body: #retained fn(&Selector($R))) R`. After the body returns, `select` runs
  `finish` itself. `wait`, the "returned without calling `wait`" panic, and the "registered after
  `wait`" check go.
- `concurrent(#it(scope) body: #retained fn(&Scope) $R)`, both overloads; `run_scope` and
  `RootSlot.body` take `#retained fn(&Scope) R`. The D1a check goes.
- `race(first, second)` and the tests rewrite to the new forms.

### Error codes

New entries in `docs/error-codes.md`: a `fn` value or named function where `#retained fn` is
expected; `#retained` on a bound; `#retained` with `#foreign`; `#it` on a parameter that is not a
callable of arity one; `#it` with an invalid name. A run-time panic message for an overlapping
call.

## Implementation

1. **Parser** (`flang_parser`). `#retained` before `fn` in type position, beside `#foreign`
   (the function type node gains a flag). Directives before a parameter; `FunctionParam` gains
   the `#it` name.
2. **Checker** (`flang_typer`). Function type identity includes the flag; the conversions above.
   Arrow-less parameter naming moves from the projector (which binds `it` today) to the point the
   lambda is checked against the parameter it fills. `LambdaFrame.captures` already records each
   capture's declaration; the checker marks which locals of a retained lambda have their address
   taken.
3. **Lowering.** A retained lambda's closure struct gains a by-value field per moved local, the
   in-call flag, and the reached-defer records. Reads and writes go through `self.field`; an inner
   closure captures `&self.field`. The caller calls the synthesized deinit after the call.
4. **Promote**, then the stdlib changes above (seed rule).

Phases: `#it` is small and lands first; `#retained` is the rest.

## Decisions

### Decided (2026-11-15, by the owner)

| # | Decision |
| --- | --- |
| 1 | `#it(name)` as specified above. |
| 2 | The frame mode is spelled `#retained`. |
| 3 | Captured loop bindings stay one slot; capture modes are a separate decision (SH-98). |
| 4 | A retained closure has a deinit, run by the caller after the call; the body's defers run there. |
| 9 | A non-copyable local the body never released is W2006, as everywhere: every unintended loss of ownership warns, whether or not a fix exists yet. |
| 10 | `#it` ships first, ahead of the rest of this RFC. |
| 7 | `concurrent` takes `#it(scope)`, as `select` takes `#it(on)`. |

### Open

| # | Question | Options | Recommendation |
| --- | --- | --- | --- |
| 5 | Overlapping calls | in-call flag that panics; callee's documented obligation only | flag: one byte, one store, catches Phase 4 misuse |
| 6 | `#it` shadowing an outer binding | silent, as `it`; a warning | silent, for one rule across `it` and `#it` |
| 8 | A `defer` inside a loop of a retained body | runs in the deinit, once per iteration reached (needs a record per iteration); keeps its block timing | keeps its block timing: a per-iteration record is an allocation per iteration, and loop-local values are already one slot (decision 3) |
