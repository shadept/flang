---
type: language
created: 2026-04-21
linear: SH-14
relates: [RFC-037, RFC-038, RFC-039, RFC-042, RFC-098, RFC-099]
---

# RFC-005: Async / Coroutines

## Summary

Concurrency for FLang as a **stackful M:N coroutine runtime** with **structured concurrency**:
coroutines start inside a scope that waits for them, a job tree carried by the runtime context
propagates cancellation downward, and results come back as values through `.await()`. Kotlin's
coroutine library is the comparison baseline for scopes, jobs, cancellation and channels; its
`suspend` colouring and its exception machinery are not imported (§2).

| Property | Position | Settled? |
|---|---|---|
| Coroutine model | Stackful: each coroutine owns a stack, swapped by the runtime | Constraint |
| Function colouring | **None.** No `async fn`, no `suspend`, no suspend function types, no rule on who may call what | Constraint |
| Waiting syntax | `.await()`, an ordinary method on an awaitable value | Constraint |
| Scheduler | M:N work-stealing over worker threads | Proposed |
| Structure | `concurrent` waits for every child it started; tasks are bound to their scope | Proposed |
| Builders | `spawn` returning `Task(T)`; a result-less form is open | **D2** |
| `.await()` result | `T`; cancellation reaches code as values from the primitives that suspend | **D4** |
| Cancellation | Cooperative; a job tree in a `context` field; checked at suspension points | Proposed |
| Failure | Errors are values; fail-fast vs supervision is open | **D5** |
| Transport | `Channel(T)` with `send`/`recv` awaitables, `close` | Proposed |
| Context | RFC-038 `context` fields; a structured child keeps its parent's link | Settled by RFC-038 |
| Allocators | `context.allocator`; what a parallel child inherits is open | **D6** |
| Detached work | Not in v1 by recommendation | **D7** |
| Runtime start | `main` is plain; the first `concurrent` scope starts the runtime if none is running | Proposed; details **D11** |

**Nothing here exists yet.** No `std.task`, `Task`, `Scope`, `Channel` or runtime is in the
tree. The signatures below are proposals. §1 says which of them the current checker would
accept as written; §7 lists every decision this draft leaves to the owner.

**What this RFC is not.** An async I/O catalog. It defines the primitives and their contract;
async-aware wrappers in `std.io`, `std.net` and `std.net.http` are follow-up work.

## 1. Reading this document

- **Expressible today**: a declaration or snippet in current FLang syntax (RFC-037 function
  values, RFC-038 context, RFC-039 lambdas, RFC-043 ownership) that the checker would accept if
  the declared functions existed. It is still a proposal.
- **Needs a feature**: marked with the feature it needs (RFC-099 `#stack`, a block construct,
  owning closures). Those features are not implemented.
- **Illustrative**: pseudocode for shape only; marked where it appears.
- **Dn**: an open decision (§7). The text gives a recommendation, never a decision.

---

## Motivation

FLang needs concurrency to be a viable systems language. The bar:

1. **Compose I/O**: fetch N URLs in parallel, bound each by a timeout, cancel the losers.
2. **Share code between sync and async**: `Dict`, `StringBuilder`, `list` and any user function
   neither know nor care whether they run in a coroutine.
3. **Deterministic resources**: no GC, no surprise background lifetimes. `defer`, allocators and
   `deinit` work unchanged.
4. **No compile-time async transform**: no state-machine lowering in the self-hosted compiler.
5. **Stay FLang-grain**: UFCS methods, trailing lambdas, the runtime context, ownership.

### Alternatives considered

| Model | Rejected because |
|---|---|
| OS threads only | No cheap concurrency for I/O fan-out; doesn't solve "same code sync/async". |
| Stackless futures (Rust `async fn`) | A compiler state-machine transform, and colouring at the signature level. |
| Stackless with compiler-generated machines, uncoloured | Rejected 2026-11-10; does not stay uncoloured past function values, foreign calls and recursion (§3.13). |
| Kotlin-style `suspend` (stackless CPS, coloured) | Colouring is the price of being stackless: "You can only call a suspending function from another suspending function." Excluded by constraint. Its structured-concurrency model is adopted (§2). |
| Fully colourless stackful with no handle (Go) | No value to compose or cancel; every join goes through channels. |
| Callback futures, no await | Sequential flows become continuation chains. |

**Chosen model** = stackful M:N runtime + structured scopes + `.await()` on task and operation
values. Stackful is what makes the absence of colouring possible; scopes are what make
FLang's by-reference closures and borrowed `fn` values sound across concurrency (§3.3).

### Self-hosting relationship

The compiler does not need async. The self-host gate (Phase 0 of the original plan) is met: the
C# reference compiler was retired 2026-08-28 (`docs/self-host.md`), so the runtime is written
once, in C and FLang.

---

## 2. Kotlin as the baseline

Kotlin's behaviour below is taken from kotlinlang.org (Sources at the end); a claim not found
there is marked unverified.

### What Kotlin does

- **Colouring.** A suspending function is declared `suspend`, and "you can only call a
  suspending function from another suspending function." Builders take
  `block: suspend CoroutineScope.() -> T`.
- **Structure.** Builders are extensions on `CoroutineScope`. "A parent coroutine waits for its
  children to complete before it finishes. If the parent coroutine fails or gets canceled, all its
  child coroutines are recursively canceled too." `coroutineScope { }` waits for the block and
  every coroutine launched in it. `runBlocking { }` runs a block "in a new coroutine …
  blocking the current thread until its completion"; it bridges plain code (`main`, tests,
  callbacks) to suspending code, and "calling `runBlocking` from a suspend function is
  redundant" and risks thread starvation.
- **Jobs.** `launch` returns a `Job`; `async` returns a `Deferred`, "a Job with a result".
  `await()` returns the value "or throws the exception if the deferred was cancelled".
- **Failure.** An exception other than `CancellationException` in a child "cancels its parent
  with that exception"; `SupervisorJob` / `supervisorScope` stop that, and still wait for every
  child.
- **Cancellation is cooperative.** It is observed at suspension, by `isActive`, `ensureActive()`
  or `yield()`. `withTimeout(1.seconds) { Thread.sleep(10_000) }` runs the full ten seconds. A
  cancelled coroutine unwinds with `CancellationException`, so `finally` runs; cleanup that must
  suspend uses `withContext(NonCancellable)`, which is documented as not for use with `launch`
  or `async` because it severs the parent-child link.
- **Context.** A set of elements, chiefly the `Job` and the dispatcher, inherited by children;
  `GlobalScope` or an explicit `Job()` breaks the parent link. A thread-local follows a coroutine
  only through `asContextElement`, which restores it at each switch.
- **Dispatchers.** `Default` (shared pool, CPU work), `IO` (elastic pool for blocking calls),
  `limitedParallelism(n)`.
- **Channels.** Suspending `send` and `receive`; rendezvous unless buffered; `close` is a token
  after every earlier element; FIFO-fair.

### What FLang takes, adapts and refuses

| Kotlin | FLang | |
|---|---|---|
| `suspend`, suspend function types | Nothing. Any function may reach a suspension point | **Refused** (constraint) |
| `coroutineScope { }` and `runBlocking { }` | `concurrent { s => ... }`, one function for both (§3.3, §3.10) | Adapted; form open (**D1**) |
| `async` / `Deferred.await()` | `s.spawn { ... }` / `Task(T).await()` | Adapted |
| `launch` / `Job` | Open (**D2**) | |
| Job tree | A `context` field rebound per scope (§3.4) | Adapted |
| `CancellationException` unwinding | Cancellation as a value from suspending primitives, propagated with `?`; `defer` runs as on any exit (§3.4) | Adapted: FLang has no exceptions |
| `NonCancellable` | `context(job = &non_cancellable) { ... }` | Adapted, same scoping rule |
| Child failure cancels parent | Open (**D5**) | |
| Dispatchers | One pool; blocking offload and dispatcher choice open (**D8**) | |
| `asContextElement` | Not needed: `context` is a hidden parameter, not thread-local storage, so it follows a coroutine across workers | FLang advantage |
| `Deferred.map` etc. | Not in Kotlin's core surface either; sequential code inside a task | Dropped from this RFC |
| `Channel` | `Channel(T)`, `move` on send (§3.6) | Adapted |

---

## 3. Design

### 3.1 Runtime model

A coroutine owns:

- **A stack.** Its own allocation, not the OS thread stack: a lazily committed virtual
  reservation with a guard page at its base, fail-fast on overflow. Stacks never grow or move
  (§8 q3).
- **A scheduler record.** Saved machine context (registers, SP), state (runnable / suspended /
  completed), its job, its result slot.
- **No implicit allocator or local storage.** Memory comes from allocators, through
  `context.allocator` or a parameter. Stacks and task records come from the runtime's own pool
  of reservations (§3.8).

**Scheduler.** M:N work-stealing:

- `N_worker` OS threads (default: CPU count; `FLANG_WORKERS` overrides).
- Each worker has a local run queue (Chase–Lev deque) and shares a global queue.
- An idle worker steals from a random sibling's tail; failing that, it parks on a condvar/futex.
- Coroutines waiting on I/O are registered with a **netpoller** (io_uring/epoll, kqueue, IOCP);
  completion puts them back on a run queue.
- Timers (`sleep`, timeouts) use a hierarchical timing wheel per worker, merged on idle.

**No colouring.** Any FLang function can run in a coroutine and any can reach a suspension
point. There is no `async fn`; `.await()` is a method, not a construct; a function type says
nothing about suspension (RFC-037 function values stay one type).

**The root context crosses workers for free.** RFC-038's context is the hidden `const Context *`
parameter. A coroutine resumed on another worker keeps its stack, and with it every context
pointer in its frames. Context links are immutable and live in frames that do not move, so
concurrent reads from several workers need no synchronization.

### 3.2 Suspension and `.await()`

**What `.await()` marks.** Without colouring, a call never shows whether its callee suspends:
`fetch_all(urls)` may wait inside its body while its caller writes no `.await()`, as any call
may block today. `.await()` marks the point where *the function writing it* waits on a value it
holds. This is weaker than Kotlin, where every call to a `suspend` function is a visible
suspension point; that visibility is what colouring buys, and FLang does not pay for it.

**An awaitable is a value with an `await` method.** A task handle is one; so is the value a
channel operation returns. An operation's value can be a small struct whose `await` performs the
suspension, so `.await()` everywhere costs no allocation per operation. Whether a contract names
the shape (`Awaitable`, RFC-035) is open (**D9**).

**Recommendation for what `.await()` returns (D4):**

- `Task(T).await()` returns `T`. Awaiting a task does not fail on its own account.
- Cancellation reaches code through the **leaf** primitives that suspend (`recv`, `send`,
  `sleep`, socket I/O, `check_cancelled`): each returns a `Result` whose error includes
  cancellation. Code propagates it with `?`, so every `defer` runs on the way out.
- A task body decides what its `T` is when cancelled: usually a `Result` whose error includes
  cancellation.
- When the awaiter's job is cancelled, the awaited child is cancelled with it (§3.4), so the wait
  ends once the child returns.

Cost: a child that never yields delays its awaiter until it finishes, as a Kotlin scope waits
for an uncooperative child. The alternative, every `.await()` returning
`Result(T, Cancelled)`, makes the awaiter interruptible at the price of an `?` or `unwrap` on
every await, and still leaves the child running. The original draft held both positions
(its §3.7 "decided" `T`; its §7 q2 proposed `Result`); this revision recommends the first and leaves
the choice open.

### 3.3 Scopes and tasks

Proposed module `std.task`. Signatures in current syntax; none of them exist.

```flang
pub type Scope = struct {
    __state: &u8                    // runtime-owned: the scope's job and its task slots
}

pub type Task = struct(T) {
    owned __slot: &TaskSlot(T)      // non-copyable: dropping one unawaited is W2006
}

// coroutineScope { } (runBlocking { } off the runtime, §3.10): run `body`, then wait
// for every task it started.
pub fn concurrent(body: fn(&Scope) $R) R

// async { }: start `body` as a child of `self`.
pub fn spawn(self: &Scope, body: fn() $T) Task(T)

// Wait for the result. Consuming: a second await of one task is E2123.
pub fn await(self: move Task($T)) T

// Cancel every task of this scope, and their descendants.
pub fn cancel(self: &Scope)
```

```flang
const total = concurrent { s =>
    const a = s.spawn { count_words(url_a) }   // captures url_a by reference
    const b = s.spawn { count_words(url_b) }
    a.await() + b.await()
}
```

**Name.** `concurrent` (alternative: `concurrent_scope`). The type stays `Scope`. The same name
serves either form D1 chooses, a function taking a lambda or a block construct.

**Why a scope makes the closures sound.** Captures are by reference (RFC-033, spec §7.3) and a
`fn` value borrows the closure it was made from (RFC-037). A scope returns only after every
child has finished, so the frame a child's closure points into outlives the child. A detached
task has no such guarantee (§3.9).

**Ownership.** `Task(T)` holds an `owned` field, as `Rc` does: leaving one unawaited is W2006 at
compile time, and awaiting consumes it. W2006 is a warning, so a scope can still end with
tasks never awaited; the scope then waits for them and releases their results with `release`. Whether the scope also cancels them first is part of
**D2**.

**Expressibility.** The declarations above are current syntax. Three properties are not
enforceable with what exists:

- **`return` inside a lambda is E1054.** A `concurrent { }` body cannot return from the enclosing
  function or `break` an outer loop; bind the result instead. Kotlin's `coroutineScope` allows
  this because it is inline. The alternatives are a block construct (`concurrent { }`, as
  RFC-099 and `docs/notes/concurrency-patterns.md` sketch) or Kotlin-style non-local return,
  which RFC-039 keeps E1054 free for. **D1.**
- **A task can escape its scope** by being returned out of the body, then awaited after its slot
  is freed. Preventing it needs RFC-099 `#stack` (a draft, unimplemented) on `Task` and `Scope`,
  or a runtime generation check that panics. **D3.**
- **`spawn`'s body is a borrowed `fn`.** Sound only because of the scope; a builder that lets a
  task outlive its scope must not take one (§3.9).

**`race`, `all`, `any`.** `all` is `tasks` awaited in order. `race` (first result wins, the
rest are cancelled) and an `any`/`select` over awaitables are scope helpers; their signatures
are open (**D9**). The original draft's `Future(T).map`, `.then` and `.or_else` are dropped:
each stored a callback in shared state to run later, possibly on another worker after the
creating frame returned, which a borrowed `fn` value does not survive. Sequential code inside a
task replaces them, as in Kotlin.

### 3.4 Jobs and cancellation

Proposed declarations, current syntax:

```flang
pub type Job = struct { __state: &u8? }      // runtime-owned job record
pub type Cancelled = struct {}

const non_cancellable = Job { __state = null }   // the runtime's sentinel; representation open
pub context job: &Job = &non_cancellable

pub fn is_cancelled() bool                         // isActive, negated; reads context.job
pub fn check_cancelled() Result((), Cancelled)     // ensureActive, for `?`
pub fn yield_now() Result((), Cancelled)           // yield(): check, then let others run
```

**The job tree is the context.** `concurrent` creates a job whose parent is `context.job` and runs
its body, and every child, under `context(job = &child_job) { ... }`. RFC-038 §Semantics 4
already says a structured child keeps the parent's link; the link now names the job that
cancels it. Cancelling a job cancels its descendants; it never cancels its parent.

**Cooperative.** A cancelled coroutine is not unwound. Its next leaf suspension (or
`check_cancelled`) returns the cancellation as a value; the code returns it with `?`. A
coroutine that never suspends and never checks runs to completion (Kotlin's `Thread.sleep`
example applies unchanged).

**`defer` and cleanup.** A deferred body runs under the context where it was written (spec §4.4
semantics 3), which is the cancelled one, so a suspending cleanup gets `Cancelled` back at once.
Cleanup that must wait rebinds: `context(job = &non_cancellable) { conn.close().await() }`. As
with Kotlin's `NonCancellable`, this belongs around cleanup code only; a `concurrent` scope started inside
it is a tree of its own.

**Tokens.** The original draft's `CancelToken` (one flag shared by many futures and awaiters)
becomes the job: `Scope.cancel` is "cancel the token", and running under a scope is "spawn with
the token". An explicit standalone token is not proposed.

**Panics** stay fatal to the process (spec §9.2). Under `flang test` a panic is caught with
`longjmp` (`stdlib/std/test.c`), which cannot cross from a coroutine stack to the runner's;
how a panicking task fails its test is open (**D10**).

### 3.5 Failure and supervision

FLang has no exceptions, so Kotlin's rule "a failing child cancels its parent" has no carrier:
the runtime cannot tell failure in an arbitrary `T`. Failure is a value the body returns.

**Recommendation (D5):** `concurrent` behaves as Kotlin's `supervisorScope`: no child cancels its
siblings, and each result is the awaiter's to inspect. Fail-fast is opt-in through a variant
for `Result` bodies, which cancels the scope on the first `Err` (sketch, current syntax):

```flang
pub fn try_concurrent(body: fn(&TryScope($E)) Result($R, E)) Result(R, E)
pub fn spawn(self: &TryScope($E), body: fn() Result($T, E)) Task(Result(T, E))
```

This reverses Kotlin's default. Choosing Kotlin's default instead means `concurrent` itself is
restricted to `Result` bodies. Either way there is no `CoroutineExceptionHandler`.

### 3.6 Channels

Proposed, current syntax; the element type is inferred from use (`let ch = channel()` then
`ch.send(3i32)`):

```flang
pub type Channel = struct(T) { owned __state: &u8 }
pub type RecvError = enum { Closed, Cancelled }
pub type SendError = enum(T) { Closed(T), Cancelled(T) }   // the value comes back

pub fn channel(capacity: usize = 0, allocator: &Allocator = context.allocator) Channel($T)
pub fn send(self: &Channel($T), value: move T) SendOp(T)
pub fn await(self: move SendOp($T)) Result((), SendError(T))
pub fn recv(self: &Channel($T)) RecvOp(T)
pub fn await(self: move RecvOp($T)) Result(T, RecvError)
pub fn try_send(self: &Channel($T), value: move T) Result((), SendError(T))
pub fn try_recv(self: &Channel($T)) Result(T?, RecvError)
pub fn close(self: &Channel($T))
pub fn deinit(self: move Channel($T))
```

- `capacity = 0` is rendezvous; `N` is buffered. Multi-producer, multi-consumer, FIFO-fair.
- `send` takes `value` by `move`; a send that fails gives it back in `SendError`, so a
  non-copyable value never leaks. On `recv` ownership passes to the receiver. This replaces the
  original "the sender's copy remains logically valid" convention with the checker's.
- v1 copies the bytes into a slot from the channel's allocator; zero-copy transfer is later.
- `close` lets receivers drain every element sent before it, then `Err(Closed)`; pending and
  later senders get `Err(Closed(v))`. Double close: panic (Go) recommended; still open (§8 q1).
- `for v in ch` would suspend inside `next()` with no `.await()` written; whether channels
  implement the iterator protocol is part of **D9**.
- The allocator parameter is last (CLAUDE.md rule); the original `chan(T, alloc, capacity)` put
  it first.

### 3.7 Timeouts and sleep

```flang
pub fn sleep(ms: i64) SleepOp                      // await: Result((), Cancelled)
pub fn with_timeout(ms: i64, body: fn() $T) T?     // withTimeoutOrNull
```

`with_timeout` runs `body` in a child scope and cancels that scope's job when the timer fires.
The body still has to cooperate (§3.4); a body that completes after the timer fired returns its
value (Kotlin documents the opposite race as losing the value). A typed `Timeout` error instead
of `T?` is open (**D9**).

### 3.8 Context and allocators

The original §3.5 library `Context` (a parent chain of type-keyed slots, `current_context()`,
`ctx.with(v)`, `spawn_in`) is replaced by RFC-038, which is implemented: `context` fields,
rebinding with `context(f = v) { }`, no context values (E2149), `or_global` removed. A
request-scoped value is a field rebound around the work:

```flang
pub context request_id: u64 = 0

context(request_id = next_id(), logger = &req.log) {
    concurrent { s => handle(s, req) }       // every child reads context.request_id
}
```

**What a child inherits.** A structured child runs under its scope's link, so it sees every field
its parent saw, including `allocator` and `temp_allocator`. Those default to the global
(malloc) allocator, which is thread-safe; an arena, fixed-buffer or tracking allocator is not.
Rebinding `allocator` to an arena and then starting parallel children is a data race the type
system does not see (spec §3.6). Options (**D6**):

- (a) Children inherit as is; document the race; a `SyncAllocator` wrapper is a required
  sibling feature before servers use arenas.
- (b) `concurrent` rebinds `temp_allocator` per task to a task-local arena it frees at task end.
- (c) A field (or allocator vtable flag) marks an allocator thread-safe, and `concurrent` panics on a
  child starting under one that is not.

Recommendation: (a) with (b) for `temp_allocator`, since a per-request temp arena is the field's
purpose. Separately: a null `&Allocator` resolves to the current context per call (spec §4.1
rule 2), so a zero-initialized container grown in a child reaches the child's allocator.

**Runtime memory.** Stacks and task slots come from the runtime's reservation pool, not from
`context.allocator`, so a scope does not need an allocator argument. The original
`spawn(&alloc, ...)` conflicted with two project rules (allocator last; no pass-through
allocators in `compiler/` and `lib/*`); a caller wanting another allocator rebinds the context.

**RFC-098.** A separately compiled library adds context tails; a structured child shares them
with its parent's link and needs no snapshot.

### 3.9 Detached work

Kotlin's `GlobalScope.launch` has no parent job. In FLang, detached work is the case where by-reference
captures and borrowed `fn` values dangle, and where RFC-038 §Semantics 4 says the task starts from
the root context plus the fields its spawn names.

Arguments cannot cross the way the original draft proposed (`spawn(alloc, args..., f)` with a
deep copy): variadic parameters are one element type (spec §7.1), and there is no general deep
copy. Two shapes would work:

- **Owned argument, non-capturing body** (expressible except the "no captures" check, which is a
  new rule or a `#foreign fn`-like type): `detach(arg: move $A, body: fn(move A))`. The body
  rebinds the fields it needs from `arg`.
- **Owning closures**, which RFC-037 lists as out of scope.

Recommendation (**D7**): no detached work in v1. A server's accept loop is a long-lived
`concurrent` scope; per-connection work is a child of it (§3.10).

### 3.10 Starting the runtime

`main` is an ordinary function; it is not a coroutine and the runtime is not running when it
starts. Concurrency always begins by opening a `concurrent` scope, and the runtime is a stdlib
feature that the first such scope starts:

- **Off the runtime** (a thread that is not a runtime worker running a coroutine: `main`'s thread,
  a test, a C callback), `concurrent` starts the runtime if none is running, runs `body` as a
  coroutine on it, and blocks the calling OS thread until the scope has joined. This is Kotlin's
  `runBlocking`.
- **On the runtime** (inside a coroutine), `concurrent` creates a child scope and suspends the
  current coroutine until it joins; the worker thread stays free. This is Kotlin's
  `coroutineScope`.

Kotlin keeps these as two functions because colouring decides which one a call site may use, and
documents `runBlocking` from a suspend function as a thread-starvation hazard. Without colouring,
the caller cannot know which side it is on, so one function checks at run time. Calling
`concurrent` in a coroutine never blocks a worker.

Illustrative (`std.net.http` and its `Server` are not designed yet):

```flang
// A library: run() is not awaitable and looks synchronous to its caller.
pub fn run(self: &Server) {
    concurrent { s =>                 // starts the runtime if none is running
        loop {
            const conn = self.listener.accept().await() match {
                Ok(c) => c,
                Err(_) => break,
            }
            s.spawn { self.handle(conn) }   // §4.3 has the capture hazard here
        }
    }                                 // blocks main's thread until the accept loop ends
}

// An application: no runtime setup, no async main.
pub fn main() {
    const server = http.server(8080)
    server.run()
}
```

Every library on the stdlib runtime does the same, so an HTTP server, a client and an
application share one runtime with nothing to configure. A library called from inside a
coroutine nests its scope in the caller's job tree, so cancelling the caller's scope reaches the
library's tasks.

The outermost scope's job has `non_cancellable` as its parent, the default of `context.job`.
The body runs on a worker under the caller's context link; the caller's frames stay alive because
the caller is blocked, so the reads are safe (§3.1). With no detached work (D7), every task has
joined when the outermost `concurrent` returns, so `main` returning has nothing to drain.

Open (**D11**):

- **Awaiting off the runtime.** `sleep(10).await()` or `ch.recv().await()` in plain `main`, with
  no scope open. Options: block the OS thread (the operation runs synchronously); panic; or wrap
  it in an implicit one-shot `concurrent`. Recommendation: block the thread, so a function using
  awaitables works whether or not its caller opened a scope (Motivation 2).
- **Runtime lifetime.** Once started, the runtime lives for the process (idle workers park), or
  it shuts down when the last outermost scope joins and restarts on the next. Recommendation:
  live for the process; starting worker threads per call is expensive.
- **Several OS threads** opening outermost scopes at once share one runtime. Start-up must be
  once-only and thread-safe; each caller blocks on its own scope.
- **Configuration.** How a program picks the worker count before the first scope starts, given
  `FLANG_WORKERS` and no runtime-init call in `main`.

### 3.11 Dispatchers and blocking calls

v1 has one worker pool. A `#foreign` call that blocks (a syscall, a C library) blocks its worker.

**D8**: whether there is a `blocking { ... }` helper that moves the current coroutine to an
elastic pool for the duration (Kotlin's `Dispatchers.IO`), a `#foreign_blocking` directive, or
nothing in v1; and whether a scope can name its executor through a `context` field (Kotlin's
`withContext(dispatcher)`), which would need the runtime to migrate a coroutine on rebind.

### 3.12 Soundness model

Spec §3.6 leaves data races to the programmer. Within that, the rules are:

1. **A task lives inside its scope.** Its closure may capture by reference because the scope
   joins it. Enforcement of "a `Task` does not leave its scope" is **D3**.
2. **No detached closures** (D7). Nothing borrowed crosses a boundary the scope does not
   enclose.
3. **Channel transfer is a `move`**, checked by E2123.
4. **A task must be awaited**, checked by W2006 on its `owned` field.
5. **Shared allocators** follow D6.
6. **Foreign thread-locals do not follow a coroutine** across workers. The context switch saves
   and restores `errno`; any other C thread-local is unreliable after a suspension.

### 3.13 Leak and lifetime model

Unchanged from the original draft. `defer x.deinit()` applies inside tasks. Memory a task
allocates through `context.allocator` and forgets to release is charged to that allocator.
Ending a coroutine releases nothing on its own. A tracing allocator that reports outstanding
allocations at `deinit` is a debugging aid, not part of this RFC.

### 3.14 Rejected: stackless state machines (SFEX-style)

Reference: <https://vittorioromeo.com/index/blog/sfex_coroutine.html>.

The SFEX post describes a stackless coroutine where a coroutine *is* a struct, its state *is* one
integer, and suspension *is* a controlled return. Allocation is the parent's choice (inline, arena,
pool), which is attractive next to a stack and a shared state record per task. With compiler
support the lowering could be done for the user: lift locals into a state struct, lower the body
into a `switch`-driven resume function, and do it for any function that transitively reaches a
suspension point, so signatures stay uncoloured.

**Decision (2026-11-10): rejected; the runtime is stackful (§3.1).** The requirement is `.await()`
with no colouring. Transitive lowering does not stay uncoloured past three cases:

- **Function values.** A call through an `fn` value has no known target. Either every function
  value is assumed to suspend (every one pays), or suspension becomes part of the function type,
  which is colouring. Kotlin takes the second path: suspend function types.
- **Foreign calls.** A `#foreign` callee is never lowered, so a C callback that reaches a
  suspending FLang function cannot suspend.
- **Recursion.** A recursive suspending function has an unbounded frame; it must box its
  recursive calls, and that shows at the call site.

The alternatives were: (1) stackful; (2) stackless with machines written by hand, an enum plus a
`step` function; (3) stackless with compiler-generated machines, which adds the cases above plus
references across a suspension point (a frame holding a reference into itself cannot move),
defers live at a suspension point, and which context a resumed frame sees. Only (1) meets the
requirement.

**State machines in application code** do not need async. One that runs several transitions in
one go is a state variable, a labeled `loop` and a `match` (RFC-042 §4). One that waits between
steps is a function: load the state, run until it must wait, store it, return.

---

## 4. Worked examples

Illustrative: they call the proposed `std.task`, `std.net.http` and channel APIs, none of which
exist. The syntax around them is current FLang.

### 4.1 Parallel fetch with a per-URL timeout

```flang
import std.task
import std.net.http            // proposed: get(url) GetOp; await: Result(Response, HttpError)

pub type FetchError = enum { Http(HttpError), Timeout }

fn count_words(url: String) Result(i64, FetchError) {
    const got = with_timeout(5_000) { http.get(url).await() }
    const response = got match {
        Some(Ok(r)) => r,
        Some(Err(e)) => return Err(Http(e)),
        None => return Err(Timeout),
    }
    defer response.deinit()
    return Ok(word_count(response.body()))       // an ordinary function; no annotation
}

pub fn total_words(urls: String[]) i64 {
    return concurrent { s =>
        let tasks = list(urls.len)
        for url in urls { tasks.push(s.spawn { count_words(url) }) }   // captures url by ref
        let total: i64 = 0
        loop {
            const t = tasks.pop() match { Some(t) => t, None => break }
            total += t.await().unwrap_or(0)
        }
        tasks.deinit()
        total
    }
}
```

What it shows: no annotation on any function; captures in `spawn` bodies; awaiting consumes each
task; the timeout is a child scope; cancellation from `with_timeout` reaches `http.get` as a
value. `tasks` holds `Task`s in an ordinary `List`, which D3 may restrict (RFC-099 bans
stack-only types as generic arguments outside `#stack` bindings).

### 4.2 Streaming producer and consumer

```flang
pub fn count_non_blank_lines(reader: &Reader) i64 {
    let lines = channel(64)
    defer lines.deinit()
    return concurrent { s =>
        const producer = s.spawn {          // D2: with a result-less builder, no binding
            loop {
                reader.read_line() match {
                    Ok(Some(line)) => {
                        if lines.send(line).await().is_err() { break }
                    },
                    else => break,
                }
            }
            lines.close()
        }
        let count: i64 = 0
        loop {
            lines.recv().await() match {
                Ok(line) => {
                    if line.view().trim().len > 0 { count += 1 }
                    line.deinit()
                },
                Err(_) => break,
            }
        }
        producer.await()
        count
    }
}
```

What it shows: an element type inferred from the first `send`; ownership of each `OwnedString`
moving through the channel; drain-until-closed. With only `spawn` (D2), the producer's
`Task(void)` must be bound and awaited, or W2006 fires.

### 4.3 Request handler with context

```flang
pub context request_id: u64 = 0

pub fn serve(listener: &Listener) {
    concurrent { s =>
        loop {
            const conn = listener.accept().await() match {
                Ok(c) => c,
                Err(_) => break,
            }
            s.spawn {                         // D2: a result-less builder would fit here
                context(request_id = next_request_id()) {
                    handle(conn)              // reads context.request_id and context.logger
                }
            }
        }
    }
}
```

What it shows: request-scoped state is a `context` rebind, not a context value; every nested
scope inherits it. `conn` is captured by reference by a task that outlives the loop iteration
binding it, which is exactly the hazard D3 and D7 must settle: as written, the next `accept`
rebinds `conn` while the previous task may still read it. A sound form moves `conn` into the
task, which needs owning closures or an argument-passing `spawn`.

---

## 5. Implementation

Three layers: **runtime (C)**, **stdlib (FLang)**, **compiler (small)**.

### 5.1 Runtime: C (`stdlib/std/runtime/`)

Companion `.c` files follow the existing build-cache convention (`docs/architecture.md`
§Build Cache); platform files are gated with `#if(platform.os == ...)` on the FLang side and
`#ifdef` on the C side.

1. **Context switching.** `ucontext` first (POSIX); fcontext-style assembly for x86_64 and arm64
   later; Fibers on Windows.
2. **Stacks.** A virtual reservation per coroutine with a guard page at its base; the OS commits
   pages as they are touched. Overflow is SIGSEGV on the guard, reported with a diagnostic.
3. **Scheduler.** A `Worker` per OS thread; a fixed 256-slot Chase–Lev deque, overflow to a global
   queue; random-sibling stealing; parking on `pthread_cond_t` / `WaitForSingleObject`.
4. **Netpoller.** io_uring (Linux ≥ 5.6) with an epoll fallback chosen by a startup probe; kqueue
   on macOS and BSD; IOCP on Windows. The abstraction is completion-oriented; readiness backends
   emulate completion on the worker side.
5. **Timer wheel.** Hierarchical, 1 ms tick, per worker, merged on idle.
6. **Atomics.** `stdlib/std/atomic.c` for job state and task completion.
7. **Jobs.** A job record per scope: parent pointer, cancelled flag, child count, waiter list.

C surface (sketch; names not final):

```c
void*  flang_coro_spawn(void (*entry)(void*), void* arg, size_t stack_size);
void   flang_coro_yield(void);
void   flang_coro_park(void);                    /* suspend until woken */
void   flang_coro_wake(FlangCoro* c);

FlangJob* flang_job_new(FlangJob* parent);
void      flang_job_cancel(FlangJob* j);         /* descendants too */
bool      flang_job_is_cancelled(const FlangJob* j);
void      flang_job_join(FlangJob* j);           /* wait for every child */

void flang_net_submit(/* op */, FlangCoro* waiter);
void flang_timer_after(int64_t ms, FlangCoro* waiter);

bool flang_runtime_on_worker(void);              /* inside a runtime coroutine? */
void flang_runtime_ensure_started(void);         /* once-only, thread-safe (D11) */
```

**Entry.** Unchanged. The C backend's `main` (`lib/flang_codegen/src/c_backend.f`) keeps passing
the root context's address to the constant initializers and calling FLang `main` (spec §4.4).
`concurrent` starts the runtime on first use (§3.10), and test blocks reach it the same way.

### 5.2 Stdlib: FLang

New modules: `std.task` (`Scope`, `Task`, `Job`, `concurrent`, `spawn`, `await`, `cancel`,
`check_cancelled`, `yield_now`, `with_timeout`, `sleep`), `std.channel` (`Channel` and its
operations). Names are proposals.

Updated: `std.io` and `std.net` gain operations that suspend through the netpoller. Whether the
blocking variants stay is open (§8 q2).

`Task(T)` and `Channel(T)` are generic types under the usual monomorphization. `Task(T)` does not
implement `op_deref`: it would hide `.await()`.

### 5.3 Compiler

Nothing is required for v1:

- **Entry point unchanged**: the runtime starts lazily (§3.10).
- **Nothing for suspension.** No AST nodes, no keywords (`await` is a method name), no
  state-machine transform.
- **Depending on decisions:** a `concurrent { }` block construct (D1); `#stack` from RFC-099 or a
  runtime check (D3); a "no captures" rule or owning closures (D7).
- **Optional later:** `#no_suspend`, an assertion that an annotated function cannot reach a
  suspension point. It is opt-in and never required of callers, so it is not colouring.

The original draft's `src/FLang.Codegen.C/` and `src/FLang.Frontend/` paths named the retired C#
compiler.

### 5.4 Build

- Runtime `.c` files join the build cache; platform files are selected by target.
- `-lpthread` on POSIX; what IOCP needs on Windows.
- `flags_hash` already covers target changes.

---

## 6. Phases

The original Phase 0 (wait for self-host) is met. Each phase lands with harness tests under
`tests/harness/async/` and its colocated `test {}` blocks.

1. **Runtime skeleton.** One worker, `ucontext`, spawn / yield / park / wake. C unit tests.
2. **Scopes, tasks, jobs.** `concurrent`, `spawn`, `await`, `cancel`, `check_cancelled`, the `job`
   context field, lazy runtime start. Requires D1-D5, D10 and D11.
3. **Channels.** Rendezvous and buffered, `close`.
4. **Work-stealing and timers.** Multiple workers, the timing wheel, `sleep`, `with_timeout`.
   Requires D6.
5. **Netpoller.** Async file and socket operations in `std.io` / `std.net`. Requires D8.
6. **HTTP.** `std.net.http` client and server (the Linear project's goal).
7. **Docs.** A concurrency section in `docs/spec.md`, error codes in `docs/error-codes.md`, the
   runtime in `docs/architecture.md`.

---

## 7. Open decisions

None of these is decided. Each gives the options and this draft's recommendation.

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D1 | Scope form | (a) stdlib function `concurrent { s => }`, E1054 applies; (b) block construct `concurrent { }` with `return`/`break`/`?` acting on the enclosing function; (c) (a) now plus non-local return later | (a) for v1; it needs no compiler change |
| D2 | Builder count and names | (a) one `spawn` returning `Task(T)`, `Task(void)` awaited or released; (b) `spawn` plus a result-less `go`/`launch` the scope joins; (c) other names | (b): fire-and-join work is common and a `Task(void)` to await is noise |
| D3 | A task escaping its scope | (a) RFC-099 `#stack` on `Task`/`Scope`; (b) a runtime generation check that panics; (c) document only | (b) for v1, (a) when RFC-099 lands; note RFC-099 also bans `List(Task)` outside `#stack` bindings |
| D4 | `.await()` result and cancellation | (a) `T`, cancellation as values from leaf primitives; (b) `Result(T, Cancelled)` from every await | (a) |
| D5 | Fail-fast vs supervision | (a) `concurrent` supervises, `try_concurrent` fails fast; (b) `concurrent` fails fast (Kotlin), restricted to `Result` bodies | (a) |
| D6 | Allocators in parallel children | §3.8 (a), (b), (c) | (a), with (b) for `temp_allocator` |
| D7 | Detached work | (a) none in v1; (b) `detach(arg: move A, body: fn(move A))` with a no-capture rule; (c) wait for owning closures | (a) |
| D8 | Dispatchers and blocking | `blocking { }` offload, `#foreign_blocking`, a context field naming the executor, or nothing in v1 | `blocking { }` in Phase 5; executor choice later |
| D9 | Composition surface | an `Awaitable` contract; `race`/`any`/`select` signatures; `for v in ch`; `with_timeout` returning `T?` or `Result(T, Timeout)` | decide with Phase 2/3 |
| D10 | Panics in tasks | process exit always; under `flang test`, fail the test from the coroutine stack without `longjmp` across stacks | needs design before Phase 2 |
| D11 | Runtime start and edges | awaiting off the runtime (block the thread, panic, or implicit scope); runtime lifetime (process vs outermost scope); worker-count configuration before first start (§3.10) | block the thread; live for the process |

## 8. Other open questions

1. **Channel double close**: panic (Go) or `Result`. Panic recommended.
2. **Sync I/O**: keep blocking variants in `std.io`, or make every I/O operation an awaitable that
   blocks the thread when awaited off the runtime (D11).
3. **Stack size.** A C stack cannot move once raw pointers point into it, so "start small and
   grow" is unavailable. Proposal: a 1 MiB reservation, touched pages committed. Open: the
   default, a per-`spawn` override, the Windows path (`VirtualAlloc(MEM_RESERVE)` plus a guard
   page).
4. **Workers**: default CPU count, `FLANG_WORKERS` overrides.
5. **Stdlib globals.** `std/test.c` and `std/profile.c` describe themselves as single-threaded
   "like the FLang runtime"; every mutable global in the stdlib needs an audit before M:N.

## 9. Risks

- **`ucontext` is slow and deprecated on some platforms.** Accept for v1; replace with assembly.
- **Stack overflow without a working guard page corrupts a neighbour.** Test the guard per
  platform.
- **Shared allocators** (D6) are a sharp edge until a `SyncAllocator` exists.
- **Captures across iterations** (§4.3): a task capturing a loop binding by reference sees it
  rebound. The scope keeps the frame alive, not the value.
- **Uncooperative children** delay their awaiters and their scope (D4).
- **Channel copy-in** costs a `memcpy` per message; zero-copy is later.
- **Debugging.** Coroutine stacks do not show in gdb backtraces without coroutine-aware
  printers.
- **`errno` and thread-locals.** A coroutine can resume on another worker; the switch saves and
  restores `errno`, and other C thread-locals are unreliable across a suspension.
- **Blocking foreign calls** starve their worker until D8 is settled.

## 10. Out of scope

- Async iterators and streams beyond `Channel`.
- `select` as syntax (a helper is D9).
- `SyncAllocator` (a separate ticket; D6 depends on it).
- Typed cancellation reasons beyond `Cancelled`.
- Growable stacks (§8 q3).
- `#no_suspend`.

## Sources

Kotlin behaviour cited in §2 and §3, from kotlinlang.org:

- Coroutines basics: <https://kotlinlang.org/docs/coroutines-basics.html>
- Exception handling and supervision: <https://kotlinlang.org/docs/exception-handling.html>
- Context and dispatchers: <https://kotlinlang.org/docs/coroutine-context-and-dispatchers.html>
- Channels: <https://kotlinlang.org/docs/channels.html>
- API: [`runBlocking`](https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines/run-blocking.html),
  [`CoroutineScope`](https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines/-coroutine-scope/),
  [`Job`](https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines/-job/),
  [`Deferred`](https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines/-deferred/),
  [`withTimeout`](https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines/with-timeout.html),
  [`ensureActive`](https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines/ensure-active.html),
  [`NonCancellable`](https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines/-non-cancellable/),
  [`CoroutineDispatcher`](https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines/-coroutine-dispatcher/)

The cancellation-and-timeouts guide page could not be retrieved while this revision was written;
its claims here rest on the API pages above.
