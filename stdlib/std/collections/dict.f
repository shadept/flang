// Hash maps in two flavours, the managed and unmanaged split of spec §9.4:
//
//   UnmanagedDict(K, V)  the table: `entries`, `length`, `dead`, `cap`, and every operation on it.
//                        The ones that allocate or free take the allocator as an argument
//                        (`d.set(k, v, alloc)`), so a composite stores one allocator for all its
//                        children and passes it at the call that allocates.
//   Dict(K, V)           an `UnmanagedDict` with its allocator beside it (`d.set(k, v)`). It reaches
//                        the table through `op_deref`, so `d.len()` and `d.get(k)` read the same on
//                        either, and its allocating functions are one-line wrappers. A null
//                        allocator is the global one (§4.1), so a zero-initialised `Dict` is a
//                        valid empty dict.
//
// `__storage` is readable like any field; treat it as private. Calling the unmanaged API on a
// `Dict` through it, or through the `op_deref` peel (`d.set(k, v, other_alloc)`), compiles and
// mixes allocators.
//
// Open addressing with linear probing. The stored hash doubles as the slot state (the combined-hash
// trick): 0 is EMPTY, 1 is a tombstone, and >= 2 is an occupied slot holding the key's hash.
// `hash_key` remaps the two reserved values (`h < 2` becomes `h + 2`), a negligible dent in a
// 64-bit hash space, and the state byte - and its alignment padding - disappears from every entry.
// A zeroed table is all-empty, so `alloc_table` and `clear` stay a plain memset.

import std.allocator
import std.mem
import std.option
import std.string
import std.test

const HASH_EMPTY: usize = 0
const HASH_DEAD: usize = 1

// A single entry in the hash map. `hash` is also the slot state - see the header comment; `key` and
// `value` are meaningful only when it is at least 2.
pub type Entry = struct(K, V) {
    hash: usize
    key: K
    value: V
}

// A hash map from `K` to `V` that carries no allocator: every operation that grows or frees the
// table takes one as its last argument, and the same allocator must be passed every time. A
// zero-initialised value is a valid empty dict. Keys and values are owned: `deinit` deinits each
// before freeing the table. `K` needs `hash` and `==`.
pub type UnmanagedDict = struct(K, V) {
    owned entries: &Entry(K, V)
    length: usize
    // Tombstones left by removals. They occupy probe slots until the next rehash, so the load
    // factor must count them or a delete-heavy dict fills up while `length` stays low.
    dead: usize
    cap: usize
}

// A hash map from `K` to `V` that owns its table and remembers the allocator it grows and frees
// through. Every `UnmanagedDict` operation applies to it as well, reached through `op_deref`, and
// the allocating ones come without the allocator argument. A zero-initialised value is a valid
// empty dict on the global allocator.
pub type Dict = struct(K, V) {
    __storage: UnmanagedDict(K, V)
    allocator: &Allocator
}

// Reaches the table: `d.len()`, `d.get(k)` and every `UnmanagedDict` read resolve through this.
pub fn op_deref(self: &Dict($K, $V)) &UnmanagedDict(K, V) {
    return &self.__storage
}

// The `Dict` API over an `UnmanagedDict` owned by someone else, for a scope in which the allocator
// is known: `s.index.managed(s.allocator).set(k, v)` inserts into `s.index` in place. It holds the
// table by reference, so nothing is copied and there is nothing to deinit; the owner of the table
// frees it, through the same allocator.
pub type DictRef = struct(K, V) {
    __storage: &UnmanagedDict(K, V)
    allocator: &Allocator
}

// Returns the `Dict` API over `d`, growing it through `allocator`. `d` must outlive the handle and
// keep allocating through the same allocator.
pub fn managed(self: &UnmanagedDict($K, $V), allocator: &Allocator) DictRef(K, V) {
    return .{ __storage = self, allocator = allocator }
}

// Reaches the wrapped table: every `UnmanagedDict` read, indexing and `for` resolve through this.
pub fn op_deref(self: &DictRef($K, $V)) &UnmanagedDict(K, V) {
    return self.__storage
}

// =============================================================================
// Construction
// =============================================================================

// Creates an unmanaged dict whose table starts at `capacity` slots, rounded up to a power of two
// (`probe_slot` masks instead of dividing; minimum 8). Zero allocates nothing; a zero-initialised
// `UnmanagedDict` is the same empty dict. Growth still triggers at the 75% load factor, so the
// table holds about three quarters of `capacity` entries before its first rehash.
//
// - `allocator`: grows and frees the table. Pass the same one to every allocating call.
//
// Panics when the allocation fails.
pub fn unmanaged_dict(capacity: usize, allocator: &Allocator) UnmanagedDict($K, $V) {
    let out: UnmanagedDict(K, V)
    if capacity > 0 {
        out.alloc_table(next_pow2_min8(capacity), allocator)
    }
    return move out
}

// Construct an empty Dict. Storage is allocated lazily on the first `set` / `op_set_index`. `K` and
// `V` are inferred from the call's expected type (e.g. `let d: Dict(String, i32) = dict()`).
pub fn dict(allocator: &Allocator? = null) Dict($K, $V) {
    let out: Dict(K, V)
    out.allocator = allocator.or_global()
    return move out
}

// Creates a dict whose table starts at `capacity` slots and that allocates through `allocator` for
// its whole life.
pub fn dict(capacity: usize, allocator: &Allocator) Dict($K, $V) {
    return dict(capacity, Some(allocator))
}

// Construct a Dict whose table starts at `capacity` slots, rounded up as `unmanaged_dict` does.
// `dict(0)` is the lazy empty form.
//
// - `allocator`: kept for the dict's whole life. Null is the global allocator.
pub fn dict(capacity: usize, allocator: &Allocator? = null) Dict($K, $V) {
    let out: Dict(K, V)
    out.allocator = allocator.or_global()
    out.__storage = unmanaged_dict(capacity, out.allocator)
    return move out
}

// The smallest power of two at or above `v`, floored at 8 - every capacity branch must yield one,
// or `probe_slot`'s mask breaks.
fn next_pow2_min8(v: usize) usize {
    let n: usize = 8
    while n < v { n = n * 2 }
    return n
}

// Install a zeroed table of `cap` slots (all states empty). `cap` must be a power of two.
fn alloc_table(self: &UnmanagedDict($K, $V), cap: usize, allocator: &Allocator) {
    const alloc_size: usize = cap * size_of(Entry(K, V))
    const raw: u8[] = allocator.alloc(alloc_size, 8).expect("dict: allocation failed")
    memset(raw.ptr, 0, alloc_size)
    self.entries = raw.ptr as &Entry(K, V)
    self.cap = cap
}

// Slot for the `i`th linear probe of hash `h`. Capacity is always a power of two (`ensure_capacity`
// starts at 8 and only doubles), so the wrap is a mask - a `%` here is a hardware divide on every
// probe of every lookup.
fn probe_slot(h: usize, i: usize, cap: usize) usize {
    return (h + i) & (cap - 1)
}

// Hash a key using the public hash() function, remapped off the two reserved slot states. Types
// with custom hash semantics (e.g. String, OwnedString) provide their own hash() overload, so Dict
// automatically uses content-aware hashing.
fn hash_key(key: &$K) usize {
    const h = key.hash()
    if h < 2 {
        return h + 2
    }
    return h
}

// A borrowed `String` dressed as an `OwnedString` so it hashes and compares like one - no
// allocation for a lookup by view.
fn fake_owned(key: String) OwnedString {
    return .{ ptr = key.ptr, len = key.len, allocator = null }
}

// =============================================================================
// UnmanagedDict: growth and release, allocator explicit
// =============================================================================

// Make room for one more entry: grow when the insert would push the table past a 75% load factor,
// and on the first insert, when there is no table at all. Tombstones count toward the load - see
// `UnmanagedDict.dead`.
fn ensure_capacity(self: &UnmanagedDict($K, $V), allocator: &Allocator) {
    const slots_needed = self.length + self.dead + 1
    if self.cap > 0 and slots_needed * 4 <= self.cap * 3 {
        return
    }

    const old_cap: usize = self.cap
    const old_entries: &Entry(K, V) = self.entries
    // A rehash that mostly clears tombstones keeps its capacity; only live-entry pressure grows the
    // table. Every branch here must yield a power of two - `probe_slot` masks instead of dividing.
    let new_cap: usize = 8
    if old_cap > 0 {
        new_cap = if self.length * 2 <= old_cap { old_cap } else { old_cap * 2 }
    }

    self.alloc_table(new_cap, allocator)
    self.length = 0
    self.dead = 0

    if old_cap > 0 {
        for i in 0..old_cap {
            const old_entry: &Entry(K, V) = old_entries + i
            if old_entry.hash >= 2 {
                const _placed = self.place(old_entry.hash, move old_entry.key, move old_entry.value)
            }
        }
        allocator.free(slice_from_raw_parts(old_entries, old_cap))
    }
}

// Store a key known to be absent in the first tombstone or empty slot on its probe sequence. The
// table must have room (`ensure_capacity`).
fn place(self: &UnmanagedDict($K, $V), h: usize, key: K, value: V) &Entry(K, V) {
    for i in 0..self.cap {
        const entry: &Entry(K, V) = self.entries + probe_slot(h, i, self.cap)
        if entry.hash == HASH_EMPTY or entry.hash == HASH_DEAD {
            if entry.hash == HASH_DEAD {
                self.dead = self.dead - 1
            }
            entry.hash = h
            entry.key = move key
            entry.value = move value
            self.length = self.length + 1
            return entry
        }
    }
    // Unreachable while the load factor is maintained
    panic("dict: set failed - table full")
}

// Inserts `key` with `value` unless the key is present, and returns whether it was inserted.
//
// A present key keeps its entry untouched, and `key` and `value` stay the caller's to deinit; an
// inserted pair is owned by the dict from here. One probe either way, so a membership-then-insert
// check is `if d.add(k, v, alloc) { ... }`. Panics when the table cannot grow.
pub fn add(self: &UnmanagedDict($K, $V), key: K, value: V, allocator: &Allocator) bool {
    if self.find_entry(&key).is_some() {
        return false
    }
    self.ensure_capacity(allocator)
    const _e = self.place(hash_key(&key), move key, move value)
    return true
}

// String-key `add` for `UnmanagedDict(OwnedString, V)`: `key` is a borrowed view, copied into an
// owned key only when it is inserted.
pub fn add(self: &UnmanagedDict(OwnedString, $V), key: String, value: V,
    allocator: &Allocator) bool {
    const fake = fake_owned(key)
    if self.find_entry(&fake).is_some() {
        return false
    }
    self.ensure_capacity(allocator)
    const _e = self.place(hash_key(&fake), from_view(key, allocator), move value)
    return true
}

// Returns a reference to the value for `key`, inserting `make()` under it first when the key is
// absent.
//
// - `make`: `fn() V`, called only on a miss, so an expensive initial value is built once and only
//   when needed. `key` is stored on a miss and stays the caller's on a hit.
//
// The reference is valid until the next insert, which may move the table. Panics when the table
// cannot grow.
pub fn get_or_insert_with(self: &UnmanagedDict($K, $V), key: K, make: $F,
    allocator: &Allocator) &V {
    const found = self.find_entry(&key)
    if found.is_some() {
        const entry = found.unwrap()
        return &entry.value
    }
    self.ensure_capacity(allocator)
    const placed = self.place(hash_key(&key), move key, make())
    return &placed.value
}

// Insert or update a key-value pair. On an update the old value is deinited, and so is `key`, since
// the entry keeps the one it already has. Panics when the allocation fails.
pub fn set(self: &UnmanagedDict($K, $V), key: K, value: V, allocator: &Allocator) {
    const existing = self.find_entry(&key)
    if existing.is_some() {
        const slot = &existing.unwrap().value
        #if !type_info(V).copyable {
            slot.deinit(allocator)
        }
        slot.* = move value
        #if !type_info(K).copyable {
            key.deinit(allocator)
        }
        return
    }
    self.ensure_capacity(allocator)
    const _placed = self.place(hash_key(&key), move key, move value)
}

// String-key insert for `UnmanagedDict(OwnedString, V)`: the key is a borrowed view, copied into an
// owned key only when it is new to the table.
pub fn set(self: &UnmanagedDict(OwnedString, $V), key: String, value: V, allocator: &Allocator) {
    const fake = fake_owned(key)
    const existing = self.find_entry(&fake)
    if existing.is_some() {
        const entry = existing.unwrap()
        #if !type_info(V).copyable {
            entry.value.deinit(allocator)
        }
        entry.value = move value
        return
    }
    self.ensure_capacity(allocator)
    const _placed = self.place(hash_key(&fake), from_view(key, allocator), move value)
}

// Returns a deep copy on `allocator`: copyable keys and values are copied bitwise, the others
// through their own `clone`.
pub fn clone(self: &UnmanagedDict($K, $V), allocator: &Allocator) UnmanagedDict(K, V) {
    let out: UnmanagedDict(K, V) = unmanaged_dict(self.len(), allocator)
    for entry in self {
        #if type_info(K).copyable {
            const k: K = entry.key
        } else {
            const k: K = entry.key.clone(allocator)
        }
        #if type_info(V).copyable {
            const v: V = entry.value
        } else {
            const v: V = entry.value.clone(allocator)
        }
        out.set(move k, move v, allocator)
    }
    return move out
}

// Deinits every live key and value, frees the table and resets to empty, so a second call is a
// no-op.
pub fn deinit(self: &UnmanagedDict($K, $V), allocator: &Allocator) {
    if self.cap > 0 {
        self.deinit_entries(allocator)
        allocator.free(slice_from_raw_parts(self.entries, self.cap))
    }
    self.entries = 0usize as &Entry(K, V)
    self.length = 0
    self.dead = 0
    self.cap = 0
}

// Copies every entry of `other` into this dict, overwriting the value under a key both have.
// Entries are copied bitwise: an owned key or value is then owned by both dicts, and only one may
// deinit it. Panics when the table cannot grow.
pub fn merge(self: &UnmanagedDict($K, $V), other: &UnmanagedDict(K, V), allocator: &Allocator) {
    for e in other.iter() {
        self.set(e.key, e.value, allocator)
    }
}

// =============================================================================
// UnmanagedDict: in-place mutation
// =============================================================================

// Removes `key` and returns its value, or null when absent. The stored key is deinited; the value
// is the caller's to deinit.
pub fn remove(self: &UnmanagedDict($K, $V), key: K, allocator: &Allocator) V? {
    const found = self.find_entry(&key)
    if found.is_none() {
        return null
    }
    const entry = found.unwrap()
    const val: V = move entry.value
    #if !type_info(K).copyable {
        entry.key.deinit(allocator)
    }
    entry.hash = HASH_DEAD
    self.length = self.length - 1
    self.dead = self.dead + 1
    return Some(move val)
}

// String-key `remove` for `UnmanagedDict(OwnedString, V)`: looks the owned key up by the view.
pub fn remove(self: &UnmanagedDict(OwnedString, $V), key: String, allocator: &Allocator) V? {
    return remove(self, fake_owned(key), allocator)
}

// Removes every entry, deiniting each key and value. The table is kept for reuse.
pub fn clear(self: &UnmanagedDict($K, $V), allocator: &Allocator) {
    if self.cap > 0 {
        self.deinit_entries(allocator)
        memset(self.entries as &u8, 0, self.cap * size_of(Entry(K, V)))
    }
    self.length = 0
    self.dead = 0
}

// Deinit every live key and value, leaving the slots as they are.
fn deinit_entries(self: &UnmanagedDict($K, $V), allocator: &Allocator) {
    for i in 0..self.cap {
        const entry: &Entry(K, V) = self.entries + i
        if entry.hash >= 2 {
            #if !type_info(K).copyable {
                entry.key.deinit(allocator)
            }
            #if !type_info(V).copyable {
                entry.value.deinit(allocator)
            }
        }
    }
}

// Mutate the value for `key` in place via `f(&value)`. Returns whether the key was present.
// In-place mutation (not get-modify-set) is the only sound shape for owned values: `set` deinits
// the value it overwrites.
pub fn update(self: &UnmanagedDict($K, $V), key: K, f: $F) bool {
    let r = self.get_ref(key)
    if r.is_none() {
        return false
    }
    f(r.unwrap())
    return true
}

// =============================================================================
// UnmanagedDict: reads
// =============================================================================

// The live entry for `key`, or null. Tombstones fall through and keep probing; the first empty slot
// ends the search.
fn find_entry(self: &UnmanagedDict($K, $V), key: &K) &Entry(K, V)? {
    if self.cap == 0 {
        return null
    }
    const h: usize = hash_key(key)
    for i in 0..self.cap {
        const entry: &Entry(K, V) = self.entries + probe_slot(h, i, self.cap)
        if entry.hash == HASH_EMPTY {
            return null
        }
        // A stored hash is >= 2, so a hash match implies an occupied slot and can never collide
        // with the reserved states.
        if entry.hash == h {
            if entry.key == key.* {
                return Some(entry)
            }
        }
    }
    return null
}

// Bytes the bucket array occupies. Counts every slot, live or not: a dict holds `cap` slots and
// `len` of them carry an entry. What a key or value owns on the heap of its own is not in here.
pub fn capacity_bytes(self: &UnmanagedDict($K, $V)) usize {
    return self.cap * size_of(Entry(K, V))
}

// Returns the number of entries.
pub fn len(self: &UnmanagedDict($K, $V)) usize {
    return self.length
}

// Returns whether there are no entries.
pub fn is_empty(self: &UnmanagedDict($K, $V)) bool {
    return self.length == 0
}

// `d[key]`: the value for `key`, or null when absent.
pub fn op_index(self: &UnmanagedDict($K, $V), key: K) V? {
    return self.get(move key)
}

// Returns the value for `key`, or null when absent.
pub fn get(self: &UnmanagedDict($K, $V), key: K) V? {
    return Some((self.get_ref(move key)?).*)
}

// Returns a reference to the value for `key`, or null when absent. Valid until the next insert,
// which may move the table.
pub fn get_ref(self: &UnmanagedDict($K, $V), key: K) &V? {
    const found = self.find_entry(&key)
    if found.is_none() {
        return null
    }
    const entry = found.unwrap()
    return Some(&entry.value)
}

// String-key `get` for `UnmanagedDict(OwnedString, V)`: looks the owned key up by the view.
pub fn get(self: &UnmanagedDict(OwnedString, $V), key: String) V? {
    return Some((self.get_ref(key)?).*)
}

// String-key `get_ref` for `UnmanagedDict(OwnedString, V)`: looks the owned key up by the view.
pub fn get_ref(self: &UnmanagedDict(OwnedString, $V), key: String) &V? {
    return get_ref(self, fake_owned(key))
}

// Returns whether `key` is present.
pub fn contains(self: &UnmanagedDict($K, $V), key: K) bool {
    return self.find_entry(&key).is_some()
}

// String-key `contains` for `UnmanagedDict(OwnedString, V)`: looks the owned key up by the view.
pub fn contains(self: &UnmanagedDict(OwnedString, $V), key: String) bool {
    return contains(self, fake_owned(key))
}

// The value for `key`, or `fallback` when absent.
pub fn get_or(self: &UnmanagedDict($K, $V), key: K, fallback: V) V {
    let v = self.get(move key)
    if v.is_some() {
        return unwrap(move v)
    }
    return move fallback
}

// The value for `key`, or `make()` when absent - the lazy counterpart of `get_or`, for fallbacks
// that are expensive (or effectful) to build.
pub fn get_or_else(self: &UnmanagedDict($K, $V), key: K, make: $F) V {
    let v = self.get(move key)
    if v.is_some() {
        return unwrap(move v)
    }
    return make()
}

// Calls `f(key, value)` on every entry, in unspecified order.
pub fn each(self: &UnmanagedDict($K, $V), f: $F) {
    for e in self.iter() {
        f(e.key, e.value)
    }
}

// Returns whether any entry satisfies `pred(key, value)`. False when empty.
pub fn any(self: &UnmanagedDict($K, $V), pred: $F) bool {
    for e in self.iter() {
        if pred(e.key, e.value) {
            return true
        }
    }
    return false
}

// Returns whether every entry satisfies `pred(key, value)`. True when empty.
pub fn all(self: &UnmanagedDict($K, $V), pred: $F) bool {
    for e in self.iter() {
        let ok: bool = pred(e.key, e.value)
        if !ok {
            return false
        }
    }
    return true
}

// Returns how many entries satisfy `pred(key, value)`.
pub fn count(self: &UnmanagedDict($K, $V), pred: $F) usize {
    let n: usize = 0
    for e in self.iter() {
        if pred(e.key, e.value) {
            n = n + 1
        }
    }
    return n
}

// =============================================================================
// Iterators
// =============================================================================

// Iterator over a dict's entries by reference, in table order. The dict is not modified while it is
// being iterated: an insert may move the table.
pub type DictIterator = struct(K, V) {
    dict: &UnmanagedDict(K, V)
    current: usize
}

// Iterates the live entries, in unspecified order.
pub fn iter(self: &UnmanagedDict($K, $V)) DictIterator(K, V) {
    return .{ dict = self, current = 0 }
}

// An iterator is its own iterable, so `for e in d.iter()` and the std.iter combinators can consume
// it.
pub fn iter(self: &DictIterator($K, $V)) DictIterator(K, V) {
    return self.*
}

// Advances and returns the next entry, or null after the last.
pub fn next(self: &DictIterator($K, $V)) &Entry(K, V)? {
    for idx in self.current..self.dict.cap {
        const entry: &Entry(K, V) = self.dict.entries + idx
        if entry.hash >= 2 {
            self.current = idx + 1
            // Wrapped explicitly - see the note in core/range.f::next.
            return Some(entry)
        }
    }
    self.current = self.dict.cap
    return null
}

// Iterator over a dict's keys, in unspecified order.
pub type KeysIter = struct(K, V) {
    it: DictIterator(K, V)
}

// An iterator is its own iterable, so adapter chains can consume it.
pub fn iter(self: &KeysIter($K, $V)) KeysIter(K, V) {
    return self.*
}

// Advances and returns the next key, or null after the last.
pub fn next(self: &KeysIter($K, $V)) K? {
    let e = self.it.next()
    if e.is_none() {
        return null
    }
    return Some(e.unwrap().key)
}

// Iterates the keys, in unspecified order.
pub fn keys(self: &UnmanagedDict($K, $V)) KeysIter(K, V) {
    return .{ it = self.iter() }
}

// Iterator over a dict's values, in unspecified order.
pub type ValuesIter = struct(K, V) {
    it: DictIterator(K, V)
}

// An iterator is its own iterable, so adapter chains can consume it.
pub fn iter(self: &ValuesIter($K, $V)) ValuesIter(K, V) {
    return self.*
}

// Advances and returns the next value, or null after the last.
pub fn next(self: &ValuesIter($K, $V)) V? {
    let e = self.it.next()
    if e.is_none() {
        return null
    }
    return Some(e.unwrap().value)
}

// Iterates the values, in unspecified order.
pub fn values(self: &UnmanagedDict($K, $V)) ValuesIter(K, V) {
    return .{ it = self.iter() }
}

// =============================================================================
// UnmanagedDict: derived dicts, allocator explicit
//
// Callbacks are duck-typed `$F` (RFC-014) and take `(key, value)`. Entries are copied shallowly,
// the same convention as List's transformations.
// =============================================================================

// Returns a new dict with the same keys and `f(key, value)` as each value. Keys are copied bitwise;
// an owned key is then owned by both dicts, and only one may deinit it.
pub fn map_values(self: &UnmanagedDict($K, $V), f: $F, allocator: &Allocator) UnmanagedDict(K, $U) {
    let out: UnmanagedDict(K, U)
    for e in self.iter() {
        out.set(e.key, f(e.key, e.value), allocator)
    }
    return move out
}

// Returns a new dict of the entries `pred(key, value)` accepts. Keys and values are copied bitwise;
// an owned key or value is then owned by both dicts, and only one may deinit it.
pub fn filter(self: &UnmanagedDict($K, $V), pred: $F, allocator: &Allocator) UnmanagedDict(K, V) {
    let out: UnmanagedDict(K, V)
    for e in self.iter() {
        if pred(e.key, e.value) {
            out.set(e.key, e.value, allocator)
        }
    }
    return move out
}

// =============================================================================
// The managed API: `Dict` and `DictRef`
//
// The same operations over the carrier's own allocator, forwarded to the unmanaged function by a
// generator, as `List`'s are (list.f): a managed carrier is any type with a `__storage` reaching an
// `UnmanagedDict(K, V)` and an `allocator` beside it. A derived dict takes an optional allocator
// for its result and otherwise uses the receiver's, and is a `Dict` either way. `deinit` is
// `Dict`'s alone.
// =============================================================================

#define(managed_dict, Self: Ident) {
    // Insert or update a key-value pair. Panics when the allocation fails.
    pub fn set(self: &#(Self)($K, $V), key: K, value: V) {
        self.__storage.set(move key, move value, self.allocator)
    }

    // String-key insert for a `(OwnedString, V)` carrier: `key` is a borrowed view, copied into an
    // owned key only when it is new to the table.
    pub fn set(self: &#(Self)(OwnedString, $V), key: String, value: V) {
        self.__storage.set(move key, move value, self.allocator)
    }

    // `d[key] = value`: insert or update. Panics when the allocation fails.
    pub fn op_set_index(self: &#(Self)($K, $V), key: K, value: V) {
        self.__storage.set(move key, move value, self.allocator)
    }

    // Inserts `key` with `value` unless the key is present, and returns whether it was inserted. A
    // present key keeps its entry, and `key` and `value` stay the caller's.
    pub fn add(self: &#(Self)($K, $V), key: K, value: V) bool {
        return self.__storage.add(move key, move value, self.allocator)
    }

    // String-key `add` for a `(OwnedString, V)` carrier: `key` is copied into an owned key only
    // when it is inserted.
    pub fn add(self: &#(Self)(OwnedString, $V), key: String, value: V) bool {
        return self.__storage.add(move key, move value, self.allocator)
    }

    // Removes `key` and returns its value, or null when absent. The stored key is deinited; the
    // value is the caller's to deinit.
    pub fn remove(self: &#(Self)($K, $V), key: K) V? {
        return self.__storage.remove(move key, self.allocator)
    }

    // String-key `remove` for an `OwnedString`-keyed table.
    pub fn remove(self: &#(Self)(OwnedString, $V), key: String) V? {
        return self.__storage.remove(key, self.allocator)
    }

    // Removes every entry, deiniting each key and value. The table is kept for reuse.
    pub fn clear(self: &#(Self)($K, $V)) {
        self.__storage.clear(self.allocator)
    }

    // Returns a reference to the value for `key`, inserting `make()` under it first when the key is
    // absent. `make` runs only on a miss. The reference is valid until the next insert.
    pub fn get_or_insert_with(self: &#(Self)($K, $V), key: K, make: $F) &V {
        return self.__storage.get_or_insert_with(move key, make, self.allocator)
    }

    // Copies every entry of `other` into this dict, overwriting the value under a key both have.
    // Entries are copied bitwise: an owned key or value is then owned by both dicts, and only one
    // may deinit it.
    pub fn merge(self: &#(Self)($K, $V), other: &#(Self)(K, V)) {
        self.__storage.merge(other.op_deref(), self.allocator)
    }

    // Returns a new dict with the same keys and `f(key, value)` as each value; keys are copied
    // bitwise. The result is on `allocator`, or on the receiver's when null.
    pub fn map_values(self: &#(Self)($K, $V), f: $F, allocator: &Allocator? = null) Dict(K, $U) {
        const alloc = allocator ?? self.allocator
        return .{ __storage = self.__storage.map_values(f, alloc), allocator = alloc }
    }

    // Returns a new dict of the entries `pred(key, value)` accepts, copied bitwise. The result is
    // on `allocator`, or on the receiver's when null.
    pub fn filter(self: &#(Self)($K, $V), pred: $F, allocator: &Allocator? = null) Dict(K, V) {
        const alloc = allocator ?? self.allocator
        return .{ __storage = self.__storage.filter(pred, alloc), allocator = alloc }
    }
}

#managed_dict(Dict)
#managed_dict(DictRef)

// Returns a deep copy: copyable keys and values are copied bitwise, the others through their own
// `clone`.
//
// - `allocator`: kept for the copy's whole life.
pub fn clone(self: &Dict($K, $V), allocator: &Allocator) Dict(K, V) {
    return .{ __storage = self.__storage.clone(allocator), allocator = allocator }
}

// A deep copy on the receiver's allocator.
pub fn clone(self: &Dict($K, $V)) Dict(K, V) {
    return self.clone(self.allocator)
}

// Deinits every live key and value and frees the table. Idempotent: a second call is a no-op.
pub fn deinit(self: &Dict($K, $V)) {
    self.__storage.deinit(self.allocator)
}

// Element form (README, Expected functions). The value carries its own allocator.
pub fn deinit(self: &Dict($K, $V), allocator: &Allocator) {
    self.deinit()
}

// =============================================================================
// Tests
// =============================================================================

test "an UnmanagedDict takes its allocator at every allocating call" {
    let counting = counting_allocator(global())
    const alloc = counting.allocator()
    let d: UnmanagedDict(u32, i32) = unmanaged_dict(0, &alloc)
    d.set(1u32, 10i32, &alloc)
    d.set(2u32, 20i32, &alloc)
    d.set(1u32, 11i32, &alloc)
    assert_eq(d.len(), 2 as usize, "an update does not add an entry")
    assert_eq(d.get(1u32).unwrap(), 11i32, "the update took")
    assert_true(d.contains(2u32), "contains")
    assert_eq(d.remove(2u32, &alloc).unwrap(), 20i32, "remove hands back the value")
    let sum = 0i32
    for e in d {
        sum = sum + e.value
    }
    assert_eq(sum, 11i32, "for over the live entries")
    const doubled = d.map_values(fn(k, v) { v * 2 }, &alloc)
    assert_eq(doubled.get(1u32).unwrap(), 22i32, "derived dict with explicit allocator")
    doubled.deinit(&alloc)
    d.deinit(&alloc)
    assert_eq(counting.live_bytes, 0 as usize, "everything went back through that allocator")
}

test "add reports a new key and get_or_insert_with hands back the slot" {
    let d: Dict(u32, i32) = dict()
    defer d.deinit()
    let first = d.get_or_insert_with(1u32, fn() { 10i32 })
    first.* = first.* + 1
    let again = d.get_or_insert_with(1u32, fn() { 99i32 })
    assert_eq(again.*, 11i32, "the second call found the first slot, not the fallback")
    assert_eq(d.len(), 1 as usize, "one key")

    let seen: Dict(u32, u8) = dict()
    defer seen.deinit()
    assert_true(seen.add(1u32, 1u8), "the first insert is new")
    assert_true(!seen.add(1u32, 2u8), "the second is not")
    assert_eq(seen.get(1u32).unwrap(), 1u8, "and leaves the value alone")
}

test "a DictRef grows the table it wraps" {
    let field: UnmanagedDict(u32, i32)
    let h = field.managed(global())
    h[1u32] = 10i32
    h.set(2u32, 20i32)
    assert_eq(field.len(), 2 as usize, "inserts landed in the field")
    assert_eq(h.get(2u32).unwrap(), 20i32, "reads through the handle")
    assert_true(h.add(3u32, 30i32), "add through the handle")
    field.deinit(global())
}

test "a zero-initialised Dict is a valid empty dict" {
    let d: Dict(u32, u32)
    defer d.deinit()
    assert_true(d.is_empty(), "empty")
    assert_true(d.get(1u32).is_none(), "a lookup finds nothing")
    d.set(1u32, 2u32)
    assert_eq(d[1u32].unwrap(), 2u32, "and it grows on the first set")
}

test "a capacity constructor preallocates a power-of-two table" {
    let d: Dict(u32, u32) = dict(100)
    defer d.deinit()
    assert_eq(d.cap, 128 as usize, "rounded up to the next power of two")
    for i in 0..64usize {
        d.set(i as u32, i as u32)
    }
    assert_eq(d.cap, 128 as usize, "no growth below the load factor")
    assert_eq(d.len(), 64 as usize, "every entry present")

    let e: Dict(u32, u32) = dict(32768)
    defer e.deinit()
    assert_eq(e.cap, 32768 as usize, "an exact power of two is kept")

    let z: Dict(u32, u32) = dict(0)
    defer z.deinit()
    assert_eq(z.cap, 0 as usize, "zero stays the lazy empty form")
}

test "a key whose hash is a reserved state still round-trips" {
    // mix64(0) is 0, so the key 0u32 naturally hashes to EMPTY's reserved value - `hash_key` must
    // remap it or the entry reads as a hole.
    let d: Dict(u32, i32) = dict()
    defer d.deinit()
    d.set(0u32, 7i32)
    d.set(9u32, 9i32)
    assert_eq(d.get(0u32).unwrap(), 7i32, "the remapped key reads back")
    assert_true(d.contains(0u32), "and is visible to contains")
    assert_eq(d.remove(0u32).unwrap(), 7i32, "and removes")
    assert_true(!d.contains(0u32), "gone after removal")
    d.set(0u32, 8i32)
    assert_eq(d.get(0u32).unwrap(), 8i32, "reinserts through the tombstone")
    assert_eq(d.len(), 2 as usize, "the other entry is untouched")
}

test "delete-heavy churn never fills the table" {
    let d: Dict(u32, u32) = dict()
    defer d.deinit()
    for i in 0..64usize {
        d.set(i as u32, 1u32)
        let _r = d.remove(i as u32)
    }
    d.set(7u32, 2u32)
    assert_eq(d.len(), 1 as usize, "one live entry after churn")
    assert_eq(d.get(7u32).unwrap(), 2u32, "the surviving entry reads back")
    assert_eq(d.cap, 8 as usize, "tombstone rehashes keep the capacity")
}

test "string keys are copied on insert and looked up by view" {
    // Block counts, not bytes: an OwnedString frees `len` of the `len + 1` it allocated, so a
    // counting allocator's `live_bytes` is inexact with string keys.
    let counting = counting_allocator(global())
    const alloc = counting.allocator()
    let d: Dict(OwnedString, i32) = dict(0, &alloc)
    d.set("one", 1i32)
    d.set("two", 2i32)
    d.set("one", 10i32)
    assert_eq(d.len(), 2 as usize, "an update by view does not add an entry")
    assert_eq(d.get("one").unwrap(), 10i32, "the update took")
    assert_true(d.contains("two"), "contains by view")
    assert_eq(d.remove("two").unwrap(), 2i32, "remove by view")
    assert_true(!d.contains("two"), "gone")
    d.deinit()
    assert_eq(counting.allocs, 3 as usize, "two keys and one table")
    assert_eq(counting.deallocs, counting.allocs,
        "keys and table freed through the dict's allocator")
}

test "keys and values iterate the live entries" {
    // std.iter (to_list etc.) can't be imported here - see the harness test stdlib_dict_iter_chain
    // for combinator chains over keys()/values().
    let d: Dict(u32, i32) = dict()
    defer d.deinit()
    d.set(1u32, 10i32)
    d.set(2u32, 20i32)

    let key_sum = 0u32
    for k in d.keys() {
        key_sum = key_sum + k
    }
    assert_eq(key_sum, 3u32, "both keys visited")

    let value_sum = 0i32
    for v in d.values() {
        value_sum = value_sum + v
    }
    assert_eq(value_sum, 30i32, "both values visited")
}

test "map_values filter each any all count" {
    let d: Dict(u32, i32) = dict()
    defer d.deinit()
    d.set(1u32, 1i32)
    d.set(2u32, 2i32)
    d.set(3u32, 3i32)

    let scale = 10i32
    let scaled = d.map_values(fn(k, v) { v * scale })
    defer scaled.deinit()
    assert_eq(scaled.get(2u32).unwrap(), 20i32, "value mapped, key kept")
    assert_eq(scaled.len(), 3 as usize, "same entry count")

    let evens = d.filter(fn(k, v) { v % 2 == 0 })
    defer evens.deinit()
    assert_eq(evens.len(), 1 as usize, "one even value")
    assert_eq(evens.get(2u32).unwrap(), 2i32, "the right entry survived")

    let sum = 0i32
    let sum_ref = &sum
    d.each(fn(k, v) { sum_ref.* = sum_ref.* + v })
    assert_eq(sum, 6i32, "each visited every entry")

    assert_true(d.any(fn(k, v) { v > 2 }), "one value exceeds 2")
    assert_true(!d.all(fn(k, v) { v > 2 }), "not all do")
    assert_eq(d.count(fn(k, v) { v > 1 }), 2 as usize, "two values exceed 1")
}

test "get_or update merge" {
    let d: Dict(u32, i32) = dict()
    defer d.deinit()
    d.set(1u32, 5i32)

    assert_eq(d.get_or(1u32, 0i32), 5i32, "present key reads its value")
    assert_eq(d.get_or(9u32, -1i32), -1i32, "absent key reads the fallback")
    assert_eq(d.get_or_else(1u32, fn() { 0i32 }), 5i32, "present key skips the fallback fn")
    let expensive = 42i32
    assert_eq(d.get_or_else(9u32, fn() { expensive }), 42i32, "absent key computes it")

    assert_true(d.update(1u32, fn(v) { v.* = v.* + 1i32 }), "update hits the key")
    assert_eq(d.get(1u32).unwrap(), 6i32, "mutated in place")
    assert_true(!d.update(9u32, fn(v) { v.* = 0i32 }), "absent key reports false")

    let other: Dict(u32, i32) = dict()
    defer other.deinit()
    other.set(1u32, 100i32)
    other.set(2u32, 200i32)
    d.merge(&other)
    assert_eq(d.len(), 2 as usize, "merged entry added")
    assert_eq(d.get(1u32).unwrap(), 100i32, "collision overwritten by other")
}
