---
status: draft
type: compiler
created: 2026-10-18
relates: [RFC-037, RFC-038]
---

# RFC-041: Native calling convention

## Summary

The `flang` calling convention for a backend that emits machine code directly. Small aggregates
cross a call in registers, split into their scalar fields; larger ones cross by address, as every
aggregate does today. The C backend keeps today's convention: what this RFC needs is below what C
can express, and the C backend exists to get the language running, not to tune its calls.

## Motivation

- **Every aggregate crosses by address today**, whatever its size (spec 3.2): the caller stores it
  in a stack slot, the callee loads it back. A slice, a `String`, a `Range`, an RFC-037 `fn` value
  and a two-field struct all pay a memory round trip on every call that is not inlined, and an
  aggregate result returns through an out-pointer.
- **C cannot say what we want.** Its only by-value aggregate is a C struct, classified by each
  platform's rules: two registers for 16 bytes on SysV and AArch64, an address on Win64. Splitting
  a struct into scalar arguments in the generated C changes every signature and call for a gain
  the C compiler partly recovers by inlining anyway. A native backend controls the registers
  itself, and the decision belongs there.

## Design

### Hidden parameters

As RFC-037 and RFC-038 set them: `R f(args..., ctx, env)`. The user's arguments take the argument
registers first; the hidden ones spill first, `env` before `ctx`.

### Parameters

- **A scalar** (integer, float, pointer, reference, `bool`, `char`, payload-less enum) goes in the
  next register of its class, integer or float, then on the stack.
- **An aggregate of at most two scalar fields** is split: each field is passed as a scalar of its
  own, in order. A slice is `ptr, len`; an RFC-037 `fn` value is `code, env`; `(i32, f64)` takes
  one integer and one float register. Nested aggregates are flattened first, so a struct holding a
  slice counts two scalars.
- **Anything larger** crosses by address, as today, with spec 3.2's copy-on-write unchanged.

A split aggregate the body writes or lets escape is rebuilt in a frame slot from its scalars, the
same shadow a by-address parameter gets today.

### Results

- A scalar returns in the first return register of its class.
- An aggregate of at most two scalar fields returns split, in the first two return registers of
  each field's class.
- Anything larger returns through an out-pointer the caller provides, as today.

### Foreign calls

`#foreign` functions keep the platform's C convention, which the native backend implements for
them alone: SysV, AAPCS64 and Win64 aggregate classification, as `agg_abi_safe` gates today.

### Precedent

- Rust passes a slice or a `&dyn` as two scalar arguments on every target, independent of the
  platform's C rules, and larger aggregates by address.
- Go's register ABI assigns a struct's fields to registers one by one, falling back to the stack
  when they do not fit.
- Swift expands small structs into up to four registers, and returns up to four.

## Interaction with spec 3.2

Spec 3.2 guarantees value semantics, not a crossing: whether a read-only parameter shares the
caller's storage is unspecified. A split aggregate needs no spec change; its `&p` names the
callee's own slot.

## Plan

Lands with the native backend; nothing changes before it. The C backend keeps passing every
aggregate by address and returning it through an out-pointer.

## Alternatives considered

- **Split in the generated C now.** Possible for parameters, but C returns at most one scalar, so
  results would still go through a C struct and the platform's rules. Rejected for the C backend:
  ABI work on a backend that is temporary.
- **C structs by value in the generated C.** Relies on per-platform classification and on layout
  agreement for every type that crosses; Win64 gains nothing at 16 bytes.
- **By address everywhere, natively too.** Simplest, and the cost is real on the types that cross
  most often.

## Open questions

- **The cutoff:** two scalars, or four as Swift?
- **Niches:** does `Option(&T)` count as one scalar (null as `None`)?
- **A pinned `ctx` register** (RFC-038 defers it here): takes `ctx` out of the argument sequence
  altogether. Which register, and is it callee-saved?
