import std.allocator
import std.dict
import std.list
import std.option
import std.set
import std.test

// =============================================================================
// Iterator combinators.
//
// Anything with a `next(&Self) T?` (and an `iter(&Self) Self` so `for` can consume it) is an
// iterator. Adapters below wrap an iterator and are themselves iterators, so they chain:
// `xs.iter().filter(f).map(g).to_list()`.
//
// Callables are duck-typed `$F` parameters (RFC-014): bare functions, non-capturing lambdas, and
// capturing closures all work, and lambda
// parameter/return annotations are optional — types flow from the element
// type at instantiation.
// =============================================================================

// =============================================================================
// Filter
// =============================================================================

type FilterIter = struct(I, F) {
    it: I
    f: F
}

pub fn iter(self: &FilterIter($I, $F)) FilterIter(I, F) {
    return self.*
}

pub fn next(self: &FilterIter($I, $F)) $T? {
    loop {
        let v = self.it.next()
        if v.is_none() {
            return null
        }
        let x = v.unwrap()
        if self.f(x) {
            return Some(x)
        }
    }
}

pub fn filter(it: $I, f: $F) FilterIter(I, F) {
    return .{ it = it, f = f }
}

// =============================================================================
// Map
// =============================================================================

type MapIter = struct(I, F) {
    it: I
    f: F
}

pub fn iter(self: &MapIter($I, $F)) MapIter(I, F) {
    return self.*
}

pub fn next(self: &MapIter($I, $F)) $U? {
    let v = self.it.next()
    if v.is_none() {
        return null
    }
    return Some(self.f(v.unwrap()))
}

pub fn map(it: $I, f: $F) MapIter(I, F) {
    return .{ it = it, f = f }
}

// =============================================================================
// Enumerate — pairs each element with its 0-based position.
// =============================================================================

type EnumerateIter = struct(I) {
    it: I
    idx: usize
}

pub fn iter(self: &EnumerateIter($I)) EnumerateIter(I) {
    return self.*
}

pub fn next(self: &EnumerateIter($I)) (usize, $T)? {
    let v = self.it.next()
    if v.is_none() {
        return null
    }
    let i = self.idx
    self.idx = i + 1
    return Some((i, v.unwrap()))
}

pub fn enumerate(it: $I) EnumerateIter(I) {
    return .{ it = it, idx = 0 }
}

// =============================================================================
// Take / Skip
// =============================================================================

type TakeIter = struct(I) {
    it: I
    left: usize
}

pub fn iter(self: &TakeIter($I)) TakeIter(I) {
    return self.*
}

pub fn next(self: &TakeIter($I)) $T? {
    if self.left == 0 {
        return null
    }
    self.left = self.left - 1
    return self.it.next()
}

// At most the first `n` elements.
pub fn take(it: $I, n: usize) TakeIter(I) {
    return .{ it = it, left = n }
}

type SkipIter = struct(I) {
    it: I
    pending: usize
}

pub fn iter(self: &SkipIter($I)) SkipIter(I) {
    return self.*
}

pub fn next(self: &SkipIter($I)) $T? {
    while self.pending > 0 {
        self.pending = self.pending - 1
        if self.it.next().is_none() {
            self.pending = 0
            return null
        }
    }
    return self.it.next()
}

// Everything after the first `n` elements.
pub fn skip(it: $I, n: usize) SkipIter(I) {
    return .{ it = it, pending = n }
}

// =============================================================================
// Take-while / Skip-while
// =============================================================================

type TakeWhileIter = struct(I, F) {
    it: I
    f: F
    done: bool
}

pub fn iter(self: &TakeWhileIter($I, $F)) TakeWhileIter(I, F) {
    return self.*
}

pub fn next(self: &TakeWhileIter($I, $F)) $T? {
    if self.done {
        return null
    }
    let v = self.it.next()
    if v.is_none() {
        self.done = true
        return null
    }
    let x = v.unwrap()
    let keep: bool = self.f(x)
    if !keep {
        self.done = true
        return null
    }
    return Some(x)
}

// Elements until the first one `f` rejects; nothing after it.
pub fn take_while(it: $I, f: $F) TakeWhileIter(I, F) {
    return .{ it = it, f = f, done = false }
}

type SkipWhileIter = struct(I, F) {
    it: I
    f: F
    skipping: bool
}

pub fn iter(self: &SkipWhileIter($I, $F)) SkipWhileIter(I, F) {
    return self.*
}

pub fn next(self: &SkipWhileIter($I, $F)) $T? {
    if self.skipping {
        self.skipping = false
        loop {
            let v = self.it.next()
            if v.is_none() {
                return null
            }
            let x = v.unwrap()
            let skip_it: bool = self.f(x)
            if !skip_it {
                return Some(x)
            }
        }
    }
    return self.it.next()
}

// Drops the leading run `f` accepts; yields everything from the first rejected element on.
pub fn skip_while(it: $I, f: $F) SkipWhileIter(I, F) {
    return .{ it = it, f = f, skipping = true }
}

// =============================================================================
// Zip / Chain
// =============================================================================

type ZipIter = struct(I, J) {
    a: I
    b: J
}

pub fn iter(self: &ZipIter($I, $J)) ZipIter(I, J) {
    return self.*
}

// Stops at the shorter side. When `a` yields and `b` is exhausted, that
// element of `a` is consumed and lost — don't reuse `a` afterwards.
pub fn next(self: &ZipIter($I, $J)) ($A, $B)? {
    let a = self.a.next()
    if a.is_none() {
        return null
    }
    let b = self.b.next()
    if b.is_none() {
        return null
    }
    return Some((a.unwrap(), b.unwrap()))
}

pub fn zip(a: $I, b: $J) ZipIter(I, J) {
    return .{ a = a, b = b }
}

type ChainIter = struct(I, J) {
    a: I
    b: J
    on_b: bool
}

pub fn iter(self: &ChainIter($I, $J)) ChainIter(I, J) {
    return self.*
}

pub fn next(self: &ChainIter($I, $J)) $T? {
    if !self.on_b {
        let v = self.a.next()
        if v.is_some() {
            return v
        }
        self.on_b = true
    }
    return self.b.next()
}

// All of `a`, then all of `b`. The iterator TYPES may differ (chain a FilterIter with a plain
// SliceIterator); only the element type they yield
// must agree — `next` unifies the two.
pub fn chain(a: $I, b: $J) ChainIter(I, J) {
    return .{ a = a, b = b, on_b = false }
}

type ZipLongestIter = struct(I, J, A, B) {
    a: I
    b: J
    fill_a: A
    fill_b: B
}

pub fn iter(self: &ZipLongestIter($I, $J, $A, $B)) ZipLongestIter(I, J, A, B) {
    return self.*
}

pub fn next(self: &ZipLongestIter($I, $J, $A, $B)) (A, B)? {
    let a = self.a.next()
    let b = self.b.next()
    if a.is_none() {
        if b.is_none() {
            return null
        }
        return Some((self.fill_a, b.unwrap()))
    }
    if b.is_none() {
        return Some((a.unwrap(), self.fill_b))
    }
    return Some((a.unwrap(), b.unwrap()))
}

// Like `zip`, but runs to the LONGER side, substituting `fill_a` / `fill_b` for the exhausted
// iterator's elements.
pub fn zip_longest(a: $I, b: $J, fill_a: $A, fill_b: $B) ZipLongestIter(I, J, A, B) {
    return .{ a = a, b = b, fill_a = fill_a, fill_b = fill_b }
}

// =============================================================================
// Cycle
// =============================================================================

type CycleIter = struct(I) {
    start: I
    it: I
}

pub fn iter(self: &CycleIter($I)) CycleIter(I) {
    return self.*
}

pub fn next(self: &CycleIter($I)) $T? {
    const v = self.it.next()
    if v.is_some() {
        return v
    }
    self.it = self.start
    return self.it.next()
}

// Repeats the sequence forever: after the last element, the first again. Infinite unless the source
// is empty; pair it with `take`. The source must be restartable by copy, which every iterator over
// a container is.
pub fn cycle(it: $I) CycleIter(I) {
    return .{ start = it, it = it }
}

// =============================================================================
// Step by
// =============================================================================

type StepByIter = struct(I) {
    it: I
    step: usize
}

pub fn iter(self: &StepByIter($I)) StepByIter(I) {
    return self.*
}

pub fn next(self: &StepByIter($I)) $T? {
    const v = self.it.next()
    if v.is_none() {
        return null
    }
    for _k in 1..self.step {
        if self.it.next().is_none() {
            break
        }
    }
    return v
}

// Every `step`th element, starting with the first. Panics when `step` is 0.
pub fn step_by(it: $I, step: usize) StepByIter(I) {
    if step == 0 {
        panic("step_by: step must be at least 1")
    }
    return .{ it = it, step = step }
}

// =============================================================================
// Peekable
// =============================================================================

type PeekableIter = struct(I, T) {
    it: I
    // The element `next` will return, pulled one step ahead; null at the end.
    ahead: T?
}

pub fn iter(self: &PeekableIter($I, $T)) PeekableIter(I, T) {
    return self.*
}

pub fn next(self: &PeekableIter($I, $T)) T? {
    const v = self.ahead
    self.ahead = self.it.next()
    return v
}

// Returns the element the next `next` will return without consuming it, or null at the end.
pub fn peek(self: &PeekableIter($I, $T)) T? {
    return self.ahead
}

// An iterator that can look one element ahead (`peek`). Pulls the first element on construction.
pub fn peekable(it: $I) PeekableIter(I, $T) {
    // Pulled before the literal: its fields evaluate in order, and `it = it` would copy the
    // iterator before `next` advanced it.
    const first = it.next()
    return .{ it = it, ahead = first }
}

// =============================================================================
// Tap
// =============================================================================

type TapIter = struct(I, F) {
    it: I
    f: F
}

pub fn iter(self: &TapIter($I, $F)) TapIter(I, F) {
    return self.*
}

pub fn next(self: &TapIter($I, $F)) $T? {
    const v = self.it.next()
    if v.is_some() {
        self.f(v.unwrap())
    }
    return v
}

// Calls `f` on every element as it passes through, yielding the element unchanged: a look at what
// an adapter chain produces without breaking the chain.
pub fn tap(it: $I, f: $F) TapIter(I, F) {
    return .{ it = it, f = f }
}

// =============================================================================
// Scan
// =============================================================================

type ScanIter = struct(I, A, F) {
    it: I
    acc: A
    f: F
}

pub fn iter(self: &ScanIter($I, $A, $F)) ScanIter(I, A, F) {
    return self.*
}

pub fn next(self: &ScanIter($I, $A, $F)) A? {
    const v = self.it.next()
    if v.is_none() {
        return null
    }
    self.acc = self.f(self.acc, v.unwrap())
    return Some(self.acc)
}

// A running fold: yields `f(acc, x)` for every element, starting from `init`, so the last value is
// what `fold` would return. `init` itself is not yielded.
pub fn scan(it: $I, init: $A, f: $F) ScanIter(I, A, F) {
    return .{ it = it, acc = init, f = f }
}

// =============================================================================
// Uniq
// =============================================================================

type UniqIter = struct(I, T) {
    it: I
    // The next element to yield, pulled one step ahead; null at the end.
    ahead: T?
}

pub fn iter(self: &UniqIter($I, $T)) UniqIter(I, T) {
    return self.*
}

pub fn next(self: &UniqIter($I, $T)) T? {
    const cur = self.ahead
    if cur.is_none() {
        return null
    }
    loop {
        self.ahead = self.it.next()
        if self.ahead.is_none() {
            break
        }
        let same: bool = self.ahead.unwrap() == cur.unwrap()
        if !same {
            break
        }
    }
    return cur
}

// Collapses runs of consecutive `==` duplicates to one element, `sort | uniq` style; sort first for
// whole-sequence uniqueness. Pulls the first element on construction.
pub fn uniq(it: $I) UniqIter(I, $T) {
    const first = it.next()
    return .{ it = it, ahead = first }
}

// =============================================================================
// Sources
// =============================================================================

type OnceIter = struct(T) {
    value: T
    done: bool
}

pub fn iter(self: &OnceIter($T)) OnceIter(T) {
    return self.*
}

pub fn next(self: &OnceIter($T)) T? {
    if self.done {
        return null
    }
    self.done = true
    return Some(self.value)
}

// An iterator over exactly one element.
pub fn once(value: $T) OnceIter(T) {
    return .{ value = value, done = false }
}

type RepeatIter = struct(T) {
    value: T
}

pub fn iter(self: &RepeatIter($T)) RepeatIter(T) {
    return self.*
}

pub fn next(self: &RepeatIter($T)) T? {
    return Some(self.value)
}

// An iterator that yields `value` forever. Pair it with `take` or `zip`.
pub fn repeat(value: $T) RepeatIter(T) {
    return .{ value = value }
}

// =============================================================================
// Consumers
// =============================================================================

// Combine left to right: `f(f(f(init, x0), x1), x2)`.
pub fn fold(it: $I, init: $A, f: $F) A {
    let acc = init
    for item in it {
        acc = f(acc, item)
    }
    return acc
}

// Fold seeded with the first element; null when empty.
pub fn reduce(it: $I, f: $F) $A? {
    return it.next() match {
        Some(first) => Some(fold(it, first, f))
        None => null
    }
}

// Call `f` on every element, in order.
pub fn each(it: $I, f: $F) {
    for item in it {
        f(item)
    }
}

// Number of elements. Consumes the iterator.
pub fn count(it: $I) usize {
    let n: usize = 0
    for item in it {
        n = n + 1
    }
    return n
}

// Number of elements `pred` accepts.
pub fn count(it: $I, pred: $F) usize {
    let n: usize = 0
    for item in it {
        if pred(item) {
            n = n + 1
        }
    }
    return n
}

// Whether any element satisfies `pred`. False for an empty iterator. Stops at the first match.
pub fn any(it: $I, pred: $F) bool {
    for item in it {
        if pred(item) {
            return true
        }
    }
    return false
}

// Whether every element satisfies `pred`. True for an empty iterator. Stops at the first
// counterexample.
pub fn all(it: $I, pred: $F) bool {
    for item in it {
        let ok: bool = pred(item)
        if !ok {
            return false
        }
    }
    return true
}

// First element satisfying `pred`, or null.
pub fn find(it: $I, pred: $F) $T? {
    for item in it {
        if pred(item) {
            return Some(item)
        }
    }
    return null
}

// 0-based position of the first element satisfying `pred`, or null.
pub fn position(it: $I, pred: $F) usize? {
    let i: usize = 0
    for item in it {
        if pred(item) {
            return Some(i)
        }
        i = i + 1
    }
    return null
}

// Final element, or null when empty.
pub fn last(it: $I) $T? {
    let result = it.next()
    if result.is_none() {
        return null
    }
    let v = result.unwrap()
    for item in it {
        v = item
    }
    return Some(v)
}

// Returns the element at position `n`, counting from 0, or null when the sequence is shorter.
// Consumes everything up to and including it.
pub fn nth(it: $I, n: usize) $T? {
    for _k in 0..n {
        if it.next().is_none() {
            return null
        }
    }
    return it.next()
}

// Smallest element by `<`, or null when empty. Requires an ordered element type (primitive or
// `op_cmp`).
pub fn min(it: $I) $T? {
    let first = it.next()
    if first.is_none() {
        return null
    }
    let best = first.unwrap()
    for item in it {
        if item < best {
            best = item
        }
    }
    return Some(best)
}

// Largest element by `<`, or null when empty.
pub fn max(it: $I) $T? {
    let first = it.next()
    if first.is_none() {
        return null
    }
    let best = first.unwrap()
    for item in it {
        if best < item {
            best = item
        }
    }
    return Some(best)
}

// Element with the smallest `key(x)`, or null when empty. Ties keep the earliest.
pub fn min_by(it: $I, key: $F) $T? {
    let first = it.next()
    if first.is_none() {
        return null
    }
    let best = first.unwrap()
    let best_key = key(best)
    for item in it {
        let k = key(item)
        if k < best_key {
            best_key = k
            best = item
        }
    }
    return Some(best)
}

// Element with the largest `key(x)`, or null when empty. Ties keep the earliest.
pub fn max_by(it: $I, key: $F) $T? {
    let first = it.next()
    if first.is_none() {
        return null
    }
    let best = first.unwrap()
    let best_key = key(best)
    for item in it {
        let k = key(item)
        if best_key < k {
            best_key = k
            best = item
        }
    }
    return Some(best)
}

// Collect into a fresh List.
pub fn to_list(it: $I, allocator: &Allocator? = null) List($T) {
    let out: List(T) = list(0, allocator)
    for item in it {
        out.push(item)
    }
    return out
}

// Collect into a fresh Set (duplicates collapse; requires a hashable element type).
pub fn to_set(it: $I, allocator: &Allocator? = null) Set($T) {
    let out: Set(T) = set(allocator)
    for item in it {
        out.add(item)
    }
    return out
}

// Collect into a fresh Dict keyed by `key(item)`. A later item with the same key overwrites the
// earlier one.
pub fn to_dict(it: $I, key: $F, allocator: &Allocator? = null) Dict($K, $T) {
    let out: Dict(K, T) = dict(allocator)
    for item in it {
        out.set(key(item), item)
    }
    return out
}

// =============================================================================
// Tests
// =============================================================================

fn is_even(x: i32) bool { return x % 2 == 0 }

fn list123() List(i32) {
    let xs: List(i32) = list(3)
    xs.push(1i32)
    xs.push(2i32)
    xs.push(3i32)
    return xs
}

test "filter advances past non-matching elements" {
    // The non-matching head is the interesting case: `next` must skip it and keep pulling, not
    // report the iterator empty.
    let xs = list123()
    defer xs.deinit()

    let it = xs.iter().filter(is_even)
    const first = it.next()
    assert_true(first.is_some(), "the 2 is found behind the non-matching 1")
    assert_eq(first.unwrap(), 2i32, "the first even element is 2")
    assert_true(it.next().is_none(), "and nothing follows it")
}

test "filter over an all-matching and an empty list" {
    let xs: List(i32) = list(2)
    defer xs.deinit()
    xs.push(4i32)
    xs.push(6i32)
    let it = xs.iter().filter(is_even)
    assert_eq(it.next().unwrap(), 4i32, "all-matching yields in order")
    assert_eq(it.next().unwrap(), 6i32, "second element follows")
    assert_true(it.next().is_none(), "then exhausts")

    let empty: List(i32) = list(0)
    defer empty.deinit()
    let e = empty.iter().filter(is_even)
    assert_true(e.next().is_none(), "empty stays empty")
}

test "filter and map accept capturing closures with unannotated params" {
    let xs = list123()
    defer xs.deinit()

    let floor = 1
    let scale = 10
    let out = xs.iter()
        .filter(fn(x) { x > floor })
        .map(fn(x) { x * scale })
        .to_list()
    defer out.deinit()
    assert_eq(out.len, 2 as usize, "two elements pass the floor")
    assert_eq(out[0], 20i32, "first survivor scaled")
    assert_eq(out[1], 30i32, "second survivor scaled")
}

test "enumerate pairs positions with elements" {
    let xs = list123()
    defer xs.deinit()
    let it = xs.iter().enumerate()
    let first = it.next().unwrap()
    assert_eq(first.0, 0 as usize, "positions start at zero")
    assert_eq(first.1, 1i32, "paired with the first element")
    let second = it.next().unwrap()
    assert_eq(second.0, 1 as usize, "second position")
    assert_true(it.next().is_some(), "third element present")
    assert_true(it.next().is_none(), "then exhausts")
}

test "take and skip split a sequence" {
    let xs = list123()
    defer xs.deinit()

    let front = xs.iter().take(2).to_list()
    defer front.deinit()
    assert_eq(front.len, 2 as usize, "take caps the count")
    assert_eq(front[1], 2i32, "in order")

    let over = xs.iter().take(9).to_list()
    defer over.deinit()
    assert_eq(over.len, 3 as usize, "taking more than exists is fine")

    let back = xs.iter().skip(1).to_list()
    defer back.deinit()
    assert_eq(back.len, 2 as usize, "skip drops the front")
    assert_eq(back[0], 2i32, "starting after the skipped prefix")

    let none = xs.iter().skip(9).to_list()
    defer none.deinit()
    assert_eq(none.len, 0 as usize, "skipping past the end yields nothing")
}

test "take_while and skip_while cut at the first rejection" {
    let xs: List(i32) = list(4)
    defer xs.deinit()
    xs.push(2i32)
    xs.push(4i32)
    xs.push(5i32)
    xs.push(6i32)

    let head = xs.iter().take_while(is_even).to_list()
    defer head.deinit()
    assert_eq(head.len, 2 as usize, "stops at the odd 5")
    // 6 is even but comes after the cut — take_while is not filter
    assert_eq(head[1], 4i32, "last accepted element")

    let tail = xs.iter().skip_while(is_even).to_list()
    defer tail.deinit()
    assert_eq(tail.len, 2 as usize, "yields from the 5 on")
    assert_eq(tail[0], 5i32, "the first rejected element is kept")
    assert_eq(tail[1], 6i32, "and everything after it")
}

test "zip stops at the shorter side, chain concatenates" {
    let xs = list123()
    defer xs.deinit()
    let ys: List(i32) = list(2)
    defer ys.deinit()
    ys.push(10i32)
    ys.push(20i32)

    let zipped = xs.iter().zip(ys.iter())
    let p = zipped.next().unwrap()
    assert_eq(p.0, 1i32, "left element")
    assert_eq(p.1, 10i32, "right element")
    assert_true(zipped.next().is_some(), "second pair")
    assert_true(zipped.next().is_none(), "shorter side ends the zip")

    let chained = xs.iter().chain(ys.iter()).to_list()
    defer chained.deinit()
    assert_eq(chained.len, 5 as usize, "all elements of both")
    assert_eq(chained[3], 10i32, "second iterator follows the first")
}

test "consumers: fold each count any all find position last" {
    let xs = list123()
    defer xs.deinit()

    assert_eq(xs.iter().fold(0i32, fn(a, x) { a + x }), 6i32, "fold sums")
    assert_eq(xs.iter().reduce(fn(a, x) { a + x }).unwrap(), 6i32, "seeded reduce agrees")

    // Captures are by value and read-only (RFC-014): to mutate outer state from `each`, capture a
    // reference and write through it.
    let sum = 0i32
    let sum_ref = &sum
    xs.iter().each(fn(x) { sum_ref.* = sum_ref.* + x })
    assert_eq(sum, 6i32, "each visits every element via the captured reference")

    assert_eq(xs.iter().count(), 3 as usize, "count consumes all")
    assert_eq(xs.iter().count(is_even), 1 as usize, "predicate count")
    assert_true(xs.iter().any(is_even), "2 is even")
    assert_true(!xs.iter().all(is_even), "1 is not")
    assert_eq(xs.iter().find(is_even).unwrap(), 2i32, "first even")
    assert_eq(xs.iter().position(is_even).unwrap(), 1 as usize, "its position")
    assert_true(xs.iter().find(fn(x: i32) { x > 99 }).is_none(), "no match is null")
    assert_eq(xs.iter().last().unwrap(), 3i32, "last element")
}

test "min max min_by max_by" {
    let xs: List(i32) = list(3)
    defer xs.deinit()
    xs.push(4i32)
    xs.push(1i32)
    xs.push(3i32)

    assert_eq(xs.iter().min().unwrap(), 1i32, "smallest")
    assert_eq(xs.iter().max().unwrap(), 4i32, "largest")
    // key inverts the order: min_by picks the element whose KEY is smallest
    assert_eq(xs.iter().min_by(fn(x) { 0 - x }).unwrap(), 4i32, "smallest key = largest value")
    assert_eq(xs.iter().max_by(fn(x) { 0 - x }).unwrap(), 1i32, "largest key = smallest value")

    let empty: List(i32) = list(0)
    defer empty.deinit()
    assert_true(empty.iter().min().is_none(), "empty min is null")
    assert_true(empty.iter().max_by(fn(x) { x }).is_none(), "empty max_by is null")
}

test "chain composes iterators of different types" {
    let xs: List(i32) = list(4)
    defer xs.deinit()
    xs.push(1i32)
    xs.push(2i32)
    xs.push(3i32)
    xs.push(4i32)
    let ys: List(i32) = list(1)
    defer ys.deinit()
    ys.push(7i32)

    // I = FilterIter(SliceIterator, ...), J = SliceIterator — only the element
    // type has to match.
    let out = xs.iter().filter(is_even).chain(ys.iter()).to_list()
    defer out.deinit()
    assert_eq(out.len, 3 as usize, "two evens then the tail")
    assert_eq(out[0], 2i32, "filtered head first")
    assert_eq(out[2], 7i32, "plain iterator follows")
}

test "zip_longest fills the exhausted side" {
    let xs: List(i32) = list(3)
    defer xs.deinit()
    xs.push(1i32)
    xs.push(2i32)
    xs.push(3i32)
    let ys: List(i32) = list(1)
    defer ys.deinit()
    ys.push(10i32)

    let z = xs.iter().zip_longest(ys.iter(), -1i32, 0i32)
    let p1 = z.next().unwrap()
    assert_eq(p1.1, 10i32, "real value while both live")
    let p2 = z.next().unwrap()
    assert_eq(p2.0, 2i32, "longer side keeps yielding")
    assert_eq(p2.1, 0i32, "shorter side filled with fill_b")
    let p3 = z.next().unwrap()
    assert_eq(p3.1, 0i32, "still filling")
    assert_true(z.next().is_none(), "ends with the longer side")
}

test "to_set and to_dict collect an iterator" {
    let xs: List(i32) = list(4)
    defer xs.deinit()
    xs.push(1i32)
    xs.push(2i32)
    xs.push(2i32)
    xs.push(3i32)

    let s = xs.iter().to_set()
    defer s.deinit()
    assert_eq(s.len(), 3 as usize, "duplicates collapse")
    assert_true(s.contains(2i32), "elements present")

    let d = xs.iter().to_dict(fn(x) { x * 10 })
    defer d.deinit()
    assert_eq(d.len(), 3 as usize, "same key overwrites")
    assert_eq(d.get(20i32).unwrap(), 2i32, "keyed by the extractor")
}

fn iter_test_noop(x: i32) {}

test "cycle repeats the sequence and take bounds it" {
    let xs = list123()
    defer xs.deinit()
    let out = xs.iter().cycle().take(7).to_list()
    defer out.deinit()
    assert_eq(out.len, 7 as usize, "seven elements")
    assert_eq(out[3], 1i32, "wrapped to the start")
    assert_eq(out[6], 1i32, "and again")
    let none: List(i32) = list(0)
    defer none.deinit()
    assert_true(none.iter().cycle().next().is_none(), "an empty source stays empty")
}

test "step_by yields every nth element starting with the first" {
    let xs: List(i32) = list(0)
    defer xs.deinit()
    for i in 0..7usize {
        xs.push(i as i32)
    }
    let out = xs.iter().step_by(3).to_list()
    defer out.deinit()
    assert_eq(out.len, 3 as usize, "0, 3, 6")
    assert_eq(out[1], 3i32, "second is 3")
    assert_eq(out[2], 6i32, "third is 6")
}

test "peekable looks ahead without consuming" {
    let xs = list123()
    defer xs.deinit()
    let it = xs.iter().peekable()
    assert_eq(it.peek().unwrap(), 1i32, "peek sees the first")
    assert_eq(it.peek().unwrap(), 1i32, "peek again, still the first")
    assert_eq(it.next().unwrap(), 1i32, "next returns it")
    assert_eq(it.peek().unwrap(), 2i32, "peek moved on")
    assert_eq(it.next().unwrap(), 2i32, "second")
    assert_eq(it.next().unwrap(), 3i32, "third")
    assert_true(it.peek().is_none(), "peek at the end")
    assert_true(it.next().is_none(), "next at the end")
}

test "tap passes elements through unchanged" {
    let xs = list123()
    defer xs.deinit()
    assert_eq(xs.iter().tap(iter_test_noop).count(), 3 as usize, "all three seen")
    assert_eq(xs.iter().tap(iter_test_noop).last().unwrap(), 3i32, "unchanged")
}

test "scan yields the running fold" {
    let xs = list123()
    defer xs.deinit()
    let sums = xs.iter().scan(0i32, fn(acc: i32, x: i32) i32 { acc + x }).to_list()
    defer sums.deinit()
    assert_eq(sums.len, 3 as usize, "one per element")
    assert_eq(sums[0], 1i32, "1")
    assert_eq(sums[1], 3i32, "1 + 2")
    assert_eq(sums[2], 6i32, "1 + 2 + 3")
}

test "uniq collapses consecutive runs" {
    let xs: List(i32) = list(0)
    defer xs.deinit()
    xs.push(1i32)
    xs.push(1i32)
    xs.push(2i32)
    xs.push(2i32)
    xs.push(2i32)
    xs.push(1i32)
    let out = xs.iter().uniq().to_list()
    defer out.deinit()
    assert_eq(out.len, 3 as usize, "1, 2, 1")
    assert_eq(out[2], 1i32, "the later 1 is not a duplicate of the earlier one")
}

test "nth, once and repeat" {
    let xs = list123()
    defer xs.deinit()
    assert_eq(xs.iter().nth(1).unwrap(), 2i32, "second element")
    assert_true(xs.iter().nth(3).is_none(), "past the end")
    let one = once(9i32).to_list()
    defer one.deinit()
    assert_eq(one.len, 1 as usize, "exactly one")
    let sevens = repeat(7i32).take(4).to_list()
    defer sevens.deinit()
    assert_eq(sevens.len, 4 as usize, "bounded by take")
    assert_eq(sevens[3], 7i32, "all sevens")
}
