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
// A table is all-empty once every hash reads 0 (`mark_empty`).

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

// Deinits the key and the value. Call it only on a live entry, one whose `hash` is at least 2.
pub fn deinit(self: move Entry($K, $V)) {
    release(self.key)
    release(self.value)
}

// A hash map from `K` to `V` that carries no allocator: every operation that grows or frees the
// table takes one as its last argument, and the same allocator must be passed every time. A
// zero-initialised value is a valid empty dict. Keys and values are owned: `deinit` deinits each
// before freeing the table.
pub type UnmanagedDict = struct(K: Hash + Eq, V) {
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
pub type Dict = struct(K: Hash + Eq, V) {
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
pub type DictRef = struct(K: Hash + Eq, V) {
    __storage: &UnmanagedDict(K, V)
    allocator: &Allocator
}

// Returns the `Dict` API over `d`, growing it through `allocator`. `d` must outlive the handle and
// keep allocating through the same allocator.
pub fn managed(d: &UnmanagedDict($K, $V), allocator: &Allocator) DictRef(K, V) {
    return .{ __storage = d, allocator = allocator }
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
    return out
}

// Construct an empty Dict. Storage is allocated lazily on the first `set` / `op_set_index`. `K` and
// `V` are inferred from the call's expected type (e.g. `let d: Dict(String, i32) = dict()`).
pub fn dict(allocator: &Allocator = context.allocator) Dict($K, $V) {
    let empty: UnmanagedDict(K, V)
    return .{ __storage = move empty, allocator = allocator }
}

// Construct a Dict whose table starts at `capacity` slots, rounded up as `unmanaged_dict` does.
// `dict(0)` is the lazy empty form.
//
// - `allocator`: kept for the dict's whole life. Null is the global allocator.
pub fn dict(capacity: usize, allocator: &Allocator = context.allocator) Dict($K, $V) {
    const alloc = allocator
    return .{ __storage = unmanaged_dict(capacity, alloc), allocator = alloc }
}

// The smallest power of two at or above `v`, floored at 8 - every capacity branch must yield one,
// or `probe_slot`'s mask breaks.
fn next_pow2_min8(v: usize) usize {
    let n: usize = 8
    while n < v { n = n * 2 }
    return n
}

// Install a table of `cap` empty slots. `cap` must be a power of two.
fn alloc_table(self: &UnmanagedDict($K, $V), cap: usize, allocator: &Allocator) {
    const alloc_size: usize = cap * size_of(Entry(K, V))
    const raw: u8[] = allocator.alloc(alloc_size, 8).expect("dict: allocation failed")
    self.entries = raw.ptr as &Entry(K, V)
    self.cap = cap
    mark_empty(self)
}

// Every slot empty: an empty slot is its hash alone, and its key and value bytes are never read.
fn mark_empty(self: &UnmanagedDict($K, $V)) {
    for i in 0..self.cap {
        (self.entries + i).hash = HASH_EMPTY
    }
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
fn hash_key(key: $K) usize where K: Hash {
    const h = key.hash()
    if h < 2 {
        return h + 2
    }
    return h
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

    // A rehash that mostly clears tombstones keeps its capacity; only live-entry pressure grows the
    // table. Every branch here must yield a power of two - `probe_slot` masks instead of dividing.
    let new_cap: usize = 8
    if self.cap > 0 {
        new_cap = if self.length * 2 <= self.cap { self.cap } else { self.cap * 2 }
    }

    // The entries leave through `self.entries`, the storage this module owns, into a fresh table
    // that then takes the old one's place.
    let next: UnmanagedDict(K, V)
    next.alloc_table(new_cap, allocator)
    for i in 0..self.cap {
        const h = (self.entries + i).hash
        if h >= 2 {
            const slot = next.claim_slot(h)
            slot.key = move (self.entries + i).key
            slot.value = move (self.entries + i).value
        }
    }
    swap(self, &next)
    // The old buffer is freed without deinit: every live entry was handed over above.
    if next.cap > 0 {
        allocator.free(slice_from_raw_parts(next.entries, next.cap))
    }
}

// Store a key known to be absent in the first tombstone or empty slot on its probe sequence. The
// table must have room (`ensure_capacity`).
fn place(self: &UnmanagedDict($K, $V), h: usize, key: move K, value: move V) &Entry(K, V) {
    const entry = self.claim_slot(h)
    entry.key = move key
    entry.value = move value
    return entry
}

// Claims the first tombstone or empty slot on `h`'s probe sequence for a key known to be absent:
// the slot is counted and hashed, and its key and value are the caller's to store.
fn claim_slot(self: &UnmanagedDict($K, $V), h: usize) &Entry(K, V) {
    for i in 0..self.cap {
        const entry: &Entry(K, V) = self.entries + probe_slot(h, i, self.cap)
        if entry.hash == HASH_EMPTY or entry.hash == HASH_DEAD {
            if entry.hash == HASH_DEAD {
                self.dead = self.dead - 1
            }
            entry.hash = h
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
pub fn add(self: &UnmanagedDict($K, $V), key: move K, value: move V, allocator: &Allocator) bool {
    if self.find_entry(key).is_some() {
        return false
    }
    self.ensure_capacity(allocator)
    const _e = self.place(hash_key(key), key, value)
    return true
}

// String-key `add` for `UnmanagedDict(OwnedString, V)`: `key` is a borrowed view, copied into an
// owned key only when it is inserted.
pub fn add(
    self: &UnmanagedDict(OwnedString, $V),
    key: String,
    value: move V,
    allocator: &Allocator,
) bool {
    if self.find_entry(key).is_some() {
        return false
    }
    self.ensure_capacity(allocator)
    const _e = self.place(hash_key(key), from_view(key, allocator), value)
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
pub fn get_or_insert_with(
    self: &UnmanagedDict($K, $V),
    key: move K,
    make: fn() V,
    allocator: &Allocator,
) &V {
    const found = self.find_entry(key)
    if found.is_some() {
        const entry = found.unwrap()
        return &entry.value
    }
    self.ensure_capacity(allocator)
    const placed = self.place(hash_key(key), key, make())
    return &placed.value
}

// Insert or update a key-value pair. On an update the old value is deinited, and so is `key`, since
// the entry keeps the one it already has. Panics when the allocation fails.
pub fn set(self: &UnmanagedDict($K, $V), key: move K, value: move V, allocator: &Allocator) {
    const existing = self.find_index(key)
    if existing.is_some() {
        // Written from `self.entries`, not through a lent `&Entry`: taking out of storage this
        // module owns is the scoped-mutability right (E2125).
        const i = existing.unwrap()
        let old = move (self.entries + i).value
        release(old)
        const entry = self.entries + i
        entry.value = move value
        release(key)
        return
    }
    self.ensure_capacity(allocator)
    const _placed = self.place(hash_key(key), key, value)
}

// String-key insert for `UnmanagedDict(OwnedString, V)`: the key is a borrowed view, copied into an
// owned key only when it is new to the table.
pub fn set(self: &UnmanagedDict(OwnedString, $V), key: String, value: move V, allocator: &Allocator) {
    const existing = self.find_index(key)
    if existing.is_some() {
        const i = existing.unwrap()
        let old = move (self.entries + i).value
        release(old)
        const entry = self.entries + i
        entry.value = move value
        return
    }
    self.ensure_capacity(allocator)
    const _placed = self.place(hash_key(key), from_view(key, allocator), value)
}

// Deinits every live key and value, frees the table and resets to empty, so a second call is a
// no-op.
pub fn deinit(self: move UnmanagedDict($K, $V), allocator: &Allocator) {
    if self.cap > 0 {
        self.clear()
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
pub fn merge(self: &UnmanagedDict($K, $V), other: &UnmanagedDict(K, V), allocator: &Allocator)
where K: copyable, V: copyable {
    for e in other.iter() {
        self.set(e.key, e.value, allocator)
    }
}

// =============================================================================
// UnmanagedDict: in-place mutation
// =============================================================================

// Removes `key` and returns its value, or null when absent. The stored key is deinited; the value
// is the caller's to deinit.
pub fn remove(self: &UnmanagedDict($K, $V), key: K) V? {
    return self.take_entry(self.find_index(key))
}

// Removes the entry whose key equals `key`, a probe of another type (a `String` against
// `OwnedString` keys), and returns its value. `key.hash()` and `==` must agree with the key type's.
pub fn remove(self: &UnmanagedDict($K, $V), key: $Q) V? where Q: Hash {
    return self.take_entry(self.find_index(key))
}

// Tombstones the slot at `found`, deinits its key and hands back its value.
fn take_entry(self: &UnmanagedDict($K, $V), found: usize?) V? {
    if found.is_none() {
        return null
    }
    const i = found.unwrap()
    const val: V = move (self.entries + i).value
    let k = move (self.entries + i).key
    release(k)
    const entry = self.entries + i
    entry.hash = HASH_DEAD
    self.length = self.length - 1
    self.dead = self.dead + 1
    return Some(move val)
}

// Removes every entry, deiniting each key and value. The table is kept for reuse.
pub fn clear(self: &UnmanagedDict($K, $V)) {
    for i in 0..self.cap {
        if (self.entries + i).hash >= 2 {
            let entry = move (self.entries + i).*
            entry.deinit()
        }
    }
    mark_empty(self)
    self.length = 0
    self.dead = 0
}

// Mutate the value for `key` in place via `f(&value)`. Returns whether the key was present.
// In-place mutation (not get-modify-set) is the only sound shape for owned values: `set` deinits
// the value it overwrites.
pub fn update(self: &UnmanagedDict($K, $V), key: K, f: fn(&V)) bool {
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
// ends the search. `key` is a `K` or a probe whose `hash` and `==` agree with `K`'s.
fn find_entry(self: &UnmanagedDict($K, $V), key: $Q) &Entry(K, V)? where Q: Hash {
    return self.find_index(key) match {
        Some(i) => Some(self.entries + i)
        None => null
    }
}

// The slot index holding `key`, or null. What a take goes through: the entry is then written as
// `(self.entries + i)`, a place this module owns, rather than through a lent `&Entry`.
fn find_index(self: &UnmanagedDict($K, $V), key: $Q) usize? where Q: Hash {
    if self.cap == 0 {
        return null
    }
    const h: usize = hash_key(key)
    for i in 0..self.cap {
        const slot = probe_slot(h, i, self.cap)
        const entry: &Entry(K, V) = self.entries + slot
        if entry.hash == HASH_EMPTY {
            return null
        }
        // A stored hash is >= 2, so a hash match implies an occupied slot and can never collide
        // with the reserved states.
        if entry.hash == h {
            if entry.key == key {
                return Some(slot)
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
pub fn op_index(self: &UnmanagedDict($K, $V), key: K) V? where V: copyable {
    return self.get(key)
}

// Returns the value for `key`, or null when absent.
pub fn get(self: &UnmanagedDict($K, $V), key: K) V? where V: copyable {
    return Some((self.get_ref(key)?).*)
}

// Returns a reference to the value for `key`, or null when absent. Valid until the next insert,
// which may move the table.
pub fn get_ref(self: &UnmanagedDict($K, $V), key: K) &V? {
    const found = self.find_entry(key)
    if found.is_none() {
        return null
    }
    const entry = found.unwrap()
    return Some(&entry.value)
}

// `get` by a probe of another type (a `String` against `OwnedString` keys). `key.hash()` and `==`
// must agree with the key type's.
pub fn get(self: &UnmanagedDict($K, $V), key: $Q) V? where V: copyable, Q: Hash {
    return Some((self.get_ref(key)?).*)
}

// `get_ref` by a probe of another type (a `String` against `OwnedString` keys). `key.hash()` and
// `==` must agree with the key type's.
pub fn get_ref(self: &UnmanagedDict($K, $V), key: $Q) &V? where Q: Hash {
    const found = self.find_entry(key)
    if found.is_none() {
        return null
    }
    const entry = found.unwrap()
    return Some(&entry.value)
}

// Returns whether `key` is present.
pub fn contains(self: &UnmanagedDict($K, $V), key: K) bool {
    return self.find_entry(key).is_some()
}

// `contains` by a probe of another type (a `String` against `OwnedString` keys). `key.hash()` and
// `==` must agree with the key type's.
pub fn contains(self: &UnmanagedDict($K, $V), key: $Q) bool where Q: Hash {
    return self.find_entry(key).is_some()
}

// The value for `key`, or `fallback` when absent.
pub fn get_or(self: &UnmanagedDict($K, $V), key: K, fallback: move V) V where V: copyable {
    let v = self.get(key)
    if v.is_some() {
        return v.unwrap()
    }
    return fallback
}

// The value for `key`, or `make()` when absent - the lazy counterpart of `get_or`, for fallbacks
// that are expensive (or effectful) to build.
pub fn get_or_else(self: &UnmanagedDict($K, $V), key: K, make: fn() V) V where V: copyable {
    let v = self.get(key)
    if v.is_some() {
        return v.unwrap()
    }
    return make()
}

// Calls `f(key, value)` on every entry, in unspecified order.
pub fn each(self: &UnmanagedDict($K, $V), f: fn(K, V)) {
    for e in self.iter() {
        f(e.key, e.value)
    }
}

// Returns whether any entry satisfies `pred(key, value)`. False when empty.
pub fn any(self: &UnmanagedDict($K, $V), pred: fn(K, V) bool) bool {
    for e in self.iter() {
        if pred(e.key, e.value) {
            return true
        }
    }
    return false
}

// Returns whether every entry satisfies `pred(key, value)`. True when empty.
pub fn all(self: &UnmanagedDict($K, $V), pred: fn(K, V) bool) bool {
    for e in self.iter() {
        let ok: bool = pred(e.key, e.value)
        if !ok {
            return false
        }
    }
    return true
}

// Returns how many entries satisfy `pred(key, value)`.
pub fn count(self: &UnmanagedDict($K, $V), pred: fn(K, V) bool) usize {
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

// Iterator over a dict's entries, each entry lent in table order. A snapshot: the dict is not
// modified while it is being iterated.
pub type DictIterator = struct(K, V) {
    dict: &UnmanagedDict(K, V)
    current: usize
}

// Iterates the live entries, in unspecified order.
pub fn iter(dict: &UnmanagedDict($K, $V)) DictIterator(K, V) {
    return .{ dict = dict, current = 0 }
}

// An iterator is its own iterable, so `for e in d.iter()` and the std.iter combinators can consume
// it.
pub fn iter(it: &DictIterator($K, $V)) DictIterator(K, V) {
    return it.*
}

// Advances and returns the next entry, or null after the last. The entry is lent, not copied: a
// dict may hold owned keys and values, and a copy of one would own them twice.
pub fn next(it: &DictIterator($K, $V)) &Entry(K, V)? {
    for idx in it.current..it.dict.cap {
        const entry: &Entry(K, V) = it.dict.entries + idx
        if entry.hash >= 2 {
            it.current = idx + 1
            // Wrapped explicitly - see the note in core/range.f::next.
            return Some(entry)
        }
    }
    it.current = it.dict.cap
    return null
}

// Hands every entry over, one at a time, emptying the dict as it goes. The table itself is kept and
// still has to be freed (`deinit`); a drain that stops early leaves the untaken entries in place.
pub type DictDrain = struct(K, V) {
    __dict: &UnmanagedDict(K, V)
    current: usize
    taken: usize
    count: usize
    // A copy would hand the entries out twice.
    __unique: NoCopy
}

// Starts a drain. The dict reads as empty while it runs; `deinit` puts back what was not taken.
pub fn drain(self: &UnmanagedDict($K, $V)) DictDrain(K, V) {
    let out: DictDrain(
        K,
        V,
    ) = .{ __dict = self, current = 0, taken = 0, count = self.length, __unique = no_copy() }
    self.length = 0
    return out
}

// A drain is its own iterable: `for (k, v) in d.drain()`.
pub fn iter(self: move DictDrain($K, $V)) DictDrain(K, V) {
    return self
}

// Moves the next key and value out of the dict, in table order, or null when every entry has been
// taken. The slot it came from is left as a tombstone.
pub fn next(self: &DictDrain($K, $V)) (K, V)? {
    for idx in self.current..self.__dict.cap {
        const entry: &Entry(K, V) = self.__dict.entries + idx
        if entry.hash >= 2 {
            self.current = idx + 1
            self.taken = self.taken + 1
            entry.hash = HASH_DEAD
            const k = move (self.__dict.entries + idx).key
            const v = move (self.__dict.entries + idx).value
            return Some((move k, move v))
        }
    }
    self.current = self.__dict.cap
    return null
}

// Puts the count back: what the drain did not take is still in the table.
pub fn deinit(self: move DictDrain($K, $V)) {
    self.__dict.length = self.count - self.taken
    self.__dict.dead = self.__dict.dead + self.taken
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
pub fn next(self: &KeysIter($K, $V)) K? where K: copyable {
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
pub fn next(self: &ValuesIter($K, $V)) V? where V: copyable {
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
// Callbacks are `fn(K, V) ...` values (RFC-037) and take `(key, value)`. Entries are copied
// shallowly, the same convention as List's transformations.
// =============================================================================

// Returns a new dict with the same keys and `f(key, value)` as each value. Keys are copied bitwise;
// an owned key is then owned by both dicts, and only one may deinit it.
pub fn map_values(
    self: &UnmanagedDict($K, $V),
    f: fn(K, V) $U,
    allocator: &Allocator,
) UnmanagedDict(K, U)
where K: copyable {
    let out: UnmanagedDict(K, U)
    for e in self.iter() {
        out.set(e.key, f(e.key, e.value), allocator)
    }
    return out
}

// Returns a new dict of the entries `pred(key, value)` accepts. Keys and values are copied bitwise;
// an owned key or value is then owned by both dicts, and only one may deinit it.
pub fn filter(
    self: &UnmanagedDict($K, $V),
    pred: fn(K, V) bool,
    allocator: &Allocator,
) UnmanagedDict(K, V)
where K: copyable, V: copyable {
    let out: UnmanagedDict(K, V)
    for e in self.iter() {
        if pred(e.key, e.value) {
            out.set(e.key, e.value, allocator)
        }
    }
    return out
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

#define(managed_dict, Name: Ident) {
    // Insert or update a key-value pair. Panics when the allocation fails.
    pub fn set(self: &#(Name)($K, $V), key: move K, value: move V) {
        self.__storage.set(key, value, self.allocator)
    }

    // String-key insert for a `(OwnedString, V)` carrier: `key` is a borrowed view, copied into an
    // owned key only when it is new to the table.
    pub fn set(self: &#(Name)(OwnedString, $V), key: String, value: move V) {
        self.__storage.set(key, value, self.allocator)
    }

    // `d[key] = value`: insert or update. Panics when the allocation fails.
    pub fn op_set_index(self: &#(Name)($K, $V), key: move K, value: move V) {
        self.__storage.set(key, value, self.allocator)
    }

    // Inserts `key` with `value` unless the key is present, and returns whether it was inserted. A
    // present key keeps its entry, and `key` and `value` stay the caller's.
    pub fn add(self: &#(Name)($K, $V), key: move K, value: move V) bool {
        return self.__storage.add(key, value, self.allocator)
    }

    // String-key `add` for a `(OwnedString, V)` carrier: `key` is copied into an owned key only
    // when it is inserted.
    pub fn add(self: &#(Name)(OwnedString, $V), key: String, value: move V) bool {
        return self.__storage.add(key, value, self.allocator)
    }

    // Returns a reference to the value for `key`, inserting `make()` under it first when the key is
    // absent. `make` runs only on a miss. The reference is valid until the next insert.
    pub fn get_or_insert_with(self: &#(Name)($K, $V), key: move K, make: fn() V) &V {
        return self.__storage.get_or_insert_with(key, make, self.allocator)
    }

    // Copies every entry of `other` into this dict, overwriting the value under a key both have.
    // Entries are copied bitwise: an owned key or value is then owned by both dicts, and only one
    // may deinit it.
    pub fn merge(self: &#(Name)($K, $V), other: &#(Name)(K, V)) where K: copyable, V: copyable {
        self.__storage.merge(other.op_deref(), self.allocator)
    }

    // Returns a new dict with the same keys and `f(key, value)` as each value; keys are copied
    // bitwise. The result is on `allocator`, or on the receiver's when null.
    pub fn map_values(self: &#(Name)($K, $V), f: fn(K, V) $U, allocator: &Allocator? = null) Dict(K, U) where K: copyable {
        const alloc = allocator ?? self.allocator
        return .{ __storage = self.__storage.map_values(f, alloc), allocator = alloc }
    }

    // Returns a new dict of the entries `pred(key, value)` accepts, copied bitwise. The result is
    // on `allocator`, or on the receiver's when null.
    pub fn filter(self: &#(Name)($K, $V), pred: fn(K, V) bool, allocator: &Allocator? = null) Dict(K, V) where K: copyable, V: copyable {
        const alloc = allocator ?? self.allocator
        return .{ __storage = self.__storage.filter(pred, alloc), allocator = alloc }
    }
}

#managed_dict(Dict)
#managed_dict(DictRef)

// Deinits every live key and value and frees the table. Idempotent: a second call is a no-op.
pub fn deinit(self: move Dict($K, $V)) {
    self.__storage.deinit(self.allocator)
}

// =============================================================================
// Tests
// =============================================================================

test "an UnmanagedDict takes its allocator at every allocating call" {
    let counting = counting_allocator(context.allocator)
    const alloc = counting.allocator()
    let d: UnmanagedDict(u32, i32) = unmanaged_dict(0, &alloc)
    d.set(1u32, 10i32, &alloc)
    d.set(2u32, 20i32, &alloc)
    d.set(1u32, 11i32, &alloc)
    assert_eq(d.len(), 2 as usize, "an update does not add an entry")
    assert_eq(d.get(1u32).unwrap(), 11i32, "the update took")
    assert_true(d.contains(2u32), "contains")
    assert_eq(d.remove(2u32).unwrap(), 20i32, "remove hands back the value")
    let sum = 0i32
    for e in d {
        sum = sum + e.value
    }
    assert_eq(sum, 11i32, "for over the live entries")
    const doubled = d.map_values({ k, v => v * 2 }, &alloc)
    assert_eq(doubled.get(1u32).unwrap(), 22i32, "derived dict with explicit allocator")
    doubled.deinit(&alloc)
    d.deinit(&alloc)
    assert_eq(counting.live_bytes, 0 as usize, "everything went back through that allocator")
}

test "add reports a new key and get_or_insert_with hands back the slot" {
    let d: Dict(u32, i32) = dict()
    defer d.deinit()
    let first = d.get_or_insert_with(1u32) { => 10i32 }
    first.* = first.* + 1
    let again = d.get_or_insert_with(1u32) { => 99i32 }
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
    let h = field.managed(context.allocator)
    h[1u32] = 10i32
    h.set(2u32, 20i32)
    assert_eq(field.len(), 2 as usize, "inserts landed in the field")
    assert_eq(h.get(2u32).unwrap(), 20i32, "reads through the handle")
    assert_true(h.add(3u32, 30i32), "add through the handle")
    field.deinit(context.allocator)
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
    let counting = counting_allocator(context.allocator)
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
    assert_eq(
        counting.deallocs,
        counting.allocs,
        "keys and table freed through the dict's allocator",
    )
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
    let scaled = d.map_values { k, v => v * scale }
    defer scaled.deinit()
    assert_eq(scaled.get(2u32).unwrap(), 20i32, "value mapped, key kept")
    assert_eq(scaled.len(), 3 as usize, "same entry count")

    let evens = d.filter { k, v => v % 2 == 0 }
    defer evens.deinit()
    assert_eq(evens.len(), 1 as usize, "one even value")
    assert_eq(evens.get(2u32).unwrap(), 2i32, "the right entry survived")

    let sum = 0i32
    let sum_ref = &sum
    d.each { k, v => sum_ref.* = sum_ref.* + v }
    assert_eq(sum, 6i32, "each visited every entry")

    assert_true(d.any { k, v => v > 2 }, "one value exceeds 2")
    assert_true(!d.all { k, v => v > 2 }, "not all do")
    assert_eq(d.count { k, v => v > 1 }, 2 as usize, "two values exceed 1")
}

test "get_or update merge" {
    let d: Dict(u32, i32) = dict()
    defer d.deinit()
    d.set(1u32, 5i32)

    assert_eq(d.get_or(1u32, 0i32), 5i32, "present key reads its value")
    assert_eq(d.get_or(9u32, -1i32), -1i32, "absent key reads the fallback")
    assert_eq(d.get_or_else(1u32) { => 0i32 }, 5i32, "present key skips the fallback fn")
    let expensive = 42i32
    assert_eq(d.get_or_else(9u32) { => expensive }, 42i32, "absent key computes it")

    assert_true(d.update(1u32) { it.* = it.* + 1i32 }, "update hits the key")
    assert_eq(d.get(1u32).unwrap(), 6i32, "mutated in place")
    assert_true(!d.update(9u32) { it.* = 0i32 }, "absent key reports false")

    let other: Dict(u32, i32) = dict()
    defer other.deinit()
    other.set(1u32, 100i32)
    other.set(2u32, 200i32)
    d.merge(&other)
    assert_eq(d.len(), 2 as usize, "merged entry added")
    assert_eq(d.get(1u32).unwrap(), 100i32, "collision overwritten by other")
}
