// Growable bit vector. One bit per element, packed into 64-bit words.
//
// Use for dense integer-indexed sets: liveness, reachability,
// optimization-pass change tracking, variant-tag presence. The API
// mirrors `Set(usize)` — `add` / `remove` / `contains` / `iter` — so a
// caller can switch between the two when density assumptions change.
//
// `union` / `intersect` are O(words/64) per call, the killer feature
// over `Set(usize)` for tight optimisation loops.

import core.bits
import std.allocator
import std.list
import std.option

pub type Bitset = struct {
    words: List(u64)
}

const BITS_PER_WORD: usize = 64

// Construct an empty bitset. `initial_bits` reserves storage for that
// many bits (rounded up to the next word boundary). Pass 0 to defer
// allocation to the first `add`.
pub fn bitset(initial_bits: usize, allocator: &Allocator? = null) Bitset {
    const word_cap = (initial_bits + BITS_PER_WORD - 1) / BITS_PER_WORD
    return .{ words = list(word_cap, allocator) }
}

// Free the backing storage. The bitset should not be used after this.
pub fn deinit(self: &Bitset) {
    self.words.deinit()
}

// Number of bits currently set. O(words).
pub fn len(self: Bitset) usize {
    let total: usize = 0
    for w in self.words {
        total = total + count_ones_u64(w) as usize
    }
    return total
}

// True when no bits are set. O(words) in the worst case (must walk the
// whole list to confirm).
pub fn is_empty(self: Bitset) bool {
    for w in self.words {
        if w != 0u64 { return false }
    }
    return true
}

// Grow the underlying word list to cover `word_count` words. New words
// are zero-initialised.
fn ensure_words(self: &Bitset, word_count: usize) {
    while self.words.len < word_count {
        self.words.push(0u64)
    }
}

// Set bit `i`. Grows the underlying storage when `i` exceeds capacity.
pub fn add(self: &Bitset, i: usize) {
    const word_idx = i / BITS_PER_WORD
    const bit_idx = i % BITS_PER_WORD
    self.ensure_words(word_idx + 1)
    const mask: u64 = 1u64 << (bit_idx as u64)
    self.words[word_idx] = self.words[word_idx] | mask
}

// Test bit `i`. Indices past the current storage are treated as unset.
pub fn contains(self: Bitset, i: usize) bool {
    const word_idx = i / BITS_PER_WORD
    if word_idx >= self.words.len { return false }
    const bit_idx = i % BITS_PER_WORD
    const mask: u64 = 1u64 << (bit_idx as u64)
    return (self.words[word_idx] & mask) != 0u64
}

// Clear bit `i`. Returns `true` iff the bit was set. Never grows.
pub fn remove(self: &Bitset, i: usize) bool {
    const word_idx = i / BITS_PER_WORD
    if word_idx >= self.words.len { return false }
    const bit_idx = i % BITS_PER_WORD
    const mask: u64 = 1u64 << (bit_idx as u64)
    const was_set = (self.words[word_idx] & mask) != 0u64
    self.words[word_idx] = self.words[word_idx] & ~mask
    return was_set
}

// Clear every bit. Backing storage is retained for reuse.
pub fn clear(self: &Bitset) {
    for i in 0..self.words.len {
        self.words[i] = 0u64
    }
}

// In-place union: self |= other. Grows self when `other` is longer.
pub fn union(self: &Bitset, other: Bitset) {
    self.ensure_words(other.words.len)
    for i in 0..other.words.len {
        self.words[i] = self.words[i] | other.words[i]
    }
}

// In-place intersection: self &= other. Words beyond `other`'s length
// become zero (since `other` has no bits there). Storage is retained.
pub fn intersect(self: &Bitset, other: Bitset) {
    const common = if self.words.len < other.words.len { self.words.len } else { other.words.len }
    for i in 0..common {
        self.words[i] = self.words[i] & other.words[i]
    }
    for i in common..self.words.len {
        self.words[i] = 0u64
    }
}

// In-place difference: self &= ~other. Bits set in `other` are cleared
// from `self`. Never grows.
pub fn difference(self: &Bitset, other: Bitset) {
    const common = if self.words.len < other.words.len { self.words.len } else { other.words.len }
    for i in 0..common {
        self.words[i] = self.words[i] & ~other.words[i]
    }
}

// =============================================================================
// Iterator — yields indices of set bits in ascending order.
// Skips entire zero words via `trailing_zeros_u64` so sparse bitsets are
// O(set bits) rather than O(capacity).
// =============================================================================

pub type BitsetIterator = struct {
    bitset: &Bitset
    word_idx: usize
    word_residual: u64   // current word with already-yielded bits cleared
}

pub fn iter(self: &Bitset) BitsetIterator {
    return .{ bitset = self, word_idx = 0, word_residual = 0u64 }
}

pub fn next(it: &BitsetIterator) usize? {
    while it.word_residual == 0u64 {
        if it.word_idx >= it.bitset.words.len { return null }
        it.word_residual = it.bitset.words[it.word_idx]
        if it.word_residual == 0u64 {
            it.word_idx = it.word_idx + 1
        }
    }
    const bit = trailing_zeros_u64(it.word_residual) as usize
    const result = it.word_idx * BITS_PER_WORD + bit
    // Clear the bit we just yielded.
    it.word_residual = it.word_residual & (it.word_residual - 1u64)
    if it.word_residual == 0u64 {
        it.word_idx = it.word_idx + 1
    }
    return result
}
