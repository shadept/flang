import std.allocator
import std.dict
import std.list
import std.set
import std.test
import std.option

// =============================================================================
// Iterator combinators.
//
// Anything with a `next(&Self) T?` (and an `iter(&Self) Self` so `for` can
// consume it) is an iterator. Adapters below wrap an iterator and are
// themselves iterators, so they chain: `xs.iter().filter(f).map(g).to_list()`.
//
// Callables are duck-typed `$F` parameters (RFC-014): bare functions,
// non-capturing lambdas, and capturing closures all work, and lambda
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
        if v.is_none() { return null }
        let x = v.unwrap()
        if self.f(x) { return Some(x) }
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
    if v.is_none() { return null }
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
    if v.is_none() { return null }
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
    if self.left == 0 { return null }
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
    if self.done { return null }
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
            if v.is_none() { return null }
            let x = v.unwrap()
            let skip_it: bool = self.f(x)
            if !skip_it { return Some(x) }
        }
    }
    return self.it.next()
}

// Drops the leading run `f` accepts; yields everything from the first
// rejected element on.
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
    if a.is_none() { return null }
    let b = self.b.next()
    if b.is_none() { return null }
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
        if v.is_some() { return v }
        self.on_b = true
    }
    return self.b.next()
}

// All of `a`, then all of `b`. The iterator TYPES may differ (chain a
// FilterIter with a plain ListIterator); only the element type they yield
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
        if b.is_none() { return null }
        return Some((self.fill_a, b.unwrap()))
    }
    if b.is_none() {
        return Some((a.unwrap(), self.fill_b))
    }
    return Some((a.unwrap(), b.unwrap()))
}

// Like `zip`, but runs to the LONGER side, substituting `fill_a` / `fill_b`
// for the exhausted iterator's elements.
pub fn zip_longest(a: $I, b: $J, fill_a: $A, fill_b: $B) ZipLongestIter(I, J, A, B) {
    return .{ a = a, b = b, fill_a = fill_a, fill_b = fill_b }
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
        if pred(item) { n = n + 1 }
    }
    return n
}

// Whether any element satisfies `pred`. False for an empty iterator.
// Stops at the first match.
pub fn any(it: $I, pred: $F) bool {
    for item in it {
        if pred(item) { return true }
    }
    return false
}

// Whether every element satisfies `pred`. True for an empty iterator.
// Stops at the first counterexample.
pub fn all(it: $I, pred: $F) bool {
    for item in it {
        let ok: bool = pred(item)
        if !ok { return false }
    }
    return true
}

// First element satisfying `pred`, or null.
pub fn find(it: $I, pred: $F) $T? {
    for item in it {
        if pred(item) { return Some(item) }
    }
    return null
}

// 0-based position of the first element satisfying `pred`, or null.
pub fn position(it: $I, pred: $F) usize? {
    let i: usize = 0
    for item in it {
        if pred(item) { return Some(i) }
        i = i + 1
    }
    return null
}

// Final element, or null when empty.
pub fn last(it: $I) $T? {
    let result = it.next()
    if result.is_none() { return null }
    let v = result.unwrap()
    for item in it {
        v = item
    }
    return Some(v)
}

// Smallest element by `<`, or null when empty. Requires an ordered element
// type (primitive or `op_cmp`).
pub fn min(it: $I) $T? {
    let first = it.next()
    if first.is_none() { return null }
    let best = first.unwrap()
    for item in it {
        if item < best { best = item }
    }
    return Some(best)
}

// Largest element by `<`, or null when empty.
pub fn max(it: $I) $T? {
    let first = it.next()
    if first.is_none() { return null }
    let best = first.unwrap()
    for item in it {
        if best < item { best = item }
    }
    return Some(best)
}

// Element with the smallest `key(x)`, or null when empty. Ties keep the
// earliest.
pub fn min_by(it: $I, key: $F) $T? {
    let first = it.next()
    if first.is_none() { return null }
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

// Element with the largest `key(x)`, or null when empty. Ties keep the
// earliest.
pub fn max_by(it: $I, key: $F) $T? {
    let first = it.next()
    if first.is_none() { return null }
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

// Collect into a fresh Set (duplicates collapse; requires a hashable
// element type).
pub fn to_set(it: $I, allocator: &Allocator? = null) Set($T) {
    let out: Set(T) = set(allocator)
    for item in it {
        out.add(item)
    }
    return out
}

// Collect into a fresh Dict keyed by `key(item)`. A later item with the
// same key overwrites the earlier one.
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
    // The non-matching head is the interesting case: `next` must skip
    // it and keep pulling, not report the iterator empty.
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

    // Captures are by value and read-only (RFC-014): to mutate outer state
    // from `each`, capture a reference and write through it.
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

    // I = FilterIter(ListIterator, ...), J = ListIterator — only the element
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
