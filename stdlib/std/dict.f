// Generic hash map (dictionary) backed by manually managed heap storage.
// Uses open addressing with linear probing for collision resolution.
//
// Probing uses bounded for-in loops over 0..capacity with break,
// which avoids the need for while loops.

import core.mem
import core.panic
import core.runtime

import std.allocator
import std.option

// Entry states: 0 = empty, 1 = occupied, 2 = tombstone

// A single entry in the hash map.
pub struct Entry(K, V) {
    state: u8
    hash: usize
    key: K
    value: V
}

pub struct Dict(K, V) {
    entries: &Entry(K, V)
    length: usize
    cap: usize
    allocator: &Allocator?
}

// Free the backing storage. The dict should not be used after this.
pub fn deinit(self: &Dict($K, $V)) {
    if (self.cap > 0) {
        const bytes: usize = self.cap * self.entry_byte_size()
        const alloc = self.get_allocator()
        alloc.free(slice_from_raw_parts(self.entries as &u8, bytes))
    }

    let zero: usize = 0
    self.entries = zero as &Entry(K, V)
    self.length = 0
    self.cap = 0
}


fn get_allocator(self: Dict($K, $V)) &Allocator {
    return self.allocator ?? &global_allocator
}

// Compute the byte size of a single Entry(K, V) from component sizes.
fn entry_byte_size(self: Dict($K, $V)) usize {
    // Entry layout: state (u8) + padding + hash (usize) + key (K) + value (V)
    return 16 + size_of(K) + size_of(V)
}

// Hash function operating on raw bytes of a key.
// Uses multiplicative hashing (no bitwise ops available in FLang).
fn hash_key(key: &$K) usize {
    const key_size: usize = size_of(K)
    const key_bytes: &u8 = key as &u8
    let hash: usize = 2166136261
    for (i in 0..key_size as isize) {
        const byte: &u8 = key_bytes + (i as usize)
        hash = (hash + (byte.* as usize) + 1) * 16777619
    }
    return hash
}

// Returns the number of key-value pairs in the dict.
pub fn len(self: Dict($K, $V)) usize {
    return self.length
}

// Returns true if the dict is empty.
pub fn is_empty(self: Dict($K, $V)) bool {
    return self.length == 0
}

// Ensure capacity and grow if load factor exceeds 75%.
fn ensure_capacity(self: &Dict($K, $V)) {
    // First allocation or load factor > 75%
    let needs_grow: bool = false
    if (self.cap == 0) {
        needs_grow = true
    }
    if (needs_grow == false) {
        if ((self.length + 1) * 4 > self.cap * 3) {
            needs_grow = true
        }
    }

    if (needs_grow == false) {
        return
    }

    const old_cap: usize = self.cap
    const old_entries: &Entry(K, V) = self.entries
    const new_cap: usize = if (old_cap == 0) 8 else old_cap * 2

    // Allocate new entry array, zero-initialized (all states = empty)
    const esize: usize = self.entry_byte_size()
    const alloc_size: usize = new_cap * esize
    const alloc = self.get_allocator()
    const raw: u8[] = alloc.alloc(alloc_size, 8).expect("dict: allocation failed")
    memset(raw.ptr, 0, alloc_size)

    self.entries = raw.ptr as &Entry(K, V)
    self.cap = new_cap
    self.length = 0

    // Re-insert old entries
    if (old_cap > 0) {
        for (i in 0..old_cap as isize) {
            const old_entry: &Entry(K, V) = old_entries + (i as usize)
            if (old_entry.state == 1) {
                self.set(old_entry.key, old_entry.value)
            }
        }
        const old_bytes: usize = old_cap * esize
        alloc.free(slice_from_raw_parts(old_entries as &u8, old_bytes))
    }
}

// Insert or update a key-value pair.
pub fn set(self: &Dict($K, $V), key: K, value: V) {
    self.ensure_capacity()

    const h: usize = hash_key(&key)
    let tombstone_idx: usize = self.cap  // sentinel: no tombstone found

    for (i in 0..self.cap as isize) {
        const idx: usize = (h + (i as usize)) % self.cap
        const entry: &Entry(K, V) = self.entries + idx

        if (entry.state == 0) {
            // Empty slot: use tombstone slot if we passed one, otherwise this slot
            const target_idx: usize = if (tombstone_idx < self.cap) tombstone_idx else idx
            const target: &Entry(K, V) = self.entries + target_idx
            target.state = 1
            target.hash = h
            target.key = key
            target.value = value
            self.length = self.length + 1
            return
        }

        if (entry.state == 2) {
            // Tombstone: remember first one for potential reuse
            if (tombstone_idx == self.cap) {
                tombstone_idx = idx
            }
            continue
        }

        // Occupied: check if same key
        if (entry.hash == h) {
            if (entry.key == key) {
                entry.value = value
                return
            }
        }
    }

    // Should never reach here if load factor is maintained
    panic("dict: set failed - table full")
}

// Get the value associated with a key, or null if not found.
pub fn get(self: Dict($K, $V), key: K) V? {
    if (self.cap == 0) {
        return null
    }

    const h: usize = hash_key(&key)

    for (i in 0..self.cap as isize) {
        const idx: usize = (h + (i as usize)) % self.cap
        const entry: &Entry(K, V) = self.entries + idx

        if (entry.state == 0) {
            return null
        }

        if (entry.state == 1) {
            if (entry.hash == h) {
                if (entry.key == key) {
                    return entry.value
                }
            }
        }
        // Tombstone (2): continue probing
    }

    return null
}

// Check if a key exists in the dict.
pub fn contains(self: Dict($K, $V), key: K) bool {
    if (self.cap == 0) {
        return false
    }

    const h: usize = hash_key(&key)

    for (i in 0..self.cap as isize) {
        const idx: usize = (h + (i as usize)) % self.cap
        const entry: &Entry(K, V) = self.entries + idx

        if (entry.state == 0) {
            return false
        }

        if (entry.state == 1) {
            if (entry.hash == h) {
                if (entry.key == key) {
                    return true
                }
            }
        }
    }

    return false
}

// Remove a key from the dict. Returns the removed value, or null if not found.
pub fn remove(self: &Dict($K, $V), key: K) V? {
    if (self.cap == 0) {
        return null
    }

    const h: usize = hash_key(&key)

    for (i in 0..self.cap as isize) {
        const idx: usize = (h + (i as usize)) % self.cap
        const entry: &Entry(K, V) = self.entries + idx

        if (entry.state == 0) {
            return null
        }

        if (entry.state == 1) {
            if (entry.hash == h) {
                if (entry.key == key) {
                    const val: V = entry.value
                    entry.state = 2
                    self.length = self.length - 1
                    return val
                }
            }
        }
    }

    return null
}

// Remove all entries from the dict without freeing memory.
pub fn clear(self: &Dict($K, $V)) {
    if (self.cap > 0) {
        const bytes: usize = self.cap * self.entry_byte_size()
        memset(self.entries as &u8, 0, bytes)
    }
    self.length = 0
}

// =============================================================================
// Dict Iterator
// =============================================================================

pub struct DictIterator(K, V) {
    dict: &Dict(K, V)
    current: usize
}

// Create iterator from dict
pub fn iter(dict: &Dict($K, $V)) DictIterator(K, V) {
    return .{ dict = dict, current = 0 }
}

// Advance iterator and return next occupied entry
pub fn next(it: &DictIterator($K, $V)) Entry(K, V)? {
    for (i in it.current as isize..it.dict.cap as isize) {
        const idx: usize = i as usize
        const entry: &Entry(K, V) = it.dict.entries + idx
        if (entry.state == 1) {
            it.current = idx + 1
            return entry.*
        }
    }
    it.current = it.dict.cap
    return null
}
