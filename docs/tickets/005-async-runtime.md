# RFC-005: Async / Coroutines

**Type:** Feature (runtime + stdlib; minimal compiler changes)
**Status:** Proposed
**Depends on:** None (self-host planned; this RFC locks the design now, implementation lands after self-host)

## Summary

Add concurrency to FLang as a **stackful M:N coroutine runtime** with **explicit `Future(T)` at the type level**, composed via `.await()` and combinators (`race`, `all`, `timeout`, `map`, `then`, `or_else`). Key properties:

| Property | Choice |
|---|---|
| Coroutine model | Stackful (own stack, swapped by runtime) |
| Scheduler | M:N work-stealing across worker threads |
| Function coloring | **None** at signature level — no `async fn` |
| Suspension visibility | `.await()` at every call site that yields; plain calls don't |
| Composition | `Future(T)` is a first-class value; combinators are stdlib functions |
| Concurrency primitive | `spawn(&alloc, args..., fn) Future(T)` — **no captures**, args explicit |
| Cross-coroutine transport | `Channel(T)` with `.send().await()`, `.recv().await()`, `.close()` |
| Allocator binding | Coroutine-local context slot; `or_global()` inside a coroutine resolves to spawn-supplied allocator |
| User-extensible context | Typed-key slots, parent-chain, inherited on `spawn` |
| Top-level | `main` is the root coroutine; runtime always live |
| Cancellation | Every `Future(T)` is cancellable; mechanism [OPEN] |

**Justification.** FLang already commits to explicit allocators (§4.1) and deterministic cleanup (§4.1 rule 4). Stackful coroutines let suspension be transparent at the runtime level while the type system keeps deferred values visible as `Future(T)` — you see *where* you suspend without being forced to color every function that might transitively do so. Work-stealing gives parallelism on multi-core without the developer managing thread pools. The coroutine-local allocator context makes the same stdlib code work in both sync and async contexts without API changes. The whole stack is stdlib + runtime (C); the compiler is essentially unchanged.

**What this RFC is not.** It is not a full async I/O library catalog. It defines the primitives and the semantic contract; individual async-aware I/O wrappers in `std.io`, `std.net`, etc. are follow-up work.

---

## Motivation

FLang needs concurrency to be a viable systems language. The bar:

1. **Compose I/O** — fetch N URLs in parallel, race with a timeout, cancel losers.
2. **Share stdlib between sync and async** — `Dict`, `StringBuilder`, `list(T)` shouldn't know or care which context they run in.
3. **Deterministic resources** — no GC, no surprise background lifetimes. `defer`, allocators, `deinit` still work.
4. **Implementable without a compile-time async transform** — we don't want to build a state-machine lowering pass in both the current C# compiler and the self-hosted one.
5. **Stay FLang-grain** — UFCS methods, named args, explicit allocators, no function coloring.

### Alternatives considered

| Model | Rejected because |
|---|---|
| OS threads only | No cheap concurrency for I/O fan-out; doesn't solve "same code sync/async". |
| Stackless futures (Rust-style `async fn`) | Requires a compiler state-machine transform, forces function coloring at signature level, conflicts with "code doesn't know it's async". |
| Stackless state-machine coroutines (SFEX-style, see §3.10) | Compelling: zero-stack, deterministic, allocation can be hidden inside a parent struct or arena, and (with compiler support) we could lower transparently *without* coloring at the signature level. Kept as a serious alternative to evaluate before implementation — see §3.10. |
| Fully colorless stackful (Go-style, no `Future`) | Can't express `race` / `all` / `timeout` as first-class combinators — the deferred value has no handle. Forces every composition through `spawn` + `chan` + `select`. |
| Callback-based futures, no await | Ugly for sequential flows, re-introduces colored continuations. |

**Chosen model** = stackful M:N + explicit `Future(T)` + `.await()`. Stackful is the runtime technique; explicit Future is the type-level handle for composition. Complementary, not competing.

### Self-hosting relationship

The self-hosted compiler does not itself need to be async — compiler passes are batch transformations over an AST. LSP and parallel module compilation can use OS threads + channels, or opt into the coroutine runtime later. **Lock the async design now** so the stdlib shape (especially `std.io`) is forward-compatible; **implement after self-host** so we only write the runtime once.

---

## Design

### 3.1 Runtime model

A coroutine owns:

- **A stack.** Independently allocated (not on the OS thread stack). Size TBD — initial proposal: 64 KiB mmap'd with a guard page at the base, fail-fast on overflow; growable stacks deferred.
- **A scheduler record.** Contains: saved machine context (registers + SP), state (runnable / suspended / completed / cancelled), pointer to current `Context` chain, result slot, cancellation flag.
- **No implicit allocator, heap, or local storage.** All memory comes from allocators passed in via args or context.

**Scheduler.** M:N work-stealing:
- `N_worker` OS threads (default: number of CPU cores; configurable via env).
- Each worker has a local run queue (Chase–Lev deque) + a shared global queue.
- When local is empty, steal from a random sibling's tail; failing that, park on a condvar/futex until signaled.
- Coroutines suspended on I/O are registered with a **netpoller** (epoll / kqueue / IOCP); readiness events push the coroutine back onto the scheduler.
- Timers (for `sleep`, `timeout`) use a coarse hierarchical timing wheel per worker; global merge on idle.

**No function coloring.** Any FLang function can be called from a coroutine. "Sync code" is just code that doesn't happen to call anything that suspends. There is no `async fn` keyword; `.await()` is a method on `Future(T)`, not a language construct.

### 3.2 `Future(T)`

```flang
pub type Future = struct(T) {
    __state: &FutureState(T)
}
```

`FutureState` is ref-counted (atomic) so both the producing coroutine and the consumer hold handles without lifetime drama. It contains: the result slot (zero-initialized `T` + readiness flag), waker registration, and cancellation signaling.

**Methods:**

```flang
fn Future(T).await(self)                          T                    // also: await(timeout=ms, ctx=&Context, cancel=&CancelToken)
fn Future(T).cancel(self)                         void                 // requests cancellation of this specific future
fn Future(T).detach(self)                         void                 // consume handle; coroutine runs to completion, result discarded
fn Future(T).is_ready(self)                       bool                 // non-blocking peek
fn Future(T).deinit(self)                         void                 // see §3.9
```

**Combinators (stdlib, not magic):**

```flang
fn race(T: Type, a: Future(T), b: Future(T))      Future(T)            // first to resolve wins, other is cancelled
fn all (T: Type, fs: Future(T)[])                 Future(T[])          // all-or-nothing; any failure cancels siblings
fn any (T: Type, fs: Future(T)[])                 Future((usize, T))   // first ready, return (index, value)
fn Future(T).timeout(self, ms: i64)               Future(Result(T, Timeout))
fn Future(T).map(self, f: fn(T) U)                Future(U)
fn Future(T).then(self, f: fn(T) Future(U))       Future(U)
fn Future(T).or_else(self, f: fn(E) Future(T))    Future(T)             // on Future(Result(T, E))
```

`.await()` extensions via named args (§7.1 pattern):

```flang
fut.await()                              // block until done
fut.await(timeout = 5_000)               // → Result(T, Timeout)
fut.await(ctx = my_ctx)                  // override inherited context for this await
fut.await(cancel = &tok)                 // → Result(T, Cancelled); see §3.7
```

`.await()` yields the current coroutine to the scheduler. Scheduler registers current coroutine as the waker on the Future, switches to another runnable coroutine (or parks). When the Future resolves, the waiter is enqueued and eventually resumed — possibly on a different worker.

### 3.3 `spawn`

```flang
fn spawn(alloc: &Allocator, args..., f: fn(args...) T,
         cancel_with: &CancelToken? = null) Future(T)
```

- `alloc` is the coroutine's allocator. Bound to the coroutine's context slot; `or_global()` inside the coroutine returns `alloc`. Must be safe under the caller's concurrency discipline (§3.8).
- `cancel_with` (optional) wires the spawned coroutine to a cancellation token (§3.7). If `tok.cancel()` fires, this coroutine observes the cancellation at its next suspension point and unwinds. If `null`, the coroutine is only cancellable via its own `Future.cancel()`.
- `args...` are passed explicitly. **`spawn`'s `f` parameter is typed as a bare `fn(args...) T` — capturing closures don't coerce into that slot (§7.3, E2111), so the entry lambda is forced to be non-capturing.** Now that RFC-014 lets lambdas capture by default, this is a *deliberate* RFC-005 isolation rule rather than a language-wide limitation: the only boundary crossings are `spawn`, `send`, `recv`, which are all stdlib choke points that can enforce isolation by typing their callable parameters as bare fn pointers.
- `args` are **deep-copied** into `alloc` at spawn time. After spawn returns, the child owns its copies; the parent's originals are untouched. Rationale: eliminates arg-aliasing races by construction. Reference args (`&T`) are preserved as-is and carry §3.6 "your problem" semantics — use them deliberately.
- Returns `Future(T)` bound to `alloc`'s lifetime. Since the caller owns `alloc`, return-value lifetime is automatic.

### 3.4 Channels

```flang
pub type Channel = struct(T) { /* opaque */ }

fn chan(T: Type, alloc: &Allocator, capacity: usize = 0) Channel(T)

fn Channel(T).send(self, v: T)      Future(Result(void, ChannelClosed))
fn Channel(T).recv(self)            Future(T?)                          // None when closed + empty
fn Channel(T).try_send(self, v: T)  Result(void, ChannelFullOrClosed)
fn Channel(T).try_recv(self)        Result(T?, ChannelEmpty)
fn Channel(T).close(self)           void                                 // idempotent; subsequent sends error
fn Channel(T).deinit(self)          void
```

**Semantics.**
- `capacity = 0` = rendezvous (send blocks until recv). `capacity = N` = buffered.
- `send(v)` transfers ownership of `v` (including any backing allocations via the "allocator follows the value" rule) into the channel. On `recv`, ownership transfers to the receiver.
- v1 implementation: **copy-in on send** (bytes copied into a channel-owned slot allocated from the channel's `alloc`). Simpler; allocator migration across the boundary handled by the copy. Zero-copy transfer is a future optimization.
- `close()` wakes all pending receivers with `None`, wakes all pending senders with `Err(ChannelClosed)`.
- Channels are multi-producer / multi-consumer. Close semantics match Go: only producers close; double-close panics (or returns error — [OPEN]).

### 3.5 Context

```flang
pub type Context = struct {
    parent: &Context?,
    key:    TypeId,
    value:  &u8,          // opaque, type-keyed
}

fn Context.get(ctx: &Context, T: Type) T?        // walks parent chain, returns first match
fn Context.with(ctx: &Context, v: T)  Context    // cons a new frame; returns child context
fn current_context() &Context                     // returns current coroutine's context root
```

- **Well-known slot:** `Allocator`. Always populated at the root (from the process allocator at `main`); replaced at each `spawn` with the allocator supplied.
- **User slots:** any user type is its own key via `Type(T)` (§2.9). Example: `Logger`, `Deadline`, `RequestId`, `TraceContext`.
- **Inheritance:** each `spawn` starts the child with a context derived from the parent's current context. Adding an entry (`ctx.with(v)`) produces a new chain frame — O(1) prepend, O(chain-depth) lookup. Chains are shallow in practice.
- **`or_global()`** (updates `std/allocator.f:106`):

  ```flang
  pub fn or_global(alloc: &Allocator?) &Allocator {
      if alloc != null { return alloc.unwrap() }
      const coro = current_coroutine_allocator()    // reads context slot; null on bare main outside spawn
      return coro ?? &global_allocator
  }
  ```

  This makes every existing stdlib function (which already takes `&Allocator? = null`) context-aware without any API change.

### 3.6 `main` as root coroutine

`main` is implicitly spawned on the runtime at process start. Consequences:
- `main` has a context: allocator = `global_allocator`, no deadline, no cancellation.
- `.await()` works at top-level without ceremony.
- The runtime is always live for the lifetime of the process.
- `main` returning causes the runtime to drain outstanding coroutines (`.detach()`'d) up to a graceful-shutdown timeout, then exit with `main`'s return code.

### 3.7 Cancellation

Cancellation is **token-based**. A `CancelToken` is a first-class value that can be observed by *both* the producer side (a coroutine that wants to bail when cancelled) and the consumer side (an `.await()` call that wants to bail when cancelled). The same token can be shared across many futures and many awaiters — cancellation is a fan-out signal, not a per-future flag.

```flang
pub type CancelToken = struct { /* opaque, internally an atomic flag + waker list */ }

fn cancel_token()                                CancelToken
fn CancelToken.cancel(self)                      void                  // idempotent; signals all observers
fn CancelToken.is_cancelled(self)                bool                  // non-blocking peek
fn CancelToken.deinit(self)                      void
```

**Two observation points:**

1. **Consumer-side** — `.await(cancel = &tok)` returns `Err(Cancelled)` immediately when `tok` fires. The producer is *not* affected — the running coroutine continues. This is "I'll wait, but only this long / under this condition."

2. **Producer-side** — `spawn(..., cancel_with = &tok)` makes the spawned coroutine observe `tok`. When `tok.cancel()` fires, the running coroutine sees cancellation at its next suspension point and unwinds. This is "stop the work."

The two are independent. A typical pattern uses both: spawn with `cancel_with = &tok` so the work stops, await with `cancel = &tok` so the wait also returns. Cancelling the token does both at once.

**Decided:**

- `CancelToken` is a value type bound to its creator's allocator (typed-key context entry, inheritable).
- `tok.cancel()` is idempotent and thread-safe (atomic flag + waker fan-out).
- `.await(cancel = &tok)` returns `Result(T, Cancelled)`; `.await()` with no token returns `T` directly. (See §7 q2 — every `.await()` overload returns either `T` or `Result(T, Cancelled)` based on whether you opt in.)
- `Future(T).cancel(self)` remains for the simple "cancel this one future" case — it's equivalent to spawning with a private token and cancelling that token.
- `race(a, b)` internally uses a token: spawn each side with `cancel_with = &internal_tok`, when one wins, fire the token, the loser unwinds.
- `.timeout(ms)` is a one-liner: spawn a timer that calls `tok.cancel()`; await with the same token.
- Cancellation checks occur at every suspension point (`.await()`, channel `send`/`recv`, `sleep`). Compute-bound coroutines that never yield are uninterruptible (matches Go, Kotlin).
- Cancellation is **cooperative** (flag, checked at yield points) — not a forced stack unwind. `defer` runs in normal order during the cooperative unwind.

**Why tokens beat per-Future cancellation:**
- Cancel a tree of work with one call (`tok.cancel()` stops every coroutine spawned with that token).
- Same future can be awaited by multiple consumers with different cancellation policies.
- Maps cleanly to the established "request context" pattern (Go's `context.Context`) without inventing a parallel mechanism — the token can live as a slot in the `Context` chain (§3.5).
- `.timeout` and `race` collapse to library code with no runtime magic.

**Still open — [§7]:** Whether dropping a Future without `await`/`detach` cancels its associated token or detaches; precise interaction of cancel-during-defer.

### 3.8 Soundness model

The existing §3.6 "memory safety is programmer's responsibility" posture extends into concurrency with the following **added rules** enforced by convention and stdlib API shape, not the type checker:

1. **No captures in coroutine entry lambdas.** Enforced by typing `spawn`'s `f` parameter as a bare `fn(args...) T`: per §7.3 / E2111, a capturing closure has an anonymous nominal type and cannot decay into a bare fn pointer slot. RFC-014 made captures the default for lambdas elsewhere; `spawn` keeps them out by signature.
2. **`spawn` deep-copies positional non-reference args.** Enforced by stdlib `spawn` implementation.
3. **Reference args (`&T`) passed to `spawn` carry §3.6 liability.** Same rule as any other shared reference.
4. **The allocator passed to `spawn` must tolerate concurrent use**, if the caller continues to allocate from it while the child runs. Two practical choices:
   - Caller stays passive on that allocator for the coroutine's lifetime, OR
   - Caller uses a thread-safe allocator variant (a `SyncAllocator` wrapper — not in this RFC, future work).
5. **Values sent through a `Channel` transfer ownership.** After `ch.send(v)`, the sender may not use `v`. Enforced by copy-in-on-send: the sender's copy remains logically valid but refers to freed-after-recv bytes in the channel buffer — same lifetime discipline as any `OwnedString` transfer.
6. **A `Future(T)` must be explicitly disposed.** `await()`, `cancel()`, or `detach()` consumes it. Dropping without one of those is a bug, same class as leaking an `OwnedString`. Runtime behavior of an undisposed Future going out of scope: [OPEN] (proposal: `deinit` cancels).

### 3.9 Leak and lifetime model

No changes to existing discipline:
- `defer x.deinit()` still applies inside coroutines.
- Memory allocated inside a coroutine using `or_global()` is allocated from the spawn-supplied allocator. If the coroutine leaks it (forgets to `deinit`), the leak is charged to the spawn-supplied allocator, freed when that allocator is destroyed.
- Async does not introduce "free cleanup via coroutine exit." Async is not gc-via-scope.
- Recommendation: provide a `TracingAllocator` in stdlib that wraps another allocator and reports outstanding allocations on `reset()` / `deinit()`. Fits the existing `AllocatorVTable` model (§4.1). Not blocking for this RFC; bolt on as a debug aid.

### 3.10 Inspiration: SFEX-style stackless state machines (alternative model under consideration)

Reference: <https://vittorioromeo.com/index/blog/sfex_coroutine.html>.

The SFEX post describes a stackless coroutine model where a coroutine *is* a struct, state *is* one integer, and suspension *is* a controlled return. The macro layer expands to a `switch` over `__COUNTER__`-derived state values; persistent state lives as struct members; no heap allocation, no compiler scaffolding hidden from the user. Composition (`SFEX_CO_AWAIT`) is sub-coroutine ownership: the child is a member, the parent runs it to completion and propagates yields.

**Why this is interesting for FLang specifically.** Our previous discussions on this RFC repeatedly came back to allocation cost — every `Future(T)` heap-allocates its `FutureState`, every `spawn` allocates a 64 KiB stack, every combinator (`race`, `all`) allocates more state. SFEX inverts that: the coroutine frame is the struct, allocation strategy is whatever the parent chose, and a `Future(T)`-equivalent can live inline in the awaiter's frame, in an arena, in a pool — same flexibility we already give every other type via explicit allocators.

**Compiler support is the unlock.** The C / hand-written-macro version forces awkward expression-level encoding (no locals across yield points unless promoted to struct members). With compiler support we can do the lowering ourselves: take a function containing `.await()` calls, lift its locals into a generated state struct, lower the body into a `switch`-driven resume function. This is the Rust/C++20 lowering, but **without function coloring at the signature level** — the lowering is performed on any function that transitively calls a yielding primitive, the resulting state struct *is* the `Future(T)`, and call sites see no signature change. Colorless async via stackless lowering, paid for in compiler complexity instead of stack memory.

**What this would change vs. the current design:**

- `Future(T)` becomes a value type (the lowered state struct) instead of a refcounted handle. Allocation strategy becomes the awaiter's choice — inline, arena, heap — same shape as every other FLang type.
- `spawn` no longer allocates a stack. It allocates the lowered state struct (size known at compile time per coroutine type) and registers it with the scheduler.
- Combinators (`race`, `all`) compose state structs rather than heap-allocating fresh ones — the `race(a, b)` Future contains `a` and `b` by value.
- Cancellation, `defer`-on-unwind, and the netpoller integration become a runtime-controlled state-transition rather than a stack manipulation.
- We lose the "any C function can yield transparently" property — yielding requires a lowered call site. This is the trade.

**Status: open design question, not yet a decision.** Locking the stackful model in the RFC body remains the conservative path because it requires no compiler work. Before implementing this RFC (which is gated on self-host anyway, §6 Phase 0), we will revisit and decide between (a) stackful as currently specified and (b) stackless-with-compiler-lowering as sketched here. The stdlib API surface in §3.2–§3.5 is intentionally compatible with either choice — `Future(T)`, `spawn`, `Channel(T)`, `Context` all describe the same observable contract regardless of the lowering strategy underneath.

---

## 4. Worked Examples

### 4.1 Parallel URL fetcher with per-URL timeout

```flang
import std.io
import std.thread           // spawn, Future, race, timeout
import std.chan             // Channel, chan, send, recv
import std.net.http         // http.get : fn(String) Future(Result(Response, HttpError))
import std.time             // sleep : fn(i64) Future(void)
import std.collections      // Dict, dict
import std.text

pub type UrlCount = struct {
    url:   OwnedString,
    words: i64,
}

pub type FetchError = enum {
    Http(HttpError),
    Timeout,
}

pub fn count_words_across_urls(
    urls:  String[],
    alloc: &Allocator,
) Dict(OwnedString, i64) {
    let results = chan(Result(UrlCount, FetchError), alloc, capacity = 8)
    defer results.deinit()

    // Fan out: one coroutine per URL.
    for url in urls {
        spawn(&alloc, url, &results, fn(u: String, out: &Channel(Result(UrlCount, FetchError))) {
            // Inside the coroutine: or_global() resolves to `alloc` via context slot.

            // Race the request against a 5s timeout. If the timeout wins,
            // the http.get future is cancelled.
            let response = race(
                http.get(u),
                sleep(5_000).map(fn(_) Err(Timeout)),
            ).await()

            response match {
                Ok(body) => {
                    defer body.deinit()
                    let count: i64 = 0
                    for _ in body.as_view().split_whitespace() { count += 1 }
                    out.send(Ok(UrlCount {
                        url   = from_view(u, or_global()),
                        words = count,
                    })).await().unwrap()
                },
                Err(e) => {
                    out.send(Err(e)).await().unwrap()
                },
            }
        })
    }

    // Fan in: known count (urls.len).
    let merged = dict(OwnedString, i64)   // allocates from or_global() → alloc
    for _ in 0..urls.len {
        results.recv().await() match {
            Some(Ok(r))  => merged[r.url] = r.words,
            Some(Err(e)) => io.eprintln($"fetch failed: {e}"),
            None         => break,         // channel closed prematurely
        }
    }
    return merged
}
```

**What this exercises:**
- `spawn(&alloc, args..., fn)` with positional args and no captures.
- Transparent allocator inheritance via context (`from_view(u, or_global())` picks up `alloc`).
- `race(...)` composing two Futures.
- `.map` as a combinator on `Future(T)`.
- `.timeout` alternatively available — equivalent form: `http.get(u).timeout(5_000).await()`.
- `Channel.send().await()` yielding when buffered channel is full.
- `Channel.recv().await()` yielding when channel is empty.
- `None` on `recv` signals "channel closed, drained" — unreachable here because we don't close; present for streaming (§4.2).
- Nothing in `count_words_across_urls` needed an `async fn` annotation. Nothing in `http.get` or `from_view` did either.

### 4.2 Streaming producer/consumer with `close()`

```flang
// Read lines from a reader, count non-blank ones; producer closes when done.

pub fn count_non_blank_lines(
    reader: &Reader,
    alloc:  &Allocator,
) i64 {
    let lines = chan(OwnedString, alloc, capacity = 64)
    defer lines.deinit()

    spawn(&alloc, &reader, &lines, fn(r: &Reader, out: &Channel(OwnedString)) {
        loop {
            r.read_line() match {
                Ok(Some(line)) => {
                    out.send(line).await().unwrap()
                    // line ownership transfers into the channel; copy-in frees sender copy
                },
                Ok(None) => break,          // EOF
                Err(_)   => break,
            }
        }
        out.close()
    })

    let count: i64 = 0
    loop {
        lines.recv().await() match {
            Some(line) => {
                defer line.deinit()
                if line.as_view().trim().len > 0 { count += 1 }
            },
            None => break,                  // producer closed
        }
    }
    return count
}
```

**What this exercises:**
- Unknown-count stream: producer `close()`s, consumer drains until `None`.
- Ownership transfer of `OwnedString` through the channel.
- Independent consumer coroutine is implicit — we're consuming in the parent, producer is spawned.

### 4.3 HTTP handler with context

```flang
pub type RequestCtx = struct {
    id:     u64,
    logger: &Logger,
}

pub fn handle_request(req: &Request, resp: &ResponseWriter, alloc: &Allocator) {
    let rc = RequestCtx { id = next_request_id(), logger = default_logger() }

    // Augment the current context with the request context,
    // then spawn the handler so children inherit it.
    let ctx = current_context().with(&rc)

    spawn_in(ctx, &alloc, req, resp, fn(r: &Request, w: &ResponseWriter) {
        // Anywhere in the handler tree (including nested spawns):
        let rc = current_context().get(RequestCtx).unwrap()
        rc.logger.info($"[{rc.id}] {r.method} {r.path}")

        let body = fetch_upstream(r.url_param("u")).await()
        w.write(body).await().unwrap()
    }).await()
}

// spawn_in: context-override form of spawn
fn spawn_in(ctx: Context, alloc: &Allocator, args..., f) Future(T)
```

**What this exercises:**
- `Context.with(v)` to inject a value.
- Nested `spawn` inheriting the augmented context without explicit threading.
- The same primitive that carries the allocator carries request-scoped state (tracing ID, logger).

---

## 5. Implementation

Three layers: **runtime (C)**, **stdlib (FLang)**, **compiler (minimal / none)**.

### 5.1 Runtime — C (`stdlib/std/runtime/async.c`, `async.h`, platform-specific)

New directory: `stdlib/std/runtime/`. Companion `.c` files follow the existing BuildCache convention (architecture.md §"Build Cache"). Platform-specific files gated via `#if(platform.os == ...)` on the FLang side and `#ifdef` on the C side.

**Components:**

1. **Coroutine context switching.** Start with `ucontext.h` (POSIX, portable). Plan: replace with fcontext-style assembly (x86_64, arm64) for speed in a follow-up. Windows: Fibers API.
2. **Stack allocation.** mmap 64 KiB + 4 KiB guard page per coroutine. Stack overflow = SIGSEGV on guard, fail-fast with a diagnostic. Growable stacks deferred.
3. **Scheduler.** `Worker` struct per OS thread. Local run queue = fixed-size Chase–Lev deque (256 slots); overflow pushes to shared global queue. Idle workers steal from a random sibling's tail; failed steal rounds park on `pthread_cond_t` / `WaitForSingleObject`.
4. **Netpoller.** `io_uring` (Linux ≥5.6, primary; falls back to `epoll` on older kernels), `kqueue` (macOS, BSD), `IOCP` (Windows). Detection is runtime: probe `io_uring_setup` at startup and select epoll if unavailable or if a feature flag forces it. The netpoller abstraction is **completion-oriented** (matching io_uring and IOCP); readiness-based backends (kqueue, epoll fallback) emulate completion on top — read/write happen on the worker side after the readiness event, with the result delivered to the registered Future. Dedicated poller per platform's native idiom (Linux runs inline on an idle worker; Windows IOCP gets a pool). Events translate to waker invocations on registered Futures. Future work: linked SQE chains for fused submit-and-await on io_uring.
5. **Timer wheel.** Hierarchical (tick = 1 ms). Per-worker local wheel; global merge on idle. Used by `sleep` and `.timeout`.
6. **Atomic primitives.** Reuse existing `stdlib/std/atomic.c`. Future state uses `atomic_fetch_add` on the internal ref count and `atomic_compare_exchange` on the readiness flag.

**C ABI surface** (called from FLang via `#foreign`):

```c
// Coroutine lifecycle
void*  flang_coro_spawn(void (*entry)(void*), void* arg, size_t stack_size);
void   flang_coro_yield(void);                     // cooperative yield
void   flang_coro_park(FlangFutureState* wait_on); // suspend until future ready
void   flang_coro_resume(FlangCoro* c);            // scheduler-internal

// Future state (allocated via the stdlib allocator the Future is bound to)
FlangFutureState* flang_future_new(size_t result_size, size_t result_align);
void              flang_future_complete(FlangFutureState* s, const void* result);
void              flang_future_cancel(FlangFutureState* s);
bool              flang_future_is_ready(FlangFutureState* s);
void              flang_future_await(FlangFutureState* s, void* out_result);

// Netpoller
void flang_net_register(int fd, int events, FlangFutureState* waker);
// ...etc

// Timer
void flang_timer_after(int64_t ms, FlangFutureState* waker);

// Scheduler init (called implicitly before main())
void flang_runtime_init(int worker_count);  // 0 = autodetect
void flang_runtime_shutdown(int exit_code);
```

**Entry wrapping for `main`.** The compiler already generates a C `main`. Update generation to:

```c
int main(int argc, char** argv) {
    flang_runtime_init(0);
    FlangFutureState* root = flang_future_new(sizeof(int32_t), alignof(int32_t));
    flang_coro_spawn(flang_main_entry, root, /*stack=*/ DEFAULT_STACK);
    int32_t code = 0;
    flang_future_await(root, &code);
    flang_runtime_shutdown(code);
    return code;
}
```

The runtime is always live. `main` runs as coroutine 0 on worker 0.

### 5.2 Stdlib — FLang (`stdlib/std/thread/`, `stdlib/std/chan/`, `stdlib/std/context/`)

**New modules** (colocated `.f` and `.c` where needed):

- `stdlib/std/thread/spawn.f` — `spawn`, `Future(T)`, `Future.await`, `.cancel`, `.detach`, `.deinit`, `.map`, `.then`, `.or_else`, `.timeout`, `race`, `all`, `any`.
- `stdlib/std/chan/channel.f` — `Channel(T)`, `chan`, `send`, `recv`, `close`, `try_send`, `try_recv`, `deinit`.
- `stdlib/std/context/context.f` — `Context`, `with`, `get`, `current_context`, `current_coroutine_allocator`.
- `stdlib/std/time/sleep.f` — `sleep(ms) Future(void)`.

**Updated modules:**

- `stdlib/std/allocator.f` — `or_global` becomes context-aware (lines ~106; see §3.5 snippet). Zero behavior change outside a coroutine.
- `stdlib/std/io/**` — I/O primitives get async-aware variants that return `Future(T)`. File reads, socket reads, etc. route through the netpoller. Existing blocking variants remain available for sync-only paths (e.g. CLI startup code) — or are reimplemented as `async_variant.await()` on the root coroutine, since `main` is always in a coroutine. [OPEN — §7 q6.]
- `stdlib/std/net/http.f` — `http.get(url) Future(Result(Response, HttpError))`.

**Generic specialization interaction.** `Future(T)`, `Channel(T)` are generic types — they follow the existing eager-monomorphization model (architecture.md §"Type System"). No new compiler support needed beyond what `Rc(T)` already exercises.

**`op_deref` opportunity.** `Future(T)` could implement `op_deref` returning `&T` after the future is resolved, but this would hide `.await()` and violates the explicit-suspension principle. **Do not implement `op_deref` on `Future(T)`.** Keep `.await()` mandatory.

### 5.3 Compiler changes

**Minimal to none.** Stackful coroutines require no compile-time transform — the runtime owns stack switching. Concretely:

- **No new AST nodes.** `spawn`, `.await()` are ordinary function and method calls. `race`, `all`, `.timeout`, etc. are ordinary calls.
- **No new keywords.** `await` is not a keyword; it's a UFCS method.
- **No state-machine transform.** No CPS conversion, no local-variable promotion to a closure environment, no async `.poll` trait generation.
- **Main-function codegen update** (`src/FLang.Codegen.C/`): wrap emitted C `main` to call `flang_runtime_init` / `flang_runtime_shutdown` and run the user's `main` as coroutine 0 (§5.1).
- **Optional future work:** a `#no_suspend` directive (`src/FLang.Frontend/`) that errors if the compiler can see a call path from the annotated function to any `.await()` or known yielding primitive. Useful for asserting that a held non-reentrant resource (mutex, arena) isn't abandoned mid-coroutine. **Out of scope for this RFC.**

### 5.4 Build integration

- Runtime `.c` files join the existing BuildCache machinery (`stdlib/std/runtime/*.c`, `architecture.md §"Build Cache"`). Platform-specific files selected at configure time based on target triple.
- Link flags: `-lpthread` on POSIX, whatever Windows IOCP needs.
- `flags_hash` invalidation already covers target triple changes.

---

## 6. Phases / Ordering

1. **Phase 0 — Self-host first.** Per the decision in the design discussion, do not implement this RFC until the C# compiler is retired. This RFC is a design lock; implementation is gated on self-host readiness.
2. **Phase 1 — Runtime skeleton (C).** `ucontext` + simple round-robin scheduler on a single worker. No I/O integration, no timers. Enough to spawn, yield, await, complete. Unit tests in C.
3. **Phase 2 — FLang bindings.** `Future(T)` with `await` / `cancel` / `detach`. `spawn` with deep-copy args. Tests in `tests/FLang.Tests/Harness/async/`.
4. **Phase 3 — Context + allocator slot.** `Context` type, `current_context`, `current_coroutine_allocator`. Update `or_global` (§3.5). Verify existing stdlib continues to pass without modification.
5. **Phase 4 — Channels.** `Channel(T)`, `send`/`recv`/`close`. Rendezvous + buffered.
6. **Phase 5 — Combinators.** `race`, `all`, `any`, `.map`, `.then`, `.or_else`, `.timeout`. (`.timeout` depends on Phase 6.)
7. **Phase 6 — Work-stealing + timers.** Multi-worker scheduler, hierarchical timing wheel, `sleep`.
8. **Phase 7 — Netpoller.** epoll / kqueue / IOCP. Async `std.io.file` reads, async `std.net` sockets.
9. **Phase 8 — HTTP client.** `std.net.http.get` atop async sockets. Enables Example 4.1 end-to-end.
10. **Phase 9 — Docs.** Add §10 "Concurrency" to `docs/spec.md` referencing this RFC. Register new error codes in `docs/error-codes.md` (cancellation, channel-closed, timeout). Update `docs/architecture.md` with runtime overview.

Each phase has a green test gate; no advance until `dotnet test.cs async*` passes.

---

## 7. Open Questions (for review)

These are intentionally undecided. Reviewing them is the primary purpose of the "review before implementation" step.

1. **Unawaited Future disposition.** `Future(T).deinit()` without prior `await` / `cancel` / `detach`: (a) implicit detach (Go-ish), (b) implicit cancel (Rust-ish), (c) panic (discipline-enforcing, matches manual `deinit`). **Proposal: (b) cancel on `deinit`** — matches FLang's explicit-resource grain and catches forgotten Futures.
2. **`.await()` on a cancelled Future.** (a) Return `Result(T, Cancelled)` automatically (requires `Future(T)` to actually be `Future(Result(T, Cancelled))` under the hood, or a separate `CancellableFuture(T)`). (b) Panic. (c) Return zero-initialized `T` and set a thread-local flag. **Proposal: (a)** — every `.await()` returns `Result(T, Cancelled)`, user unwraps when they know cancellation can't happen.
3. **Cancellation model: cooperative flag vs forced unwind.** Proposal: **cooperative flag, checked at every suspension point**. Matches Go/Kotlin. Forced unwind requires stack scanning + `defer` replay machinery that the runtime doesn't have.
4. **`defer` during cancel.** When a coroutine is cancelled at a suspension point, its stack still has pending `defer`s. They must run in normal order during unwind. Confirm the existing FIR `defer` lowering is compatible with a runtime-driven unwind signal. Likely yes (defers run on scope exit regardless of path) but needs validation in Phase 2.
5. **Channel double-close.** (a) Panic (Go). (b) `close` returns `Result(void, AlreadyClosed)`. **Proposal: (a) panic** — it's a bug, surface it loudly.
6. **Sync I/O after async lands.** Does `std.io` retain synchronous-blocking variants, or does every I/O call return a Future and blocking is implemented as `.await()` on the main coroutine? **Proposal: all I/O returns Future; there is no "sync" variant; blocking at top-level is `.await()` on `main`.** Simpler surface; relies on `main`-as-root-coroutine.
7. **`SyncAllocator` wrapper.** Needed for the common case of a shared allocator across sibling coroutines (§3.8 rule 4). Out of scope for this RFC but a required sibling feature before the design is practically usable. Track as follow-up ticket.
8. **Stack size policy.** Fixed 64 KiB + guard vs initial-small-with-growth. Proposal: **fixed for v1**, growth deferred. Guard-page SIGSEGV → diagnostic with "increase stack size" hint.
9. **Number of workers.** Default = CPU count. Env var `FLANG_WORKERS`. Low-priority decision, safe default.

---

## 8. Risks / Pitfalls

- **`ucontext` is deprecated on some platforms.** Linux `glibc` still supports it but it's slow. Accept for v1; plan assembly replacement.
- **Stack overflow in coroutines is silent without guard pages.** Ensure guard page configuration is tested per platform — a stack overflow that corrupts adjacent coroutines is an obscure class of bug.
- **Deep-copy of args.** Cost depends on arg size. For large structs, this is a real overhead. Document the pattern: pass `&T` when you mean aliasing (and accept §3.6 liability), pass `T` when you mean a copy.
- **Allocator thread-safety confusion.** §3.8 rule 4 is a sharp edge. The documentation must be explicit; a common shape will be "spawn with a SyncAllocator-wrapped arena." Mitigated by §7 q7.
- **`defer` + cancel interaction.** Untested surface (§7 q4).
- **Channel copy-in cost.** Large-payload channels pay a `memcpy` per message. Acceptable for v1; zero-copy transfer is a future optimization (transfer-with-allocator, per §3.4).
- **`Future(T)` is heap-allocated (the `FutureState`).** Every `spawn` and every `race`/`all` etc. allocates. Acceptable; matches Tokio's `Arc<Task>` cost.
- **Debugging experience.** Stackful coroutines don't show cleanly in gdb backtraces without coroutine-aware pretty-printers. Accept as known limitation; revisit if self-host tooling needs it.
- **Interaction with `#foreign` C code.** Foreign C that blocks on syscalls will block the underlying worker, starving other coroutines on that worker. Mitigation: mark known-blocking foreign calls with `#foreign_blocking` (future) and have the scheduler promote the worker to a dedicated OS thread for the duration. **Out of scope for this RFC.**

---

## 9. Out of Scope

- **Async iterators / streams.** `for x in stream` with suspension. Can be built atop `Channel(T)`. Separate RFC.
- **Structured concurrency (nursery / scope).** Kotlin/Trio-style scoped coroutines that must complete before their scope exits. Useful; separate RFC.
- **Select over multiple channels.** Go-style `select { case ... }`. Implementable atop `any` over `recv` futures. Separate RFC if it becomes idiomatic.
- **`SyncAllocator` variants.** Atomic arena, sync-wrapper vtable. Required sibling feature (§7 q7), separate ticket.
- **Blocking-C-call isolation (`#foreign_blocking`).** Listed in risks; separate work.
- **Cancellation error-hierarchy design.** If user code wants typed cancellation reasons (timeout vs user-requested), that's beyond the `Cancelled` binary signal proposed here.
- **Growable stacks.** v1 is fixed-size.
- **Compile-time `#no_suspend` diagnostic.** Optional future hardening.
