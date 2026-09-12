// Growable arrays in two flavours, the managed and unmanaged split of spec §9.4:
//
//   UnmanagedList(T)  the buffer: `ptr`, `len`, `cap`, and every operation on it. The ones that
//                     allocate or free take the allocator as an argument (`xs.push(v, alloc)`), so
//                     a composite stores one allocator for all its children and passes it at the
//                     call that allocates.
//   List(T)           an `UnmanagedList` with its allocator beside it (`xs.push(v)`). It reaches
//                     the storage through `op_deref`, so `xs.len` and `xs.pop()` read the same on
//                     either, and its allocating functions are one-line wrappers. A null allocator
//                     is the global one (§4.1), so a zero-initialised `List` is a valid empty list.
//
// `__storage` is readable like any field; treat it as private. Calling the unmanaged API on a
// `List` through it, or through the `op_deref` peel (`xs.push(v, other_alloc)`), compiles and mixes
// allocators.

import core.math

import std.allocator
import std.collections.dict
import std.mem
import std.option
import std.sort
import std.string
import std.string_builder
import std.test

// A growable array of `T` that carries no allocator: every operation that grows or frees the buffer
// takes one as its last argument, and the same allocator must be passed every time. A
// zero-initialised value is a valid empty list. Elements are owned: `deinit` deinits each before
// freeing the buffer.
//
// `ptr` is `owned` in the RFC-028 sense: the list is responsible for releasing the buffer, so a
// copy would be two releasers. The memory itself belongs to the allocator that handed it out.
pub type UnmanagedList = struct(T) {
    owned ptr: &T
    len: usize
    cap: usize
}

// A growable array of `T` that owns its storage and remembers the allocator it grows and frees
// through. Every `UnmanagedList` operation applies to it as well, reached through `op_deref`, and
// the allocating ones come without the allocator argument. A zero-initialised value is a valid
// empty list on the global allocator.
pub type List = struct(T) {
    __storage: UnmanagedList(T)
    allocator: &Allocator
}

// Reaches the storage: `xs.len`, `xs.pop()` and every `UnmanagedList` read resolve through this.
pub fn op_deref(self: &List($T)) &UnmanagedList(T) {
    return &self.__storage
}

// The `List` API over an `UnmanagedList` owned by someone else, for a scope in which the allocator
// is known: `s.items.managed(s.allocator).push(v)` grows `s.items` in place. It holds the storage
// by reference, so nothing is copied and there is nothing to deinit; the owner of the storage frees
// it, through the same allocator.
pub type ListRef = struct(T) {
    __storage: &UnmanagedList(T)
    allocator: &Allocator
}

// Returns the `List` API over `s`, growing it through `allocator`. `s` must outlive the handle and
// keep allocating through the same allocator.
pub fn managed(self: &UnmanagedList($T), allocator: &Allocator) ListRef(T) {
    return .{ __storage = self, allocator = allocator }
}

// Reaches the wrapped storage: every `UnmanagedList` read, indexing and `for` resolve through this.
pub fn op_deref(self: &ListRef($T)) &UnmanagedList(T) {
    return self.__storage
}

// Budget for a list's first allocation, in bytes, and the ceiling on how many elements it buys.
// Sizing in bytes keeps the first allocation flat across element types; a fixed element count would
// scale it with `size_of(T)`.
const DEFAULT_CAPACITY_BUDGET: usize = 1024

const DEFAULT_CAPACITY_MAX: usize = 8

// Elements the first allocation holds for an element type of `elem_size` bytes: the byte budget's
// worth, clamped to `[1, DEFAULT_CAPACITY_MAX]`.
fn default_capacity(elem_size: usize) usize {
    // A payload-less enum variant is zero-sized; the budget buys as many as the ceiling allows.
    if elem_size == 0 {
        return DEFAULT_CAPACITY_MAX
    }
    return clamp(DEFAULT_CAPACITY_BUDGET / elem_size, 1, DEFAULT_CAPACITY_MAX)
}

// =============================================================================
// Construction
// =============================================================================

// Creates an unmanaged list with room for `capacity` elements. Zero allocates nothing; a
// zero-initialised `UnmanagedList` is the same empty list.
//
// - `allocator`: grows and frees the storage. Pass the same one to every allocating call.
//
// Panics when the allocation fails.
pub fn unmanaged_list(capacity: usize, allocator: &Allocator) UnmanagedList($T) {
    let out: UnmanagedList(T)
    if capacity > 0 {
        const buf = allocator.alloc(capacity * size_of(T),
            align_of(T)).expect("list: allocation failed")
        out.ptr = buf.ptr as &T
        out.cap = capacity
    }
    return move out
}

// Creates an unmanaged list holding a copy of `source`, in fresh storage sized to its length.
//
// Copyable elements are copied bitwise; owning elements are cloned through `clone(&T, allocator)`,
// so the new list owns its own. An empty source allocates nothing. Panics when the allocation
// fails.
//
// - `allocator`: grows and frees the storage. Pass the same one to every allocating call.
pub fn unmanaged_list(source: $T[], allocator: &Allocator) UnmanagedList(T) {
    let out: UnmanagedList(T) = unmanaged_list(source.len, allocator)
    out.push_all(source, allocator)
    return move out
}

// Creates a list with room for `capacity` elements that allocates through `allocator` for its whole
// life. Zero allocates nothing. Panics when the allocation fails.
pub fn list(capacity: usize, allocator: &Allocator) List($T) {
    let out: List(T)
    out.allocator = allocator
    if capacity > 0 {
        const buf = allocator.alloc(capacity * size_of(T),
            align_of(T)).expect("list: allocation failed")
        out.__storage = .{ ptr = buf.ptr as &T, len = 0usize, cap = capacity }
    }
    return move out
}

// Creates a list with room for `capacity` elements. Zero allocates nothing; a zero-initialised
// `List` is the same empty list.
//
// - `allocator`: kept for the list's whole life. Null is the global allocator.
//
// Panics when the allocation fails.
pub fn list(capacity: usize, allocator: &Allocator? = null) List($T) {
    let out: List(T)
    out.allocator = allocator.or_global()
    if capacity > 0 {
        const buf = out.allocator.alloc(capacity * size_of(T),
            align_of(T)).expect("list: allocation failed")
        out.__storage = .{ ptr = buf.ptr as &T, len = 0usize, cap = capacity }
    }
    return move out
}

// Creates a list holding a copy of `source`, in fresh storage sized to fit. Copyable elements are
// copied bitwise; owning elements are cloned through `clone(&T, allocator)`, so the new list owns
// its own. An empty source allocates nothing. Panics when the allocation fails.
//
// - `allocator`: kept for the list's whole life. Null is the global allocator.
pub fn list(source: $T[], allocator: &Allocator? = null) List(T) {
    const alloc = allocator.or_global()
    let st: UnmanagedList(T) = unmanaged_list(source, alloc)
    return .{ __storage = move st, allocator = alloc }
}

// Creates an unmanaged list of `count` bitwise copies of `value`, in storage sized to fit. Zero
// allocates nothing. Panics when the allocation fails.
//
// - `allocator`: grows and frees the storage. Pass the same one to every allocating call.
pub fn filled_unmanaged_list(count: usize, value: $T, allocator: &Allocator) UnmanagedList(T) {
    let out: UnmanagedList(T) = unmanaged_list(count, allocator)
    for _i in 0..count {
        out.push(value, allocator)
    }
    return move out
}

// Creates a list of `count` bitwise copies of `value`, in storage sized to fit. Zero allocates
// nothing. Panics when the allocation fails.
//
// - `allocator`: kept for the list's whole life. Null is the global allocator.
pub fn filled_list(count: usize, value: $T, allocator: &Allocator? = null) List(T) {
    const alloc = allocator.or_global()
    return .{ __storage = filled_unmanaged_list(count, value, alloc), allocator = alloc }
}

// =============================================================================
// UnmanagedList: release and copies
// =============================================================================

// Deinits every live element, frees the buffer and resets to empty, so a second call is a no-op.
pub fn deinit(self: &UnmanagedList($T), allocator: &Allocator) {
    if self.cap > 0 {
        self.clear(allocator)
        allocator.free(slice_from_raw_parts(self.ptr, self.cap))
    }

    self.ptr = 0usize as &T
    self.len = 0
    self.cap = 0
}

// Returns a deep copy in fresh storage sized to fit: copyable elements are copied bitwise, the
// others through their own `clone`. Panics when the allocation fails.
//
// - `allocator`: grows and frees the copy's storage. Pass the same one to every allocating call.
pub fn clone(self: &UnmanagedList($T), allocator: &Allocator) UnmanagedList(T) {
    let out: UnmanagedList(T) = unmanaged_list(self.len, allocator)
    for &elem in self {
        #if type_info(T).copyable {
            out.push(elem.*, allocator)
        } else {
            out.push(elem.clone(allocator), allocator)
        }
    }
    return move out
}

// Hands over the buffer, shrunk to `len`, and resets the list to empty. Elements are not deinited:
// the caller owns them now, and frees the slice through the same allocator.
pub fn to_owned_slice(self: &UnmanagedList($T), allocator: &Allocator) T[] {
    const elem_size: usize = size_of(T)

    if self.len == 0 {
        if self.cap > 0 {
            allocator.free(slice_from_raw_parts(self.ptr, self.cap))
        }
        self.ptr = 0usize as &T
        self.cap = 0
        const empty: T[] = slice_from_raw_parts(0usize as &T, 0)
        return move empty
    }

    if self.cap > self.len {
        const old_slice = slice_from_raw_parts(self.ptr as &u8, self.cap * elem_size)
        const resized = allocator.realloc(old_slice, align_of(T), self.len * elem_size)
        if resized.is_some() {
            self.ptr = resized.unwrap().ptr as &T
            self.cap = self.len
        }
    }

    const result_slice = slice_from_raw_parts(self.ptr, self.len)
    self.ptr = 0usize as &T
    self.len = 0
    self.cap = 0
    return result_slice
}

// =============================================================================
// UnmanagedList: queries
//
// Forwarders to `core.slice` over `as_slice()`; the slice functions carry the full contracts. A
// slice function forwards when it is container vocabulary, what a caller reaches for on the list
// itself; a primitive composed once to build something else (`lower_bound`, `swap`, `copy_to`)
// stays on the slice, reached through `as_slice()`.
// =============================================================================

// Returns the bytes the backing storage occupies: the whole capacity, not just the live elements,
// and nothing the elements own on their own.
pub fn capacity_bytes(self: &UnmanagedList($T)) usize {
    return self.cap * size_of(T)
}

// Returns a view of the live elements. Growth moves the buffer and invalidates the view.
pub fn as_slice(self: &UnmanagedList($T)) T[] {
    return slice_from_raw_parts(self.ptr, self.len)
}

// Returns the element at `index`, or null past the end.
pub fn get(self: &UnmanagedList($T), index: usize) T? {
    return self.as_slice().get(index)
}

// Returns a reference to the element at `index`, or null past the end. Invalidated by growth.
pub fn get_ref(self: &UnmanagedList($T), index: usize) &T? {
    return self.as_slice().get_ref(index)
}

// Returns the first element, or null when empty.
pub fn first(self: &UnmanagedList($T)) T? {
    return self.as_slice().first()
}

// Returns the last element, or null when empty.
pub fn last(self: &UnmanagedList($T)) T? {
    return self.as_slice().last()
}

// Returns a reference to the first element, or null when empty. Writes through it land in the list;
// growth may move the storage and invalidate it.
pub fn first_ref(self: &UnmanagedList($T)) &T? {
    return self.get_ref(0)
}

// Returns a reference to the last element, or null when empty. Writes through it land in the list;
// growth may move the storage and invalidate it.
pub fn last_ref(self: &UnmanagedList($T)) &T? {
    if self.len == 0 {
        return null
    }
    return self.get_ref(self.len - 1)
}

// Returns the index of `value`, or null when absent; with duplicates, the first. The list must be
// sorted ascending.
pub fn binary_search(self: &UnmanagedList($T), value: T) usize? {
    return self.as_slice().binary_search(value)
}

// Returns whether any element equals `value`.
pub fn contains(self: &UnmanagedList($T), value: T) bool {
    return self.as_slice().contains(value)
}

// Returns the index of the first element equal to `value`, or null.
pub fn index_of(self: &UnmanagedList($T), value: T) usize? {
    return self.as_slice().index_of(value)
}

// Returns the index of the last element equal to `value`, or null.
pub fn last_index_of(self: &UnmanagedList($T), value: T) usize? {
    return self.as_slice().last_index_of(value)
}

// Returns the first element satisfying `pred`, or null.
pub fn find(self: &UnmanagedList($T), pred: $F) T? {
    return self.as_slice().find(pred)
}

// Returns the index of the first element satisfying `pred`, or null.
pub fn find_index(self: &UnmanagedList($T), pred: $F) usize? {
    return self.as_slice().find_index(pred)
}

// Returns whether any element satisfies `pred`. False when empty.
pub fn any(self: &UnmanagedList($T), pred: $F) bool {
    return self.as_slice().any(pred)
}

// Returns whether every element satisfies `pred`. True when empty.
pub fn all(self: &UnmanagedList($T), pred: $F) bool {
    return self.as_slice().all(pred)
}

// Calls `f` on every element, in order.
pub fn each(self: &UnmanagedList($T), f: $F) {
    self.as_slice().each(f)
}

// Returns how many elements satisfy `pred`.
pub fn count(self: &UnmanagedList($T), pred: $F) usize {
    return self.as_slice().count_if(pred)
}

// Returns the smallest element by `<`, or null when empty.
pub fn min(self: &UnmanagedList($T)) T? {
    return self.as_slice().min()
}

// Returns the largest element by `<`, or null when empty.
pub fn max(self: &UnmanagedList($T)) T? {
    return self.as_slice().max()
}

// Returns the element with the smallest `key(x)`, or null when empty. Ties keep the earliest.
pub fn min_by(self: &UnmanagedList($T), key: $F) T? {
    return self.as_slice().min_by(key)
}

// Returns the element with the largest `key(x)`, or null when empty. Ties keep the earliest.
pub fn max_by(self: &UnmanagedList($T), key: $F) T? {
    return self.as_slice().max_by(key)
}

// Combines left to right: `f(f(f(init, x0), x1), x2)`.
pub fn fold(self: &UnmanagedList($T), init: $A, f: $F) A {
    return self.as_slice().fold(init, f)
}

// Combines right to left: `f(x0, f(x1, f(x2, init)))`. The accumulator is `f`'s second argument.
pub fn fold_right(self: &UnmanagedList($T), init: $A, f: $F) A {
    return self.as_slice().fold_right(init, f)
}

// Concatenates the views with `sep` between them into a new owned string.
//
// - `allocator`: where the result is allocated. Null is the global allocator.
pub fn join(self: &UnmanagedList(String), sep: String, allocator: &Allocator? = null) OwnedString {
    return self.as_slice().join(sep, allocator)
}

// =============================================================================
// UnmanagedList: mutations, allocator explicit where the buffer may grow
// =============================================================================

// Ensures room for at least `capacity` elements, growing geometrically. A grown buffer moves, so
// views from `as_slice()` are invalid afterwards. Panics when the allocation fails.
pub fn reserve(self: &UnmanagedList($T), capacity: usize, allocator: &Allocator) {
    if self.cap >= capacity {
        return
    }

    const elem_size: usize = size_of(T)
    const elem_align: usize = align_of(T)

    let new_cap = if self.cap == 0 { default_capacity(elem_size) } else { self.cap * 2 }
    if new_cap < capacity {
        new_cap = capacity
    }
    const new_bytes: usize = new_cap * elem_size

    // Grow through `realloc`, so an allocator that can extend the block in place does no copy. The
    // alloc-copy-free path below is the fallback for a `realloc` that declines.
    if self.cap > 0 {
        const old_bytes = slice_from_raw_parts(self.ptr as &u8, self.cap * elem_size)
        const grown = allocator.realloc(old_bytes, elem_align, new_bytes)
        if grown.is_some() {
            self.ptr = grown.unwrap().ptr as &T
            self.cap = new_cap
            return
        }
    }

    const new_buf = allocator.alloc(new_bytes, elem_align)
        .expect("reserve(List(T), capacity): allocation failed")
    const new_ptr: &T = new_buf.ptr as &T

    if self.len > 0 {
        memcpy(new_ptr as &u8, self.ptr as &u8, self.len * elem_size)
    }

    if self.cap > 0 {
        allocator.free(slice_from_raw_parts(self.ptr, self.cap))
    }

    self.ptr = new_ptr
    self.cap = new_cap
}

// Appends `value`, growing when full. Panics when the allocation fails.
pub fn push(self: &UnmanagedList($T), value: T, allocator: &Allocator) {
    self.reserve(self.len + 1, allocator)
    self.len = self.len + 1
    let data = self.as_slice()
    data[self.len - 1] = move value
}

// Appends every element of `xs`, in order, growing when needed. Copyable elements are copied
// bitwise; owning elements are cloned through `clone(&T, allocator)`. Panics when the allocation
// fails.
//
// - `xs`: must not alias the list's own storage. Growth may move and free that storage before the
//   copy, so no copy primitive makes self-append safe.
pub fn push_all(self: &UnmanagedList($T), xs: T[], allocator: &Allocator) {
    if xs.len == 0 {
        return
    }
    self.reserve(self.len + xs.len, allocator)
    #if type_info(T).copyable {
        memcpy((self.ptr + self.len) as &u8, xs.ptr as &u8, xs.len * size_of(T))
        self.len = self.len + xs.len
    } else {
        for i in 0..xs.len {
            self.push(xs[i].clone(allocator), allocator)
        }
    }
}

// Inserts `value` at `index`, shifting everything at and after it one slot toward the end. `index
// == len` appends. O(len - index). Panics past the end or when the allocation fails.
pub fn insert(self: &UnmanagedList($T), index: usize, value: T, allocator: &Allocator) {
    if index > self.len {
        panic("insert(List(T), index): index out of bounds")
    }
    self.reserve(self.len + 1, allocator)
    self.len = self.len + 1
    let data = self.as_slice()
    let i = self.len - 1
    while i > index {
        data[i] = move data[i - 1]
        i = i - 1
    }
    data[index] = move value
}

// Removes and returns the last element, or null when empty.
pub fn pop(self: &UnmanagedList($T)) T? {
    if self.len == 0 {
        return null
    }

    self.len = self.len - 1
    let last: &T = self.ptr + self.len
    return Some(move last.*)
}

// Set the element at the given index.
// Panics if index is out of bounds.
#deprecated("Prefer index syntax: list[idx] = value")
pub fn set(self: &UnmanagedList($T), index: usize, value: T) {
    if index >= self.len {
        panic("List: index out of bounds")
    }

    // Write value using memcpy
    let dest: &u8 = (self.ptr + index) as &u8
    memcpy(dest, &value as &u8, size_of(T))
}

// Drops every element, deiniting each. The backing storage is kept for reuse.
pub fn clear(self: &UnmanagedList($T), allocator: &Allocator) {
    #if !type_info(T).copyable {
        for &elem in self {
            elem.deinit(allocator)
        }
    }
    self.len = 0
}

// Drops every element past the first `n`, deiniting each. The backing storage is kept; a length at
// or below `n` is left alone.
pub fn truncate(self: &UnmanagedList($T), n: usize, allocator: &Allocator) {
    if n >= self.len {
        return
    }
    #if !type_info(T).copyable {
        while self.len > n {
            self.len = self.len - 1
            const elem: &T = self.ptr + self.len
            elem.deinit(allocator)
        }
    } else {
        self.len = n
    }
}

// Sorts in place, ascending by `<`.
pub fn sort(self: &UnmanagedList($T)) {
    sort(self.as_slice())
}

// Sorts in place by `cmp`, an `fn(T, T) Ord`.
pub fn sort(self: &UnmanagedList($T), cmp: $F) {
    sort(self.as_slice(), cmp)
}

// Sorts in place by `key(x)` ascending, keeping the order of equal keys.
pub fn sort_by(self: &UnmanagedList($T), key: $F) {
    self.as_slice().sort_by(key)
}

// Reverses the elements in place.
pub fn reverse(self: &UnmanagedList($T)) {
    self.as_slice().reverse()
}

// Sets every live element to `value`. The length is unchanged.
pub fn fill(self: &UnmanagedList($T), value: T) {
    self.as_slice().fill(value)
}

// =============================================================================
// UnmanagedList: transformations
//
// Each returns a fresh list and leaves the receiver untouched.
// =============================================================================

// Returns a new list of `f(x)` for every element, in order, allocated through `allocator`.
pub fn map(self: &UnmanagedList($T), f: $F, allocator: &Allocator) UnmanagedList($U) {
    let out: UnmanagedList(U) = unmanaged_list(self.len, allocator)
    for x in self {
        out.push(f(x), allocator)
    }
    return move out
}

// Returns a new list of the elements `keep` accepts, in order.
pub fn filter(self: &UnmanagedList($T), keep: $F, allocator: &Allocator) UnmanagedList(T) {
    let out: UnmanagedList(T) = unmanaged_list(self.len, allocator)
    for x in self {
        if keep(x) {
            out.push(x, allocator)
        }
    }
    return move out
}

// Returns a new list of the elements `drop` rejects, in order: `filter` with the predicate negated.
pub fn remove(self: &UnmanagedList($T), drop: $F, allocator: &Allocator) UnmanagedList(T) {
    let out: UnmanagedList(T) = unmanaged_list(self.len, allocator)
    for x in self {
        let dropped: bool = drop(x)
        if !dropped {
            out.push(x, allocator)
        }
    }
    return move out
}

// Returns a new list of everything after the first `n` elements; empty when `n` exceeds the length.
pub fn drop_first(self: &UnmanagedList($T), n: usize, allocator: &Allocator) UnmanagedList(T) {
    let out: UnmanagedList(T) = unmanaged_list(self.len, allocator)
    let start = if n > self.len { self.len } else { n }
    for i in start..self.len {
        out.push(self[i], allocator)
    }
    return move out
}

// Returns a reversed copy.
pub fn reversed(self: &UnmanagedList($T), allocator: &Allocator) UnmanagedList(T) {
    let out: UnmanagedList(T) = unmanaged_list(self.len, allocator)
    let i = self.len
    while i > 0 {
        i = i - 1
        out.push(self[i], allocator)
    }
    return move out
}

// Returns a new list of the last `n` elements, or all of them when `n` exceeds the length.
pub fn take_last(self: &UnmanagedList($T), n: usize, allocator: &Allocator) UnmanagedList(T) {
    let out: UnmanagedList(T) = unmanaged_list(n, allocator)
    let start = if n > self.len { 0 as usize } else { self.len - n }
    for i in start..self.len {
        out.push(self[i], allocator)
    }
    return move out
}

// Returns a new list pairing elements positionally with `other`, stopping at the shorter.
pub fn zip(self: &UnmanagedList($T), other: &UnmanagedList($B),
    allocator: &Allocator) UnmanagedList((T, B)) {
    let n = if self.len < other.len { self.len } else { other.len }
    let out: UnmanagedList((T, B)) = unmanaged_list(n, allocator)
    for i in 0..n {
        out.push((self[i], other[i]), allocator)
    }
    return move out
}

// Splits into two new lists, (accepted, rejected) by `pred`, each in order.
pub fn partition(self: &UnmanagedList($T), pred: $F, allocator: &Allocator) (UnmanagedList(T),
    UnmanagedList(T)) {
    let yes: UnmanagedList(T) = unmanaged_list(0, allocator)
    let no: UnmanagedList(T) = unmanaged_list(0, allocator)
    for x in self {
        if pred(x) {
            yes.push(x, allocator)
        } else {
            no.push(x, allocator)
        }
    }
    return (move yes, move no)
}

// Returns a new list of every inner list's elements, in order, in one allocation sized from the
// inner lengths. The inner lists are left untouched; their elements are copied, owning ones through
// `clone`.
pub fn flatten(self: &UnmanagedList(List($T)), allocator: &Allocator) UnmanagedList(T) {
    let total: usize = 0
    for &inner in self {
        total = total + inner.len
    }
    let out: UnmanagedList(T) = unmanaged_list(total, allocator)
    for &inner in self {
        out.push_all(inner.as_slice(), allocator)
    }
    return move out
}

// Returns a copy with runs of consecutive `==` duplicates collapsed to one element, `sort | uniq`
// style: sort first for whole-list uniqueness.
pub fn uniq(self: &UnmanagedList($T), allocator: &Allocator) UnmanagedList(T) {
    let out: UnmanagedList(T) = unmanaged_list(0, allocator)
    for i in 0..self.len {
        if i == 0 {
            out.push(self[i], allocator)
        } else {
            let same: bool = self[i] == self[i - 1]
            if !same {
                out.push(self[i], allocator)
            }
        }
    }
    return move out
}

// =============================================================================
// UnmanagedList: operators
// =============================================================================

// Scalar indexing - ref-form. One function covers reads, writes, and address-of; the compiler
// desugars `list[i]`, `list[i] = v`, and `&list[i]` all through this. Panics on out-of-bounds.
pub fn op_index_ref(self: &UnmanagedList($T), index: usize) &T {
    if index >= self.len {
        panic("List: index out of bounds")
    }
    return self.ptr + index
}

// Range indexing: returns a sub-slice of the list's live elements. Out-of-bounds indices are
// clamped; an invalid range yields an empty slice. Value-form overload (returns a new slice);
// distinct idx type from the scalar ref-form above, so the two coexist without ambiguity.
pub fn op_index(self: &UnmanagedList($T), range: Range(usize)) T[] {
    let start = range.start
    let end = range.end
    if start > self.len {
        start = self.len
    }
    if end > self.len {
        end = self.len
    }
    if start > end {
        end = start
    }
    return slice_from_raw_parts(self.ptr + start, end - start)
}

// =============================================================================
// UnmanagedList: iteration
// =============================================================================

// Iterates the elements by value, first to last: `for x in xs`. The iterator is a snapshot of the
// storage; the list is not modified while it is being iterated.
pub fn iter(self: &UnmanagedList($T)) SliceIterator(T) {
    return self.as_slice().iter()
}

// Iterates the elements by reference, first to last: `for &x in xs`, for loops that write elements
// in place. The list is not grown while it is being iterated.
pub fn iter_ref(self: &UnmanagedList($T)) SliceRefIterator(T) {
    return self.as_slice().iter_ref()
}

// Iterates the elements by value, last to first, without copying the list. The iterator is a
// snapshot of the storage; the list is not modified while it is being iterated.
pub fn iter_rev(self: &UnmanagedList($T)) SliceRevIterator(T) {
    return self.as_slice().iter_rev()
}

// =============================================================================
// The managed API: `List` and `ListRef`
//
// The same operations over the carrier's own allocator, forwarded to the unmanaged function - the
// one implementation - by a generator, so a managed carrier is any type with a `__storage` reaching
// an `UnmanagedList(T)` and an `allocator` beside it. A transformation takes an optional allocator
// for its result and otherwise uses the receiver's; it returns a `List` either way, since a new
// list needs storage of its own. Only what owns storage lives outside the template: `deinit`,
// `to_owned_slice` and `flat_map` are `List`'s alone.
// =============================================================================

#define(managed_list, Self: Ident) {
    // Ensures room for at least `capacity` elements. Panics when the allocation fails.
    pub fn reserve(self: &#(Self)($T), capacity: usize) {
        self.__storage.reserve(capacity, self.allocator)
    }

    // Appends `value`, growing when full. Panics when the allocation fails.
    pub fn push(self: &#(Self)($T), value: T) {
        self.__storage.push(move value, self.allocator)
    }

    // Appends every element of `xs`, in order, cloning owning elements. `xs` must not alias the
    // list's own storage.
    pub fn push_all(self: &#(Self)($T), xs: T[]) {
        self.__storage.push_all(xs, self.allocator)
    }

    // Drops every element, deiniting each. The backing storage is kept for reuse.
    pub fn clear(self: &#(Self)($T)) {
        self.__storage.clear(self.allocator)
    }

    // Drops every element past the first `n`, deiniting each. The backing storage is kept.
    pub fn truncate(self: &#(Self)($T), n: usize) {
        self.__storage.truncate(n, self.allocator)
    }

    // Inserts `value` at `index`, shifting everything at and after it one slot toward the end.
    // `index == len` appends. Panics past the end.
    pub fn insert(self: &#(Self)($T), index: usize, value: T) {
        self.__storage.insert(index, move value, self.allocator)
    }

    // Returns a new list of `f(x)` for every element, in order.
    pub fn map(self: &#(Self)($T), f: $F, allocator: &Allocator? = null) List($U) {
        const alloc = allocator ?? self.allocator
        return .{ __storage = self.__storage.map(f, alloc), allocator = alloc }
    }

    // Returns a new list of the elements `keep` accepts, in order.
    pub fn filter(self: &#(Self)($T), keep: $F, allocator: &Allocator? = null) List(T) {
        const alloc = allocator ?? self.allocator
        return .{ __storage = self.__storage.filter(keep, alloc), allocator = alloc }
    }

    // Returns a new list of the elements `drop` rejects, in order: `filter` with the predicate
    // negated.
    pub fn remove(self: &#(Self)($T), drop: $F, allocator: &Allocator? = null) List(T) {
        const alloc = allocator ?? self.allocator
        return .{ __storage = self.__storage.remove(drop, alloc), allocator = alloc }
    }

    // Returns a new list of everything after the first `n` elements; empty when `n` exceeds the
    // length.
    pub fn drop_first(self: &#(Self)($T), n: usize, allocator: &Allocator? = null) List(T) {
        const alloc = allocator ?? self.allocator
        return .{ __storage = self.__storage.drop_first(n, alloc), allocator = alloc }
    }

    // Returns a reversed copy.
    pub fn reversed(self: &#(Self)($T), allocator: &Allocator? = null) List(T) {
        const alloc = allocator ?? self.allocator
        return .{ __storage = self.__storage.reversed(alloc), allocator = alloc }
    }

    // Returns a new list of the last `n` elements, or all of them when `n` exceeds the length.
    pub fn take_last(self: &#(Self)($T), n: usize, allocator: &Allocator? = null) List(T) {
        const alloc = allocator ?? self.allocator
        return .{ __storage = self.__storage.take_last(n, alloc), allocator = alloc }
    }

    // Returns a new list pairing elements positionally with `other`, stopping at the shorter.
    pub fn zip(self: &#(Self)($T), other: &#(Self)($B), allocator: &Allocator? = null) List((T,
            B)) {
        const alloc = allocator ?? self.allocator
        return .{ __storage = self.__storage.zip(other.op_deref(), alloc), allocator = alloc }
    }

    // Splits into two new lists, (accepted, rejected) by `pred`, each in order.
    pub fn partition(self: &#(Self)($T), pred: $F,
        allocator: &Allocator? = null) (List(T), List(T)) {
        const alloc = allocator ?? self.allocator
        const parts = self.__storage.partition(pred, alloc)
        return (.{ __storage = move parts.0, allocator = alloc }, .{ __storage = move parts.1,
            allocator = alloc })
    }

    // Returns a new list of every inner list's elements, in order, in one allocation sized from the
    // inner lengths. The inner lists are left untouched.
    pub fn flatten(self: &#(Self)(List($T)), allocator: &Allocator? = null) List(T) {
        const alloc = allocator ?? self.allocator
        return .{ __storage = self.__storage.flatten(alloc), allocator = alloc }
    }

    // Returns a copy with runs of consecutive `==` duplicates collapsed to one element, `sort |
    // uniq` style: sort first for whole-list uniqueness.
    pub fn uniq(self: &#(Self)($T), allocator: &Allocator? = null) List(T) {
        const alloc = allocator ?? self.allocator
        return .{ __storage = self.__storage.uniq(alloc), allocator = alloc }
    }
}

#managed_list(List)
#managed_list(ListRef)

// Returns a deep copy: copyable elements are copied bitwise, the others through their own `clone`.
//
// - `allocator`: kept for the copy's whole life.
pub fn clone(self: &List($T), allocator: &Allocator) List(T) {
    return .{ __storage = self.__storage.clone(allocator), allocator = allocator }
}

// A deep copy on the receiver's allocator.
pub fn clone(self: &List($T)) List(T) {
    return self.clone(self.allocator)
}

// Deinits every live element and frees the backing storage. Idempotent: a second call is a no-op.
pub fn deinit(self: &List($T)) {
    self.__storage.deinit(self.allocator)
}

// Element form (README, Expected functions). The value carries its own allocator.
pub fn deinit(self: &List($T), allocator: &Allocator) {
    self.deinit()
}

// Hands over the buffer as a `(T[], &Allocator)` pair and resets the list to empty, so a later
// `deinit()` is a no-op; `let l = list(...); defer l.deinit(); ...; l.to_owned_slice()` is the
// pattern. The slice is shrunk to fit. Elements are not deinited: the caller owns them now and
// frees the slice with `alloc.free(s)`, deiniting the elements first when they own anything.
pub fn to_owned_slice(self: &List($T)) (T[], &Allocator) {
    return (self.__storage.to_owned_slice(self.allocator), self.allocator)
}

// Returns a new list of the results of `f` concatenated, in order. Each list `f` returns is
// consumed: `f` hands over ownership and this frees it. ponytail: one allocation and one free per
// element, plus a copy into `out`. The intermediates are pure scratch - nothing outlives the loop
// iteration that made it - so the allocator traffic is the whole cost of the call for small
// results. Upgrade path: thread an allocator into `f` and hand it a temporary arena created once
// per call, so the intermediates are bump allocations reclaimed in one shot; better still, let `f`
// append directly into `out` and drop the intermediates entirely. Both need an API decision about
// the callback's shape, not just an implementation change - see docs/known-issues.md.
pub fn flat_map(self: &List($T), f: $F, allocator: &Allocator? = null) List($U) {
    let out: List(U) = list(self.len, allocator ?? self.allocator)
    for x in self {
        let part = f(x)
        out.push_all(part.as_slice())
        part.deinit()
    }
    return move out
}

// =============================================================================
// Tests
// =============================================================================

fn test_is_even(x: i32) bool { return x % 2 == 0 }

test "search utilities: contains, index_of, first, last" {
    let xs: List(i32) = list(3)
    defer xs.deinit()
    xs.push(10i32)
    xs.push(20i32)
    xs.push(30i32)

    assert_true(xs.contains(20i32), "present value is found")
    assert_true(!xs.contains(99i32), "absent value is not")
    assert_eq(xs.index_of(30i32).unwrap(), 2 as usize, "index of the last element")
    assert_true(xs.index_of(99i32).is_none(), "absent value has no index")
    assert_eq(xs.first().unwrap(), 10i32, "first element")
    assert_eq(xs.last().unwrap(), 30i32, "last element")

    let empty: List(i32) = list(0)
    defer empty.deinit()
    assert_true(empty.first().is_none(), "empty list has no first")
    assert_true(empty.last().is_none(), "empty list has no last")
}

test "a ListRef grows the field it wraps and owns nothing" {
    let counting = counting_allocator(global())
    const alloc = counting.allocator()
    let field: UnmanagedList(i32)
    let h = field.managed(&alloc)
    h.push(1i32)
    h.push(2i32)
    assert_eq(field.len, 2 as usize, "pushes landed in the field")
    assert_eq(h[1], 2i32, "reads through the handle")
    let total = 0i32
    for x in h {
        total = total + x
    }
    assert_eq(total, 3i32, "for through the handle")
    let doubled = h.map(fn(v: i32) i32 { v * 2 })
    assert_eq(doubled[1], 4i32, "a transformation yields a List on the handle's allocator")
    doubled.deinit()
    field.deinit(&alloc)
    assert_eq(counting.live_bytes, 0 as usize, "the field's allocator saw every free")
}

test "list from a slice, first_ref, last_ref and iter_rev" {
    let src: List(i32) = list(0)
    defer src.deinit()
    src.push(1i32)
    src.push(2i32)
    src.push(3i32)
    let xs: List(i32) = list(src.as_slice())
    defer xs.deinit()
    assert_eq(xs.len, 3 as usize, "copied every element")
    let top = xs.last_ref().unwrap()
    top.* = 30i32
    assert_eq(xs[2], 30i32, "last_ref writes through")
    assert_eq(xs.first_ref().unwrap().*, 1i32, "first_ref reads the head")
    let seen: List(i32) = list(0)
    defer seen.deinit()
    for x in xs.iter_rev() {
        seen.push(x)
    }
    assert_eq(seen[0], 30i32, "iter_rev starts at the end")
    assert_eq(seen[2], 1i32, "and finishes at the head")
    let empty: List(i32) = list(0)
    defer empty.deinit()
    assert_true(empty.last_ref().is_none(), "no last on an empty list")
}

test "a zero-initialised List is a valid empty list" {
    let xs: List(i32)
    defer xs.deinit()
    assert_eq(xs.len, 0 as usize, "empty")
    xs.push(7)
    xs.push(8)
    assert_eq(xs.len, 2 as usize, "grew through the global allocator")
    assert_eq(xs[1], 8, "readable")
}

test "an UnmanagedList takes its allocator at every allocating call" {
    let counting = counting_allocator(global())
    const alloc = counting.allocator()
    let xs: UnmanagedList(i32) = unmanaged_list(0, &alloc)
    xs.push(1, &alloc)
    xs.push(2, &alloc)
    xs.push(3, &alloc)
    assert_eq(xs.len, 3 as usize, "len through op_deref")
    assert_eq(xs[0], 1, "index")
    assert_eq(xs.pop().unwrap(), 3, "pop through op_deref")
    let sum = 0
    for x in xs {
        sum = sum + x
    }
    assert_eq(sum, 3, "for")
    const doubled = xs.map(fn(v: i32) i32 { v * 2 }, &alloc)
    assert_eq(doubled[1], 4, "combinator with explicit allocator")
    doubled.deinit(&alloc)
    xs.deinit(&alloc)
    assert_eq(counting.live_bytes, 0 as usize, "everything went back through that allocator")
}

test "for &x writes through to the list, directly and via as_slice" {
    let xs: List(u32) = list(0)
    defer xs.deinit()
    xs.push(1u32)
    xs.push(2u32)
    for &x in xs { x.* = x.* * 10 }
    for &x in xs.as_slice() { x.* = x.* + 1 }
    assert_eq(xs[0], 11u32, "first element written through both refs")
    assert_eq(xs[1], 21u32, "second element written through both refs")
}

test "truncate drops the tail and clamps at the length" {
    let xs: List(u32) = list(0)
    defer xs.deinit()
    xs.push(1u32)
    xs.push(2u32)
    xs.push(3u32)
    xs.truncate(2)
    assert_eq(xs.len, 2 as usize, "the tail past n is dropped")
    assert_eq(xs[1], 2u32, "the kept prefix is untouched")
    xs.truncate(5)
    assert_eq(xs.len, 2 as usize, "a length at or below n is left alone")
}

test "push_all appends a slice in order" {
    let xs: List(u32) = list(0)
    defer xs.deinit()
    xs.push(1u32)
    let more: List(u32) = list(2)
    defer more.deinit()
    more.push(2u32)
    more.push(3u32)
    xs.push_all(more.as_slice())
    assert_eq(xs.len, 3 as usize, "three elements after push_all")
    assert_eq(xs[0], 1u32, "existing element untouched")
    assert_eq(xs[2], 3u32, "order preserved")

    let none: List(u32) = list(0)
    defer none.deinit()
    xs.push_all(none.as_slice())
    assert_eq(xs.len, 3 as usize, "empty source is a no-op")
}

test "push_all and list(source) clone owning elements" {
    let src: List(OwnedString) = list(1)
    defer src.deinit()
    src.push(from_view("alpha"))

    let xs: List(OwnedString) = list(0)
    defer xs.deinit()
    xs.push_all(src.as_slice())
    assert_true(xs[0].as_view() == "alpha", "element cloned by push_all")

    let ys: List(OwnedString) = list(src.as_slice())
    defer ys.deinit()
    assert_true(ys[0].as_view() == "alpha", "element cloned by the constructor")

    let zs = src.clone()
    defer zs.deinit()
    assert_true(zs[0].as_view() == "alpha", "element cloned by clone")
    // Four lists each own an "alpha"; the test allocator reports a double free or a leak.
}

test "binary search trickles through to the list" {
    let xs: List(i32) = list(0)
    defer xs.deinit()
    xs.push(1)
    xs.push(4)
    xs.push(4)
    xs.push(9)
    assert_eq(xs.binary_search(4).unwrap(), 1 as usize, "first 4")
    assert_eq(xs.as_slice().upper_bound(4), 3 as usize, "the primitives stay on the slice")
    assert_eq(xs.last_index_of(4).unwrap(), 2 as usize, "last 4")
    xs.fill(7)
    assert_eq(xs[0] + xs[3], 14, "filled in place")
    assert_true(xs.binary_search(5).is_none(), "absent")
}

test "flatten concatenates inner lists in one allocation" {
    let a: List(i32) = list(0)
    a.push(1)
    a.push(2)
    let b: List(i32) = list(0)
    b.push(3)
    let nested: List(List(i32)) = list(0)
    defer nested.deinit()
    nested.push(move a)
    nested.push(move b)
    let flat = nested.flatten()
    defer flat.deinit()
    assert_eq(flat.len, 3 as usize, "all elements")
    assert_eq(flat.cap, 3 as usize, "sized exactly from the inner lengths")
    assert_eq(flat[2], 3, "order kept")
    assert_eq(nested[0].len, 2 as usize, "inner lists untouched")
}

test "map applies f in order and leaves the receiver alone" {
    let xs: List(i32) = list(0)
    defer xs.deinit()
    xs.push(1)
    xs.push(2)
    xs.push(3)

    let doubled = xs.map(fn(v: i32) i32 { v * 2 })
    defer doubled.deinit()
    assert_eq(doubled.len, 3 as usize, "same length")
    assert_eq(doubled[0], 2, "first doubled")
    assert_eq(doubled[2], 6, "last doubled")
    assert_eq(xs[0], 1, "receiver untouched")
}

test "flat_map concatenates and frees the intermediates" {
    let xs: List(i32) = list(0)
    defer xs.deinit()
    xs.push(1)
    xs.push(2)

    let out = xs.flat_map(fn(v: i32) List(i32) {
        let part: List(i32) = list(2)
        part.push(v)
        part.push(v * 10)
        part
    })
    defer out.deinit()
    assert_eq(out.len, 4 as usize, "two elements each")
    assert_eq(out[1], 10, "second of the first pair")
    assert_eq(out[2], 2, "first of the second pair")
}

test "filter keeps matches, remove keeps the rest" {
    let xs: List(i32) = list(0)
    defer xs.deinit()
    for i in 0..6usize { xs.push(i as i32) }

    let evens = xs.filter(fn(v: i32) bool { v % 2 == 0 })
    defer evens.deinit()
    let odds = xs.remove(fn(v: i32) bool { v % 2 == 0 })
    defer odds.deinit()

    assert_eq(evens.len, 3 as usize, "three evens")
    assert_eq(odds.len, 3 as usize, "three odds")
    assert_eq(evens[0], 0, "first even")
    assert_eq(odds[0], 1, "first odd")
    assert_eq(evens.len + odds.len, xs.len, "the two partitions cover the input")
}

test "fold and fold_right differ in association" {
    let xs: List(i32) = list(0)
    defer xs.deinit()
    xs.push(1)
    xs.push(2)
    xs.push(3)

    // Subtraction is not associative, so the two directions disagree:
    // left  ((0-1)-2)-3 = -6
    // right 1-(2-(3-0)) = 2
    // The seed pins the accumulator type ($A): a bare `0` won't default, because `f` is duck-typed
    // ($F) and only constrains A at instantiation.
    let l = xs.fold(0i32, fn(acc, v) { acc - v })
    let r = xs.fold_right(0i32, fn(v, acc) { v - acc })
    assert_eq(l, -6i32, "left-associated")
    assert_eq(r, 2i32, "right-associated")
}

test "drop_first skips a prefix and clamps past the end" {
    let xs: List(i32) = list(0)
    defer xs.deinit()
    for i in 0..4usize { xs.push(i as i32) }

    let tail = xs.drop_first(2 as usize)
    defer tail.deinit()
    assert_eq(tail.len, 2 as usize, "two remain")
    assert_eq(tail[0], 2, "starts after the prefix")

    let past = xs.drop_first(99 as usize)
    defer past.deinit()
    assert_eq(past.len, 0 as usize, "dropping past the end is empty, not an error")
}

test "search utilities: find, find_index, any, all" {
    let xs: List(i32) = list(3)
    defer xs.deinit()
    xs.push(1i32)
    xs.push(2i32)
    xs.push(4i32)

    assert_eq(xs.find(test_is_even).unwrap(), 2i32, "first even element")
    assert_eq(xs.find_index(test_is_even).unwrap(), 1 as usize, "its index")
    assert_true(xs.any(test_is_even), "any is true when one matches")
    assert_true(!xs.all(test_is_even), "all is false when one does not")

    let evens: List(i32) = list(2)
    defer evens.deinit()
    evens.push(2i32)
    evens.push(4i32)
    assert_true(evens.all(test_is_even), "all is true when every element matches")

    let empty: List(i32) = list(0)
    defer empty.deinit()
    assert_true(!empty.any(test_is_even), "any is false on empty")
    assert_true(empty.all(test_is_even), "all is vacuously true on empty")
}

test "deinit is idempotent on every core container" {
    // Any deinit may run twice: state nulls on the first call, so the second is a no-op, not a
    // double free.
    let xs: List(OwnedString) = list(2)
    xs.push(from_view("alpha"))
    xs.push(from_view("beta"))
    xs.deinit()
    xs.deinit()
    assert_eq(xs.len, 0 as usize, "list is empty after deinit")

    let d: Dict(OwnedString, i32) = dict()
    d.set("k", 1i32)
    d.deinit()
    d.deinit()

    let s = from_view("gamma")
    s.deinit()
    s.deinit()

    let sb = string_builder(8)
    sb.append("x")
    sb.deinit()
    sb.deinit()

    let o: OwnedString? = Some(from_view("delta"))
    o.deinit()
    o.deinit()
    assert_true(o.is_none(), "option resets to None on deinit")
}

test "combinators accept capturing closures with unannotated params" {
    let xs: List(i32) = list(3)
    defer xs.deinit()
    xs.push(1i32)
    xs.push(2i32)
    xs.push(3i32)

    let floor = 1
    let scale = 10
    let kept = xs.filter(fn(v) { v > floor })
    defer kept.deinit()
    let scaled = kept.map(fn(v) { v * scale })
    defer scaled.deinit()
    assert_eq(scaled.len, 2 as usize, "two elements pass the floor")
    assert_eq(scaled[0], 20i32, "closure saw the captured scale")
}

test "each and count" {
    let xs: List(i32) = list(3)
    defer xs.deinit()
    xs.push(1i32)
    xs.push(2i32)
    xs.push(3i32)

    // Captures are by value and read-only: mutate through a captured reference.
    let sum = 0i32
    let sum_ref = &sum
    xs.each(fn(v) { sum_ref.* = sum_ref.* + v })
    assert_eq(sum, 6i32, "each visited every element")

    assert_eq(xs.count(test_is_even), 1 as usize, "one even element")
}

test "min max min_by max_by on lists" {
    let xs: List(i32) = list(3)
    defer xs.deinit()
    xs.push(4i32)
    xs.push(1i32)
    xs.push(3i32)

    assert_eq(xs.min().unwrap(), 1i32, "smallest")
    assert_eq(xs.max().unwrap(), 4i32, "largest")
    assert_eq(xs.min_by(fn(v) { 0 - v }).unwrap(), 4i32, "smallest key = largest value")
    assert_eq(xs.max_by(fn(v) { 0 - v }).unwrap(), 1i32, "largest key = smallest value")

    let empty: List(i32) = list(0)
    defer empty.deinit()
    assert_true(empty.min().is_none(), "empty min is null")
    assert_true(empty.min_by(fn(v) { v }).is_none(), "empty min_by is null")
}

test "sort_by orders by key" {
    let xs: List(i32) = list(3)
    defer xs.deinit()
    xs.push(1i32)
    xs.push(3i32)
    xs.push(2i32)

    xs.sort_by(fn(v) { 0 - v })
    assert_eq(xs[0], 3i32, "descending by negated key")
    assert_eq(xs[2], 1i32, "smallest last")
}

test "reverse in place and reversed copy" {
    let xs: List(i32) = list(3)
    defer xs.deinit()
    xs.push(1i32)
    xs.push(2i32)
    xs.push(3i32)

    let back = xs.reversed()
    defer back.deinit()
    assert_eq(back[0], 3i32, "copy is reversed")
    assert_eq(xs[0], 1i32, "receiver untouched by reversed()")

    xs.reverse()
    assert_eq(xs[0], 3i32, "in-place reversal")
    assert_eq(xs[2], 1i32, "ends swapped")

    let two: List(i32) = list(2)
    defer two.deinit()
    two.push(7i32)
    two.push(9i32)
    two.reverse()
    assert_eq(two[0], 9i32, "even length reverses fully")
}

test "take_last clamps like drop_first" {
    let xs: List(i32) = list(4)
    defer xs.deinit()
    for i in 0..4usize { xs.push(i as i32) }

    let tail = xs.take_last(2 as usize)
    defer tail.deinit()
    assert_eq(tail.len, 2 as usize, "two elements")
    assert_eq(tail[0], 2i32, "the last two")

    let all_of_them = xs.take_last(99 as usize)
    defer all_of_them.deinit()
    assert_eq(all_of_them.len, 4 as usize, "over-asking yields everything")
}

test "zip pairs positionally and stops at the shorter list" {
    let xs: List(i32) = list(3)
    defer xs.deinit()
    xs.push(1i32)
    xs.push(2i32)
    xs.push(3i32)
    let ys: List(i32) = list(2)
    defer ys.deinit()
    ys.push(10i32)
    ys.push(20i32)

    let pairs = xs.zip(&ys)
    defer pairs.deinit()
    assert_eq(pairs.len, 2 as usize, "shorter side bounds the zip")
    assert_eq(pairs[0].0, 1i32, "left element")
    assert_eq(pairs[1].1, 20i32, "right element")
}

test "partition splits by predicate preserving order" {
    let xs: List(i32) = list(4)
    defer xs.deinit()
    for i in 0..4usize { xs.push(i as i32) }

    let parts = xs.partition(test_is_even)
    let evens = move parts.0
    defer evens.deinit()
    let odds = move parts.1
    defer odds.deinit()
    assert_eq(evens.len, 2 as usize, "two evens")
    assert_eq(evens[0], 0i32, "in order")
    assert_eq(odds[1], 3i32, "rejects in order too")
}

test "uniq collapses consecutive runs only" {
    let xs: List(i32) = list(6)
    defer xs.deinit()
    xs.push(1i32)
    xs.push(1i32)
    xs.push(2i32)
    xs.push(2i32)
    xs.push(2i32)
    xs.push(1i32)

    let out = xs.uniq()
    defer out.deinit()
    assert_eq(out.len, 3 as usize, "runs collapsed")
    assert_eq(out[0], 1i32, "first run")
    assert_eq(out[1], 2i32, "second run")
    assert_eq(out[2], 1i32, "non-consecutive duplicate survives")
}

test "join concatenates with separator" {
    let xs: List(String) = list(3)
    defer xs.deinit()
    xs.push("a")
    xs.push("b")
    xs.push("c")

    let joined = xs.join(", ")
    defer joined.deinit()
    assert_eq(joined.as_view(), "a, b, c", "separators between elements only")

    let one: List(String) = list(1)
    defer one.deinit()
    one.push("solo")
    let single = one.join(", ")
    defer single.deinit()
    assert_eq(single.as_view(), "solo", "no separator for one element")
}

test "filled_list gives a list of length count, ready to index" {
    let xs: List(usize) = filled_list(3, 7)
    defer xs.deinit()
    assert_eq(xs.len, 3 as usize, "length is the count, not a reserved capacity")
    assert_eq(xs[0], 7 as usize, "every slot holds the value")
    assert_eq(xs[2], 7 as usize, "including the last")
    xs[1] = 9
    assert_eq(xs[1], 9 as usize, "and the slots are assignable")

    let empty: List(bool) = filled_list(0, true)
    defer empty.deinit()
    assert_eq(empty.len, 0 as usize, "a count of zero is an empty list")
}
