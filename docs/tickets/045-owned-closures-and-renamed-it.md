---
type: language
created: 2026-11-15
linear: SH-97
relates: [RFC-005, RFC-014, RFC-028, RFC-033, RFC-037, RFC-039, RFC-099]
---

# RFC-045: Owned closures and a renamed `it`

## Summary

Two features that `select` and `concurrent` need, each usable alone:

1. `owned fn(P...) R` is the type of an owned closure: a lambda that keeps its frame in its closure
   object. Its locals live until its owner releases it, so inner closures may capture them and run
   after the lambda has returned. The owner releases it with `deinit`, which runs the defers of
   the lambda's own scope.
2. `#it(name)` on a parameter renames the parameter of an arrow-less lambda that fills it.

```flang
pub fn select(#it(on) body: owned fn(&Selector($R))) R

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

### Owned closures

```
owned fn(&Scope) R           // a function type, like `#foreign fn(...)`
```

`owned` before `fn` in type position makes the function type owning, as an `owned` field makes
its struct own what it points to (RFC-028). The value is non-copyable: it carries the duty to
release the closure, and a copy would carry it twice. Everything else follows from ownership as it
already works.

**The frame.** A lambda converted to `owned fn(...)` keeps its frame in its closure object: its
parameters, its locals in every block, and the closure objects of lambdas written inside it. The
closure object stays where any closure object lives (spec §7.3), in the frame of the function that
wrote the lambda; an `owned fn` value is a handle to it, so moving the value never moves the frame
that inner closures point into.

Which locals move into the frame is unobservable except through addresses, so the compiler moves
only the ones whose address is taken: captured by an inner lambda, borrowed with `&`, or a closure
object converted to a `fn` value. The rest stay C locals.

**Release.** `deinit(self: owned fn(...))` releases the closure. The lambda's own scope ends
there instead of at the body's return, so the defers written in that scope run in `deinit`, in
reverse order. Every other scope ends where it does today: an inner block (`if`, a `match` arm, a
loop body, a plain `{ }`) when the body leaves it, and an inner lambda when its own call ends. A
defer the body never reached, for example after an early `?`, does not run.

The owner decides when: whoever holds the value releases it, and one still live at an exit is
W2006, as for any non-copyable value. In parameter position `owned` implies `move`: a parameter
typed `owned fn(...)` takes ownership, and passes it on to another such parameter. A function that
only calls the closure takes a plain `fn(...)` and borrows it (below).

```flang
pub fn concurrent(#it(scope) body: owned fn(&Scope) $R) R {
    defer body.deinit()              // runs after the scope has joined its tasks
    ...
}
```

`concurrent`'s scope has a concrete lifetime: by the time it returns, its tasks have finished and
the body's defers have run.

**Calls and conversions.**

| From | To `owned fn(P) R` | Why |
| --- | --- | --- |
| A lambda written where one is expected | yes | compiled with its frame in the closure |
| `owned fn(P) R` value | yes, moved | non-copyable |
| `fn(P) R` value | no (new error) | its frame is on the stack |
| A named function | no (new error) | its frame is on the stack |
| `#foreign fn(P) R` | no | C code pointer, no environment |

The owner calls the closure as any callable (`body(&s)`). Where a `fn(P) R` is expected, an
`owned fn(P) R` converts by borrowing: the `{ code, env }` value runs the same code, and the owner
keeps the duty to release. The `deinit` entry sits in the closure object, so a function value
stays two words. A lambda that captures nothing still gets an environment: its frame.

`owned` is refused on a bound (`where F: owned fn(...)`, new error) and together with `#foreign`
(new error). A generic `$F` holds the closure object itself by value and may move it; an `owned fn`
value is a handle, so the object stays where it was made while inner closures point into it.

**The owner's obligations.** The closure object lives in the frame of the function that wrote the
lambda, so its owner must release it, and let nothing it created run on, before that frame ends:
for a lambda written as an argument, before the call returns. `select` and `concurrent` do so by
construction. RFC-099 `#stack` could check it later; until then it is the owner's documented
obligation, as it is for any `fn` value.

**Overlapping calls.** An owner runs the closure one call at a time: no recursion through it, no
two tasks running it. This is the owner's documented obligation, as it is for any `fn` value,
until a call-once function mode (Rust's `FnOnce`) can state it in the type. A sequential second
call starts with a fresh frame, as any call does. Why the mode is opt-in: one frame per closure
object is sound only under this rule, and `map`, `sort` and the iterator adapters call their
callbacks many times. Making every lambda sound would need a frame per call, allocated on every
call of any lambda whose locals an inner closure captures.

**Loop bindings.** Out of scope. A loop binding captured by an inner closure is one field, rebound
each iteration, as it is one stack slot today: `for url in urls { scope.launch { fetch(url) } }`
reads the last `url` in every task. Every FLang lambda captures by reference, as C++'s `[&]` does,
and C++ has the same hazard; Go had it until 1.22 fixed it with per-iteration variables that its GC
frees. The fix for FLang is a choice of capture mode per lambda (copy or reference), which applies
to every lambda and is decided separately (SH-98). An owned closure is a natural home for values
captured by move: its `deinit` would release them too.

**`#stack`.** RFC-099 forbids capturing a `#stack` binding, inside an owned closure or not, so the
two do not interact. `Scope` and `Selector` may become `#stack` when RFC-099 lands; that retires
the remaining task-escape check (RFC-005 D3).

### Worked examples

User functions (`load_config`, `serve`, `search`, ...) are placeholders. Each example says what
owned closures change; the ones whose body waits for its tasks before returning work today.

**Defers by scope.** Each `defer` runs when its own scope ends.

```flang
concurrent {
    let seen = list(8)
    defer seen.deinit()              // the lambda's scope: in `deinit`, after every task
    let log = open(log_path)
    defer log.close()                // the lambda's scope: in `deinit`, before `seen.deinit()`

    if verbose {
        let banner = open(banner_path)
        defer banner.close()         // the `if` block: when the body leaves the `if`
        log.copy_from(&banner)
    }

    for url in urls {
        defer log.write(url)         // the loop body: at the end of each pass
        check(url)
    }

    scope.launch {
        let page = fetch(url_a)
        defer page.deinit()          // the task's own lambda: when the task ends
        seen.push(page.title())
    }
}
```

Order: `banner.close()` when the `if` ends, `log.write(url)` once per pass, `page.deinit()` when the
task finishes, then `concurrent`, having joined that task, releases the body: `log.close()`, then
`seen.deinit()`. Then `concurrent` returns.

An inner block that defers a release must wait, within that block, for the work that uses the
value; deferring per loop pass without waiting for the tasks the pass started is wrong code, owned
closure or not.

**Tasks that outlive the body.** The body starts two servers and returns at once. Both read `cfg`,
and both push into `stats`, after the body has returned.

```flang
concurrent {
    let cfg = load_config(path)
    defer cfg.deinit()                   // in `deinit`, second
    let stats = list(2)
    defer stats.deinit()                 // in `deinit`, first
    scope.launch { stats.push(serve(&cfg, port_a)) }
    scope.launch { stats.push(serve(&cfg, port_b)) }
}
// 1. the body returns after the two `launch` calls
// 2. `concurrent` joins both tasks
// 3. `concurrent` releases the body: `stats.deinit()`, then `cfg.deinit()`
// 4. `concurrent` returns
```

Today the body returning while its tasks run panics (RFC-005 D1a), so it must end with
`scope.join()`.

**All: every result, in order.** There is no `all` function; awaiting each task in order is `all`.
The body waits for every task before it returns, so this works today unchanged.

```flang
const total = concurrent {
    const query = parse(term)            // read by both tasks
    const a = scope.spawn { mirror_a.count(&query) }
    const b = scope.spawn { mirror_b.count(&query) }
    a.await() + b.await()
}
```

**Race: the first result.** `race` returns the first task to finish, cancels the other and waits
for it before returning, so the tasks are done before the body returns: this works today too.
`race(f, g)` is the same over two functions it spawns itself, in a scope of its own.

```flang
const first = concurrent {
    const query = parse(term)
    let tasks = list(2)
    tasks.push(scope.spawn { mirror_a.search(&query) })
    tasks.push(scope.spawn { mirror_b.search(&query) })
    race(tasks)                          // the loser is cancelled and awaited before this returns
}

const query = parse(term)
const quick = race({ mirror_a.search(&query) }, { mirror_b.search(&query) })
```

**Select.** The body registers arms and returns; `select` then waits, and the winning handler runs
after the body has returned and reads its locals. `on.wait()` and its checks go.

```flang
// today: the handler must run before the body returns, so the body ends with `on.wait()`
const event = select {
    const tag = job_tag(id)
    let log = open(log_path)
    defer log.close()                    // at the body's end, after `on.wait()` ran the winner
    on(results.recv()) {
        log.write(tag)
        Event.Got(tag, it)
    }
    on(stop.recv()) { Event.Stop(tag) }
    on.wait()
}

// with owned closures
const event = select {
    const tag = job_tag(id)
    let log = open(log_path)
    defer log.close()                    // released by `select`, after the winning handler
    on(results.recv()) {
        log.write(tag)                   // runs after the body returned; `log` is still open
        Event.Got(tag, it)
    }
    on(stop.recv()) { Event.Stop(tag) }
}
// 1. the body registers both arms and returns; `log` stays open
// 2. `select` waits and runs the winning handler
// 3. `select` releases its body (`log.close()`) and returns the handler's value
```

**Select inside a scope.** Both lambdas are owned closures, each released by the function that
took it.

```flang
const page = concurrent {
    let results: Channel(Page) = channel(4)
    defer results.deinit()               // released by `concurrent`, after the crawler finished
    scope.launch { crawl(&results, start_url) }
    select {
        let note = string_builder(32)
        defer note.deinit()              // released by `select`, after the winning handler
        on(results.recv()) { it }        // the first page, or why there is none
        on(stop.recv()) {
            note.append("stopped")
            Err(RecvError.Closed)
        }
    }
}
// 1. `select`'s body returns; `select` waits, runs the winner, releases its body (`note`)
//    and returns that value
// 2. the `concurrent` body returns it; `concurrent` joins the crawler
// 3. `concurrent` releases its body (`results`) and returns
```

### `#it(name)` on a parameter

```
pub fn select(#it(on) body: owned fn(&Selector($R))) R
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

- `select(#it(on) body: owned fn(&Selector($R))) R`. After the body returns, `select` runs
  `finish` itself, then releases the body. `wait`, the "returned without calling `wait`" panic,
  and the "registered after `wait`" check go.
- `concurrent(#it(scope) body: owned fn(&Scope) $R)`, both overloads: the body is released
  after the scope joins. `run_scope` and `RootSlot.body` borrow it as `fn(&Scope) R`. The D1a
  check goes.
- `race(first, second)` and the tests rewrite to the new forms.

### Error codes

New entries in `docs/error-codes.md`: a `fn` value or named function where `owned fn` is expected;
`owned` on a bound; `owned` with `#foreign`. An unreleased owned closure is W2006, as any
non-copyable value. `#it` on a parameter that is not a callable of arity one is E2163, a malformed
parameter directive E1058 (shipped).

## Implementation

1. **Parser** (`flang_parser`). `owned` before `fn` in type position, read contextually as it is
   for fields; the function type node gains a flag.
2. **Checker** (`flang_typer`). Function type identity includes the flag; the conversions above;
   the type is non-copyable (RFC-028's derived bit) with a built-in `deinit(self: move ...)`.
   `LambdaFrame.captures` already records each capture's declaration; the checker marks which
   locals of an owned closure have their address taken.
3. **Lowering.** An owned closure's struct gains a by-value field per moved local, its `deinit`
   entry, and the reached-defer records. Reads and writes go through `self.field`; an inner closure
   captures `&self.field`. `deinit` runs the reached defers of the lambda's own scope.
4. **Promote**, then the stdlib changes above (seed rule).

Phases: `#it` shipped first (SH-99); owned closures are the rest.

## Decisions

### Decided (2026-11-15, by the owner)

| # | Decision |
| --- | --- |
| 1 | `#it(name)` as specified above. |
| 2 | The frame mode is an owned closure, `owned fn(P) R`: a new use of `owned`, not a directive. Replaces the earlier `#retained` spelling. |
| 3 | Captured loop bindings stay one slot; capture modes are a separate decision (SH-98). |
| 4 | An owned closure has a `deinit`; its owner calls it and decides when. `concurrent` and `select` release their body before they return, so their defers have run by then. |
| 5 | Overlapping calls are the owner's documented obligation; no run-time check. A call-once function mode may state it later. |
| 6 | A name from `#it` shadows an outer binding silently, as `it` does. |
| 7 | `concurrent` takes `#it(scope)`, as `select` takes `#it(on)`. |
| 8 | The owned closure's own scope ends in its `deinit`, so the defers written in it run there; a defer in an inner block or an inner lambda runs when that scope ends, as today. |
| 9 | A non-copyable local the body never released is W2006, as everywhere: every unintended loss of ownership warns, whether or not a fix exists yet. |
| 10 | `#it` ships first, ahead of the rest of this RFC. |
| 11 | In parameter position `owned` implies `move`: `body: owned fn(...)` takes ownership. A borrowing function takes a plain `fn(...)`. |
