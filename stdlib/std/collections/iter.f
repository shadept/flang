// Iterator adapters and consumers.
//
// An iterator is a value with a `next` function that returns the following element on each call and
// null once the sequence is exhausted. The `Iterator` contract below describes it. For an iterator
// type `I`, `I.Item` is the type of its elements.
//
// The functions in this module come in two groups:
//
// - Adapters such as `filter`, `map`, `take` and `zip` take ownership of an iterator and return a
//   new iterator that transforms its elements. Because the result is an iterator too, adapters
//   compose: `xs.iter().filter(f).map(g).take(3)`. An adapter does its work lazily, one element at
//   a time, as the elements are requested.
// - Consumers such as `to_list`, `fold`, `any` and `count` take ownership of an iterator and read
//   it to the end, or until they have their answer.
//
// Each iterator parameter is declared `$I` with the bound `I: Iterator`, so these functions apply
// to iterators only. A call such as `xs.last()` on a `List` therefore resolves to `List`'s own
// `last`.
//
// A callback parameter is declared `$F` with a function-type bound, such as:
//
//     F: fn(I.Item) bool
//
// It accepts a named function, a lambda or a capturing closure, and the bound supplies the
// parameter types of an unannotated lambda. Each adapter declares its bounds on its struct:
//
//     type FilterIter = struct(I: Iterator, F: fn(I.Item) bool)
//
// The adapter's constructor and its `next` require the same bounds by naming the struct.

import std.allocator
import std.collections.dict
import std.collections.list
import std.collections.set
import std.option
import std.test

// =============================================================================
// The iteration protocol
// =============================================================================

// A type that produces a sequence of elements: each call to `next` returns the following element,
// and null once the sequence is exhausted. Adapters and consumers take ownership of an iterator.
pub type Iterator = contract {
    type Item
    fn next(self: &Self) Item?
}

// A collection that provides an iterator over its elements. `iter` borrows the collection, which
// remains usable afterwards.
pub type Iterable = contract {
    type Iter: Iterator
    type Item = Iter.Item
    fn iter(self: &Self) Iter
}

// =============================================================================
// Filter
// =============================================================================

type FilterIter = struct(I: Iterator, F: fn(I.Item) bool) {
    it: I
    f: F
}

pub fn iter(self: move FilterIter($I, $F)) FilterIter(I, F) {
    return self
}

pub fn deinit(self: move FilterIter($I, $F)) {
    release(self.it)
    release(self.f)
}

pub fn next(self: &FilterIter($I, $F)) I.Item? {
    loop {
        let v = self.it.next()
        if v.is_none() {
            return null
        }
        let x = v.unwrap()
        if self.f(x) {
            return Some(move x)
        }
    }
}

pub fn filter(it: move $I, f: move $F) FilterIter(I, F) {
    return .{ it = move it, f = move f }
}

// =============================================================================
// Map
// =============================================================================

type MapIter = struct(I: Iterator, F) {
    it: I
    f: F
}

pub fn iter(self: move MapIter($I, $F)) MapIter(I, F) {
    return self
}

pub fn deinit(self: move MapIter($I, $F)) {
    release(self.it)
    release(self.f)
}

pub fn next(self: &MapIter($I, $F)) U? where F: fn(I.Item) $U {
    let v = self.it.next()
    if v.is_none() {
        return null
    }
    return Some(self.f(v.unwrap()))
}

pub fn map(it: move $I, f: move $F) MapIter(I, F) where F: fn(I.Item) $U {
    return .{ it = move it, f = move f }
}

// =============================================================================
// Enumerate — pairs each element with its 0-based position.
// =============================================================================

type EnumerateIter = struct(I: Iterator) {
    it: I
    idx: usize
}

pub fn iter(self: move EnumerateIter($I)) EnumerateIter(I) {
    return self
}

pub fn deinit(self: move EnumerateIter($I)) {
    release(self.it)
}

pub fn next(self: &EnumerateIter($I)) (usize, I.Item)? {
    let v = self.it.next()
    if v.is_none() {
        return null
    }
    let i = self.idx
    self.idx = i + 1
    return Some((i, v.unwrap()))
}

pub fn enumerate(it: move $I) EnumerateIter(I) {
    return .{ it = move it, idx = 0 }
}

// =============================================================================
// Take / Skip
// =============================================================================

type TakeIter = struct(I: Iterator) {
    it: I
    left: usize
}

pub fn iter(self: move TakeIter($I)) TakeIter(I) {
    return self
}

pub fn deinit(self: move TakeIter($I)) {
    release(self.it)
}

pub fn next(self: &TakeIter($I)) I.Item? {
    if self.left == 0 {
        return null
    }
    self.left = self.left - 1
    return self.it.next()
}

// At most the first `n` elements.
pub fn take(it: move $I, n: usize) TakeIter(I) {
    return .{ it = move it, left = n }
}

type SkipIter = struct(I: Iterator) {
    it: I
    pending: usize
}

pub fn iter(self: move SkipIter($I)) SkipIter(I) {
    return self
}

pub fn deinit(self: move SkipIter($I)) {
    release(self.it)
}

pub fn next(self: &SkipIter($I)) I.Item? {
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
pub fn skip(it: move $I, n: usize) SkipIter(I) {
    return .{ it = move it, pending = n }
}

// =============================================================================
// Take-while / Skip-while
// =============================================================================

type TakeWhileIter = struct(I: Iterator, F: fn(I.Item) bool) {
    it: I
    f: F
    done: bool
}

pub fn iter(self: move TakeWhileIter($I, $F)) TakeWhileIter(I, F) {
    return self
}

pub fn deinit(self: move TakeWhileIter($I, $F)) {
    release(self.it)
    release(self.f)
}

pub fn next(self: &TakeWhileIter($I, $F)) I.Item? {
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
    return Some(move x)
}

// Elements until the first one `f` rejects; nothing after it.
pub fn take_while(it: move $I, f: move $F) TakeWhileIter(I, F) {
    return .{ it = move it, f = move f, done = false }
}

type SkipWhileIter = struct(I: Iterator, F: fn(I.Item) bool) {
    it: I
    f: F
    skipping: bool
}

pub fn iter(self: move SkipWhileIter($I, $F)) SkipWhileIter(I, F) {
    return self
}

pub fn deinit(self: move SkipWhileIter($I, $F)) {
    release(self.it)
    release(self.f)
}

pub fn next(self: &SkipWhileIter($I, $F)) I.Item? {
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
                return Some(move x)
            }
        }
    }
    return self.it.next()
}

// Drops the leading run `f` accepts; yields everything from the first rejected element on.
pub fn skip_while(it: move $I, f: move $F) SkipWhileIter(I, F) {
    return .{ it = move it, f = move f, skipping = true }
}

// =============================================================================
// Zip / Chain
// =============================================================================

type ZipIter = struct(I: Iterator, J: Iterator) {
    a: I
    b: J
}

pub fn iter(self: move ZipIter($I, $J)) ZipIter(I, J) {
    return self
}

pub fn deinit(self: move ZipIter($I, $J)) {
    release(self.a)
    release(self.b)
}

// Stops at the shorter side. When `a` yields and `b` is exhausted, that
// element of `a` is consumed and lost — don't reuse `a` afterwards.
pub fn next(self: &ZipIter($I, $J)) (I.Item, J.Item)? {
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

pub fn zip(a: move $I, b: move $J) ZipIter(I, J) {
    return .{ a = move a, b = move b }
}

type ChainIter = struct(I: Iterator, J: Iterator(Item = I.Item)) {
    a: I
    b: J
    on_b: bool
}

pub fn iter(self: move ChainIter($I, $J)) ChainIter(I, J) {
    return self
}

pub fn deinit(self: move ChainIter($I, $J)) {
    release(self.a)
    release(self.b)
}

pub fn next(self: &ChainIter($I, $J)) I.Item? {
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
// SliceIterator); only the element type they yield must agree.
pub fn chain(a: move $I, b: move $J) ChainIter(I, J) {
    return .{ a = move a, b = move b, on_b = false }
}

type ZipLongestIter = struct(I: Iterator, J: Iterator) {
    a: I
    b: J
    fill_a: I.Item
    fill_b: J.Item
}

pub fn iter(self: move ZipLongestIter($I, $J)) ZipLongestIter(I, J) {
    return self
}

pub fn deinit(self: move ZipLongestIter($I, $J)) {
    release(self.a)
    release(self.b)
    release(self.fill_a)
    release(self.fill_b)
}

pub fn next(self: &ZipLongestIter($I, $J)) (I.Item, J.Item)?
where I.Item: copyable, J.Item: copyable {
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
pub fn zip_longest(
    a: move $I,
    b: move $J,
    fill_a: move I.Item,
    fill_b: move J.Item,
) ZipLongestIter(I, J) {
    return .{ a = move a, b = move b, fill_a = move fill_a, fill_b = move fill_b }
}

// =============================================================================
// Cycle
// =============================================================================

type CycleIter = struct(I: Iterator + copyable) {
    start: I
    it: I
}

pub fn iter(self: move CycleIter($I)) CycleIter(I) {
    return self
}

pub fn deinit(self: move CycleIter($I)) {
    release(self.start)
    release(self.it)
}

pub fn next(self: &CycleIter($I)) I.Item? {
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
pub fn cycle(it: move $I) CycleIter(I) {
    return .{ start = it, it = it }
}

// =============================================================================
// Step by
// =============================================================================

type StepByIter = struct(I: Iterator) {
    it: I
    step: usize
}

pub fn iter(self: move StepByIter($I)) StepByIter(I) {
    return self
}

pub fn deinit(self: move StepByIter($I)) {
    release(self.it)
}

pub fn next(self: &StepByIter($I)) I.Item? {
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
pub fn step_by(it: move $I, step: usize) StepByIter(I) {
    if step == 0 {
        panic("step_by: step must be at least 1")
    }
    return .{ it = move it, step = step }
}

// =============================================================================
// Peekable
// =============================================================================

type PeekableIter = struct(I: Iterator) {
    it: I
    // The element `next` will return, pulled one step ahead; null at the end.
    ahead: I.Item?
}

pub fn iter(self: move PeekableIter($I)) PeekableIter(I) {
    return self
}

pub fn deinit(self: move PeekableIter($I)) {
    release(self.it)
    release(self.ahead)
}

pub fn next(self: &PeekableIter($I)) I.Item? {
    return replace(&self.ahead, self.it.next())
}

// Returns the element the next `next` will return without consuming it, or null at the end.
pub fn peek(self: &PeekableIter($I)) I.Item? where I.Item: copyable {
    return self.ahead
}

// An iterator that can look one element ahead (`peek`). Pulls the first element on construction.
pub fn peekable(it: move $I) PeekableIter(I) {
    // Pulled before the literal: its fields evaluate in order, and `it = it` would copy the
    // iterator before `next` advanced it.
    const first = it.next()
    return .{ it = move it, ahead = first }
}

// =============================================================================
// Tap
// =============================================================================

type TapIter = struct(I: Iterator, F: fn(I.Item)) {
    it: I
    f: F
}

pub fn iter(self: move TapIter($I, $F)) TapIter(I, F) {
    return self
}

pub fn deinit(self: move TapIter($I, $F)) {
    release(self.it)
    release(self.f)
}

pub fn next(self: &TapIter($I, $F)) I.Item? {
    const v = self.it.next()
    if v.is_some() {
        self.f(v.unwrap())
    }
    return v
}

// Calls `f` on every element as it passes through, yielding the element unchanged: a look at what
// an adapter chain produces without breaking the chain.
pub fn tap(it: move $I, f: move $F) TapIter(I, F) {
    return .{ it = move it, f = move f }
}

// =============================================================================
// Scan
// =============================================================================

type ScanIter = struct(I: Iterator, A, F: fn(A, I.Item) A) {
    it: I
    acc: A
    f: F
}

pub fn iter(self: move ScanIter($I, $A, $F)) ScanIter(I, A, F) {
    return self
}

pub fn deinit(self: move ScanIter($I, $A, $F)) {
    release(self.it)
    release(self.acc)
    release(self.f)
}

pub fn next(self: &ScanIter($I, $A, $F)) A? where A: copyable {
    const v = self.it.next()
    if v.is_none() {
        return null
    }
    self.acc = self.f(self.acc, v.unwrap())
    return Some(self.acc)
}

// A running fold: yields `f(acc, x)` for every element, starting from `init`, so the last value is
// what `fold` would return. `init` itself is not yielded.
pub fn scan(it: move $I, init: move $A, f: move $F) ScanIter(I, A, F) {
    return .{ it = move it, acc = move init, f = move f }
}

// =============================================================================
// Uniq
// =============================================================================

type UniqIter = struct(I: Iterator) {
    it: I
    // The next element to yield, pulled one step ahead; null at the end.
    ahead: I.Item?
}

pub fn iter(self: move UniqIter($I)) UniqIter(I) {
    return self
}

pub fn deinit(self: move UniqIter($I)) {
    release(self.it)
    release(self.ahead)
}

pub fn next(self: &UniqIter($I)) I.Item? where I.Item: copyable + Eq {
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
pub fn uniq(it: move $I) UniqIter(I) {
    const first = it.next()
    return .{ it = move it, ahead = first }
}

// =============================================================================
// Sources
// =============================================================================

type OnceIter = struct(T) {
    value: T
    done: bool
}

pub fn iter(self: move OnceIter($T)) OnceIter(T) {
    return self
}

pub fn deinit(self: move OnceIter($T)) {
    release(self.value)
}

pub fn next(self: &OnceIter($T)) T? where T: copyable {
    if self.done {
        return null
    }
    self.done = true
    return Some(self.value)
}

// An iterator over exactly one element.
pub fn once(value: move $T) OnceIter(T) {
    return .{ value = move value, done = false }
}

type RepeatIter = struct(T) {
    value: T
}

pub fn iter(self: move RepeatIter($T)) RepeatIter(T) {
    return self
}

pub fn deinit(self: move RepeatIter($T)) {
    release(self.value)
}

pub fn next(self: &RepeatIter($T)) T? where T: copyable {
    return Some(self.value)
}

// An iterator that yields `value` forever. Pair it with `take` or `zip`.
pub fn repeat(value: move $T) RepeatIter(T) {
    return .{ value = move value }
}

// =============================================================================
// Consumers
// =============================================================================

// Combine left to right: `f(f(f(init, x0), x1), x2)`.
pub fn fold(it: move $I, init: move $A, f: move $F) A where I: Iterator, F: fn(A, I.Item) A {
    let acc = move init
    for item in it {
        acc = f(acc, item)
    }
    return acc
}

// Fold seeded with the first element; null when empty.
pub fn reduce(it: move $I, f: move $F) I.Item? where I: Iterator, F: fn(I.Item, I.Item) I.Item {
    return it.next() match {
        Some(first) => Some(fold(it, first, f))
        None => null
    }
}

// Call `f` on every element, in order.
pub fn each(it: move $I, f: move $F) where I: Iterator, F: fn(I.Item) {
    for item in it {
        f(item)
    }
}

// Number of elements. Consumes the iterator.
pub fn count(it: move Iterator) usize {
    let n: usize = 0
    for item in it {
        n = n + 1
    }
    return n
}

// Number of elements `pred` accepts.
pub fn count(it: move $I, pred: $F) usize where I: Iterator, F: fn(I.Item) bool {
    let n: usize = 0
    for item in it {
        if pred(item) {
            n = n + 1
        }
    }
    return n
}

// Whether any element satisfies `pred`. False for an empty iterator. Stops at the first match.
pub fn any(it: move $I, pred: $F) bool where I: Iterator, F: fn(I.Item) bool {
    for item in it {
        if pred(item) {
            return true
        }
    }
    return false
}

// Whether every element satisfies `pred`. True for an empty iterator. Stops at the first
// counterexample.
pub fn all(it: move $I, pred: $F) bool where I: Iterator, F: fn(I.Item) bool {
    for item in it {
        let ok: bool = pred(item)
        if !ok {
            return false
        }
    }
    return true
}

// First element satisfying `pred`, or null.
pub fn find(it: move $I, pred: $F) I.Item? where I: Iterator, F: fn(I.Item) bool {
    for item in it {
        if pred(item) {
            return Some(move item)
        }
    }
    return null
}

// 0-based position of the first element satisfying `pred`, or null.
pub fn position(it: move $I, pred: $F) usize? where I: Iterator, F: fn(I.Item) bool {
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
pub fn last(it: move $I) I.Item? where I: Iterator(Item: copyable) {
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
pub fn nth(it: move $I, n: usize) I.Item? where I: Iterator {
    for _k in 0..n {
        if it.next().is_none() {
            return null
        }
    }
    return it.next()
}

// Smallest element by `<`, or null when empty.
pub fn min(it: move $I) I.Item? where I: Iterator(Item: copyable + Ordered) {
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
pub fn max(it: move $I) I.Item? where I: Iterator(Item: copyable + Ordered) {
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
pub fn min_by(it: move $I, key: $F) I.Item?
where I: Iterator(Item: copyable), F: fn(I.Item) $K, K: copyable + Ordered {
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
pub fn max_by(it: move $I, key: $F) I.Item?
where I: Iterator(Item: copyable), F: fn(I.Item) $K, K: copyable + Ordered {
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

// Appends every element `it` yields to the list, in order.
pub fn extend(self: &List($T), it: move Iterator(Item = T)) {
    for item in it {
        self.push(item)
    }
}

// Appends every element `it` yields to the list, in order.
pub fn extend(self: &UnmanagedList($T), it: move Iterator(Item = T), allocator: &Allocator) {
    for item in it {
        self.push(item, allocator)
    }
}

// Collect into a fresh List.
pub fn to_list(it: move $I, allocator: &Allocator = context.allocator) List(I.Item)
where I: Iterator {
    let out: List(I.Item) = list(0, allocator)
    for item in it {
        out.push(item)
    }
    return out
}

// Collect into a fresh Set (duplicates collapse; requires a hashable element type).
pub fn to_set(it: move $I, allocator: &Allocator = context.allocator) Set(I.Item)
where I: Iterator {
    let out: Set(I.Item) = set(allocator)
    for item in it {
        out.add(item)
    }
    return out
}

// Collect into a fresh Dict keyed by `key(item)`. A later item with the same key overwrites the
// earlier one.
pub fn to_dict(it: move $I, key: $F, allocator: &Allocator = context.allocator) Dict(K, I.Item)
where I: Iterator, F: fn(I.Item) $K {
    let out: Dict(K, I.Item) = dict(allocator)
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
        .filter { it > floor }
        .map { it * scale }
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

    assert_eq(xs.iter().fold(0i32) { a, x => a + x }, 6i32, "fold sums")
    assert_eq(xs.iter().reduce { a, x => a + x }.unwrap(), 6i32, "seeded reduce agrees")

    // Captures are by value and read-only (RFC-014): to mutate outer state from `each`, capture a
    // reference and write through it.
    let sum = 0i32
    let sum_ref = &sum
    xs.iter().each { sum_ref.* = sum_ref.* + it }
    assert_eq(sum, 6i32, "each visits every element via the captured reference")

    assert_eq(xs.iter().count(), 3 as usize, "count consumes all")
    assert_eq(xs.iter().count(is_even), 1 as usize, "predicate count")
    assert_true(xs.iter().any(is_even), "2 is even")
    assert_true(!xs.iter().all(is_even), "1 is not")
    assert_eq(xs.iter().find(is_even).unwrap(), 2i32, "first even")
    assert_eq(xs.iter().position(is_even).unwrap(), 1 as usize, "its position")
    assert_true(xs.iter().find { it > 99 }.is_none(), "no match is null")
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
    assert_eq(xs.iter().min_by { 0 - it }.unwrap(), 4i32, "smallest key = largest value")
    assert_eq(xs.iter().max_by { 0 - it }.unwrap(), 1i32, "largest key = smallest value")

    let empty: List(i32) = list(0)
    defer empty.deinit()
    assert_true(empty.iter().min().is_none(), "empty min is null")
    assert_true(empty.iter().max_by { it }.is_none(), "empty max_by is null")
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

    let d = xs.iter().to_dict { it * 10 }
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
    let sums = xs.iter()
        .scan(0i32) { acc, x => acc + x }
        .to_list()
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

test "extend appends what an iterator yields" {
    let xs = list123()
    defer xs.deinit()
    const ys = list123()
    xs.extend(ys.iter().filter { it != 2 })
    ys.deinit()
    assert_eq(xs.len, 5usize, "two of the three appended")
    assert_eq(xs[4], 3i32, "in order")
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
