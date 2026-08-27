# Concurrency patterns vs. stack-only handles

Working notes for RFC-025. The question each pattern answers: *where do the
handles live, and does the lifetime rule accept it?*

A handle is stack-only: it cannot be returned, stored in an ordinary container,
or captured. It *can* go into a binding marked `#stack`, which cannot leave the
block either. Every verdict below is that one rule, and none of it requires the
compiler to know any value's lifetime.

Summary:

| # | Pattern | Handle storage | Verdict |
|---|---|---|---|
| 1 | Fork-join, fixed arity | named locals, or `#stack` array | works today |
| 2 | Divide and conquer | two locals per frame | works today |
| 3 | Uniform fan-out | none (`join_all`) | works today |
| 4 | Dynamic fan-out, bounded | `List` under a `#stack` binding | **needs E2124 relaxed** |
| 5 | Keyed fan-out | `Dict` under a `#stack` binding | **needs E2124 relaxed** |
| 6 | Join as they complete | one local at a time | needs `join_any` |
| 7 | Race / first wins | one local at a time | needs `join_any` + cancellation |
| 8 | Worker pool | none (channel) | works, different mechanism |
| 9 | Phased | fresh block per phase | works today |
| 10 | Scope passing | `#stack` parameter | works, and is the reason §1.2 exists |
| 11 | Unbounded dynamic fan-out | nowhere valid | **does not work, by design** |

---

## 1. Fork-join, fixed arity

Known number of branches, all results used.

```flang
concurrent {
    #stack const hs = [spawn parse(a), spawn parse(b), spawn parse(c)]
    combine(join(hs[0]), join(hs[1]), join(hs[2]))
}
```

The array is inline and `#stack`-bound, so its lifetime equals its elements'.

## 2. Divide and conquer

Recursive halving with a sequential cutoff. Covered in RFC-025 §3.2. Handles
never cross a frame boundary because each level joins before it yields, so depth
never enters the analysis.

## 3. Uniform fan-out

N chunks, same function, results folded. No handle is ever named:

```flang
concurrent {
    for i in 0..workers { spawn sum_slice(chunk(data, i, workers)) }
    sum_slice(join_all())
}
```

## 4. Dynamic fan-out, bounded

The first pattern that actually needs a container. The count is data driven, but
you are willing to cap it.

```flang
concurrent {
    let backing = [0u8; 8192]
    let fba     = fixed_buffer_allocator(backing)
    #stack const scratch  = fba.allocator()
    #stack let   handles  = list(0, &scratch)

    for job in queue {
        if !job.ready { continue }
        handles.push(spawn run(job))
    }

    let total = 0
    for &h in handles { total += join(h.*) }
    total
}
```

The `#stack` on `handles` is what makes this legal: the list cannot leave the
block, so the handles in it cannot either. The allocator does not enter into the
safety argument at all (addendum A). The one thing RFC-025 has to absorb is that
`List(Deferred(T))` puts a stack-only type in a generic argument, which E2124
forbids outright today.

The `#stack` on `scratch` is doing separate work, and the stdlib already asks
for it in a comment:

> Initialize a FixedBufferAllocator from a pre-allocated buffer. This allocator
> should not outlive the provided buffer.
> (`stdlib/std/allocator.f`)

Overflow is the operational risk, not the safety one. `FixedBufferAllocator`
returns null when the buffer is exhausted, and `List` growth panics on a failed
allocation. A cap you picked by guessing becomes a crash under load. Either size
the buffer from a bound you can prove (`queue.len`), or handle the failure.

## 5. Keyed fan-out

Same trick, different container. Results wanted by key rather than by position:

```flang
concurrent {
    let backing = [0u8; 16384]
    let fba     = fixed_buffer_allocator(backing)
    #stack const scratch = fba.allocator()
    #stack let   pending = dict(hosts.len, &scratch)   // Dict(String, Deferred(Response))

    for host in hosts { pending.insert(host, spawn fetch(host)) }

    #stack let out = dict(hosts.len, &scratch)
    for &kv in pending { out.insert(kv.key, join(kv.value)) }
    out                                  // E2125: cannot leave the block
}
```

Note the last line. `out` is a `#stack` binding, so it cannot be returned, and
that is the annotation doing its job rather than an inference about the buffer.
Returning results means copying into a caller-owned allocator, which is the
honest cost and should be visible:

```flang
    dict_copy(&out, caller_alloc)
```

## 6. Join as they complete

Long tail work where you want to start using early results rather than waiting
for the slowest.

```flang
concurrent {
    for job in jobs { spawn run(job) }
    loop {
        const r = join_any()             // Deferred result, or done
        if r.is_none() { break }
        emit(r.unwrap())
    }
}
```

Only one result is live at a time, so there is nothing to store and nothing for
the lifetime rule to reject. What this needs is a `join_any` primitive returning
results in completion order. Not specified anywhere yet.

## 7. Race / first wins

Speculative execution, timeouts, redundant backends.

```flang
concurrent {
    spawn from_cache(key)
    spawn from_origin(key)
    join_any().unwrap()                  // losers cancelled at block exit
}
```

Lifetime-wise this is pattern 6 with an early exit. The hard part is the exit:
the block cannot leave with tasks outstanding, so the losers must be cancelled
and awaited. That is cancellation semantics, which RFC-005 §3.7 lists as open.

## 8. Worker pool

Fixed workers pulling from a queue, work items arriving over time. Handles do not
appear at all; the coordination is a channel, and the fan-out is `workers`, not
`items`.

```flang
concurrent {
    for _ in 0..workers { spawn drain(&inbox) }
    join_all()
}
```

Lifetime-clean, and the natural answer to pattern 11. The channel needs to be
frame-bound or outlive the block, and either is expressible.

## 9. Phased

Waves that depend on the previous wave's results. Each phase is its own block:

```flang
const stage1 = concurrent { for x in xs { spawn prepare(x) }; collect(join_all()) }
const stage2 = concurrent { for y in stage1 { spawn refine(y) }; collect(join_all()) }
```

Works because `collect` copies results out into a caller-owned allocator, so
`stage1` is an ordinary value with no frame binding. Skipping the copy and
passing the raw `join_all()` slice into the next block is E2125, correctly: the
first block's slab is gone.

## 10. Scope passing

A helper that spawns into *the caller's* block, which is how a data-driven walk
avoids opening a block per node.

```flang
fn walk(#stack scope: &Scope, node: &Node) {
    scope.spawn(process(node))
    for &child in node.children { walk(scope, child) }
}

concurrent {
    walk(current_scope(), root)
    join_all()
}
```

The `#stack` parameter marker is what makes this sound: it says `walk` will not
retain the scope, which lets a caller pass something frame-bound. Without the
binding-level form from RFC-025 §1.2 this pattern has no safe spelling.

Note the tasks outlive `walk`'s own frame, and that is fine. They are bound to
the block, not to the function that spawned them.

## 11. Unbounded dynamic fan-out

Spawn per item, unknown and unbounded count, all handles held at once. This is
the pattern that does not work, and should not:

```flang
concurrent {
    let handles = list(0, &heap_alloc)   // E2124: not a #stack binding
    for item in stream { handles.push(spawn run(item)) }
    ...
}
```

Marking it `#stack` would make it compile, and would also make it useless for
the thing the author wanted, which was to keep the handles past the block.

There is no clever fix, because the request is incoherent: unbounded concurrency
with all handles retained means unbounded memory and unbounded task count, which
is a resource bug wearing a lifetime bug's clothing. The three real answers:

1. Bound it (pattern 4).
2. Do not retain handles (patterns 3, 6).
3. Bound the *workers* instead of the work (pattern 8).

If a caller genuinely needs a handle that outlives its creating scope, that is a
different type: a heap-allocated, refcounted task record, not a stack-only
handle. That belongs in RFC-005 as a deliberate second tier, if it is wanted at
all, and it should be more verbose to write than the stack-only one.

---

# Addendum: what patterns 4 and 5 add to RFC-025

## A. The allocator is not what makes it sound

Tempting conclusion from patterns 4 and 5: a container's lifetime should be
derived from its allocator's, so `list(cap, &frame_bound_alloc)` is frame-bound.
That works, and it is what C# would do, and it requires knowing the lifetime of
every ordinary value in the chain (`backing`, `fba`, `scratch`). That is full
lifetime analysis, which RFC-025 §2.1 rejects.

The cheaper answer is also the correct one: **the `#stack` on the container is
what makes it sound, not the allocator.** `handles` cannot leave the block, so
nothing inside it can either, whatever allocator produced the bytes. The
compiler never needs to know where the memory came from.

Consequences worth being explicit about:

- `#stack let h = list(0, &global_allocator)` is sound. Wasteful, since the
  memory outlives its only user, but not unsafe.
- The fixed buffer in patterns 4 and 5 is an *allocation* decision (no malloc in
  the hot path, bounded memory), not a safety one. Do not let the two get
  conflated in the docs.
- `#stack` on `scratch` is not required for handle safety. It earns its place by
  catching a different bug: returning an allocator whose buffer has died.

## B. E2124 has to be relaxed

`List(Deferred(i64))` is a stack-only type as a generic argument, banned outright
today. C# bans it too and reopened the door with an explicit opt-in:

> The `allows ref struct` anti-constraint declares that the corresponding type
> argument can be a `ref struct` type. [...] The generic type or method must obey
> ref safety rules for any instance of `T`.

C# puts the opt-in on the type parameter because it checks a generic body once,
at its definition, and that body might box `T` or stash it in a static field.

RFC-025 puts the opt-in at the *use site* instead: a stack-only type argument is
admissible exactly when the resulting binding is `#stack`. No constraint kind, no
analysis of the generic body, and no per-instantiation checking either. The
binding's own restriction covers whatever the container does internally, because
the container cannot leave the block.

## C. Deinit interacts

A `List` over a `FixedBufferAllocator` needs no `deinit`, since `fixed_dealloc`
is a no-op and the buffer dies with the frame. Calling `deinit` anyway is
harmless but pointless. Whatever RFC-016 (auto-deinit) does should recognise
that a frame-bound container has nothing to release, or every one of these
patterns picks up a dead call in the generated C.
