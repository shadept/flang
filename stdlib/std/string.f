// TODO file doc

import core.string // explicit import for clarity

import std.encoding.utf8
import std.allocator
import std.list
import std.option
import std.string_builder
import std.string_reader

// =============================================================================
// String stdlib functions
// =============================================================================

// **1. String manipulation (HIGH PRIORITY)**
// - `split()`, `trim()`, `find()`, `contains()`, `replace()`
// - `ends_with()` (commented out)
// - Substring search
// - Character classification (`is_digit`, `is_alpha`, `is_whitespace`)
// - String-to-integer parsing (`parse_int`)

// Note on overload ordering: the char-needle overloads are declared BEFORE the
// String-needle ones. Char literals 0-255 currently bind to an unconstrained
// type variable (see HmTypeChecker.Expressions.InferIntegerLiteral) so they
// also unify with `String`, producing a tie in overload resolution; in a tie
// the first-declared overload wins. Declaring the char form first keeps the
// expected meaning of `find(s, '/')`.

pub fn find(s: String, c: char) usize? {
    let buf = [0u8; 4]
    const n = encode_char(c, buf as u8[])
    if n == 1 {
        for i in 0..s.len {
            if s[i] == buf[0] { return i }
        }
        return null
    }
    return find(s, from_c_string(buf.ptr, n))
}

pub fn find(s: String, needle: String) usize? {
    let h = s.as_raw_bytes()
    let n = needle.as_raw_bytes()

    if n.len == 0 {
        return 0
    }
    if n.len > h.len {
        return null
    }

    // Build table
    // Would need to support dynamic stack allocated arrays
    let table = [0usize; 1024] // TODO support dynamic stack allocations and replace 1024 with n.len
    let j: usize = 0 // TODO handle multi statement inference
    for i in 1..n.len {
        loop {
            if n[i] == n[j] {
                j = j + 1
                table[i] = j
                break
            }
            if j == 0 {
                table[i] = 0
                break
            }
            j = table[j - 1]
        }
    }

    // Search
    j = 0
    for i in 0..h.len {
        loop {
            if h[i] == n[j] {
                j = j + 1
                if j == n.len {
                    return i - n.len + 1
                }
                break
            }
            if j == 0 {
                break
            }
            j = table[j - 1]
        }
    }

    return null
}

pub fn starts_with(s: String, prefix: String) bool {
    if (s.len < prefix.len) {
        return false
    }
    for i in 0..prefix.len {
        const i = i as usize
        if (s[i] != prefix[i]) {
            return false
        }
    }
    return true
}

pub fn rfind(s: String, c: char) usize? {
    let buf = [0u8; 4]
    const n = encode_char(c, buf as u8[])
    if n == 1 {
        let i: usize = s.len
        while i > 0 {
            i = i - 1
            if s[i] == buf[0] { return i }
        }
        return null
    }
    return rfind(s, from_c_string(buf.ptr, n))
}

pub fn rfind(s: String, needle: String) usize? {
    let h = s.as_raw_bytes()
    let n = needle.as_raw_bytes()

    if n.len == 0 {
        return s.len
    }
    if n.len > h.len {
        return null
    }

    // Reverse linear scan
    let i = h.len - n.len + 1
    while i != 0 {
        i = i - 1

        let found = true
        for j in 0..n.len {
            const j = j as usize
            if h[i + j] != n[j] {
                found = false
                break
            }
        }
        if found {
            return i
        }
    }
    return null
}

pub fn contains(s: String, needle: String) bool {
    return find(s, needle).is_some()
}

pub fn ends_with(s: String, suffix: String) bool {
    if s.len < suffix.len {
        return false
    }
    let h = s.as_raw_bytes()
    let n = suffix.as_raw_bytes()
    let start = s.len - suffix.len
    for i in 0..suffix.len {
        const i = i as usize
        if h[start + i] != n[i] {
            return false
        }
    }
    return true
}

fn is_ascii_whitespace(c: u8) bool {
    return c == 32 or c == 9 or c == 10 or c == 13
}

pub fn trim_start(s: String) String {
    let h = s.as_raw_bytes()
    let start: usize = 0
    while start < h.len and is_ascii_whitespace(h[start]) {
        start = start + 1
    }
    return .{ ptr = s.ptr + start, len = s.len - start }
}

pub fn trim_end(s: String) String {
    let h = s.as_raw_bytes()
    let end = h.len
    while end != 0 and is_ascii_whitespace(h[end - 1]) {
        end = end - 1
    }
    return .{ ptr = s.ptr, len = end }
}

pub fn trim(s: String) String {
    return trim_end(trim_start(s))
}

// =============================================================================
// Split
// =============================================================================
//
// Byte- and String-delimiter overloads. Byte form is declared first for the
// same overload-resolution reason documented above (char literals bind to an
// unconstrained type variable and tie with the String overload — first wins).

// Split a string by a byte delimiter. Returns a List of non-owning views.
//   split("a,b,c", ',')    → ["a", "b", "c"]
//   split("a,b,c", ',', 1) → ["a", "b,c"]
pub fn split(s: String, delimiter: u8, max: i32 = -1) List(String) {
    let result: List(String) = list(0)
    let start: usize = 0
    let splits: i32 = 0
    for i in 0..s.len {
        if s[i] == delimiter and (max < 0 or splits < max) {
            result.push(s[start..i])
            start = i + 1
            splits = splits + 1
        }
    }
    result.push(s[start..s.len])
    return result
}

// Split a string by a String delimiter. Returns a List of non-owning views.
// An empty delimiter is treated as "no split" — the result is one element.
//   split("a::b::c", "::")    → ["a", "b", "c"]
//   split("a::b::c", "::", 1) → ["a", "b::c"]
pub fn split(s: String, sep: String, max: i32 = -1) List(String) {
    let result: List(String) = list(0)
    if sep.len == 0 {
        result.push(s)
        return result
    }
    let start: usize = 0
    let i: usize = 0
    let splits: i32 = 0
    loop {
        if i + sep.len > s.len { break }
        if max >= 0 and splits >= max { break }
        let matched: bool = true
        for k in 0..sep.len {
            if s[i + k] != sep[k] { matched = false; break }
        }
        if matched {
            result.push(s[start..i])
            start = i + sep.len
            i = start
            splits = splits + 1
            continue
        }
        i = i + 1
    }
    result.push(s[start..s.len])
    return result
}

// =============================================================================
// Char-overload count (find / rfind already declared above the String overloads)
// =============================================================================

pub fn count(s: String, c: char) usize {
    let buf = [0u8; 4]
    const n = encode_char(c, buf as u8[])
    if n == 1 {
        let total: usize = 0
        for i in 0..s.len {
            if s[i] == buf[0] { total = total + 1 }
        }
        return total
    }
    return count(s, from_c_string(buf.ptr, n))
}

pub fn count(s: String, needle: String) usize {
    if needle.len == 0 { return 0 }
    let total: usize = 0
    let i: usize = 0
    loop {
        if i + needle.len > s.len { break }
        const tail = s[i..s.len]
        const f = find(tail, needle)
        f match {
            Some(off) => {
                total = total + 1
                i = i + off + needle.len
            },
            None => break,
        }
    }
    return total
}

// =============================================================================
// Prefix / suffix
// =============================================================================

// Returns the remainder after `prefix` if `s` starts with `prefix`, else null.
//   "core.option".strip_prefix("core.") -> Some("option")
//   "std.io".strip_prefix("core.")      -> None
pub fn strip_prefix(s: String, prefix: String) String? {
    if !s.starts_with(prefix) { return null }
    return s[prefix.len..s.len]
}

pub fn strip_suffix(s: String, suffix: String) String? {
    if !s.ends_with(suffix) { return null }
    return s[0..s.len - suffix.len]
}

// =============================================================================
// Bisect / classification
// =============================================================================

// Splits `s` into (left, right) at byte index `i`. `i` is clamped to s.len.
pub fn split_at(s: String, i: usize) (String, String) {
    let cut: usize = i
    if cut > s.len { cut = s.len }
    return (s[0..cut], s[cut..s.len])
}

pub fn is_ascii(s: String) bool {
    for i in 0..s.len {
        if s[i] >= 0x80 { return false }
    }
    return true
}

fn ascii_lower(b: u8) u8 {
    if b >= 'A' and b <= 'Z' { return b + 32 }
    return b
}

pub fn eq_ignore_ascii_case(a: String, b: String) bool {
    if a.len != b.len { return false }
    for i in 0..a.len {
        if ascii_lower(a[i]) != ascii_lower(b[i]) { return false }
    }
    return true
}

// =============================================================================
// Lines iterator
// =============================================================================
//
// Yields each line of `s` as a non-owning String view. The trailing newline is
// stripped — both `\n` and `\r\n` produce the same line content. A final line
// without a trailing newline is still yielded.
//
//   for line in s.lines() { ... }

pub type Lines = struct {
    buf: u8[]
    pos: usize
    done: bool
}

pub fn lines(s: String) Lines {
    return .{
        buf = slice_from_raw_parts(s.ptr, s.len),
        pos = 0,
        done = false,
    }
}

pub fn iter(self: &Lines) &Lines {
    return self
}

pub fn next(self: &Lines) String? {
    if self.done { return null }
    if self.pos > self.buf.len { return null }

    const start = self.pos
    let i: usize = start
    while i < self.buf.len and self.buf[i] != '\n' {
        i = i + 1
    }

    let line_end: usize = i
    // Strip trailing \r from CRLF.
    if line_end > start and self.buf[line_end - 1] == '\r' {
        line_end = line_end - 1
    }
    const line = from_c_string(self.buf.ptr + start, line_end - start)

    if i >= self.buf.len {
        // Final segment without trailing \n. Yield once more only if non-empty;
        // otherwise yield empty and stop (so "a\n" yields just "a", "a" yields "a").
        self.done = true
        if start == self.buf.len { return null }
        return line
    }

    self.pos = i + 1
    return line
}


// =============================================================================
// OwnedString
// =============================================================================

pub type OwnedString = struct {
    ptr: &u8
    len: usize
    allocator: &Allocator?
}

pub fn from_view(s: String, allocator: &Allocator? = null) OwnedString {
    // TODO optimize
    const sb = string_builder(s.len, allocator)
    sb.append(s)
    return sb.to_string()
}

pub fn deinit(self: &OwnedString) {
    self.allocator.or_global().dealloc(slice_from_raw_parts(self.ptr, self.len))
    self.ptr = 0usize as &u8
    self.len = 0
}


pub fn as_view(self: OwnedString) String {
    return .{ ptr = self.ptr, len = self.len }
}

pub fn op_eq(a: OwnedString, b: OwnedString) bool {
    return op_eq(a.as_view(), b.as_view())
}

pub fn hash(s: OwnedString) usize {
    return hash(s.as_view())
}

#string_reader(OwnedString)

// =============================================================================
// Bytes Iterator
// =============================================================================

type Bytes = struct {
    buf: u8[]
    idx: usize
}

pub fn bytes(s: String) Bytes {
    // TODO fix String to Slice(u8) coersion
    const slice = slice_from_raw_parts(s.ptr, s.len)
    return .{ buf = slice, idx = 0 }
}

pub fn bytes(s: OwnedString) Bytes {
    // TODO fix String to Slice(u8) coersion
    const slice = slice_from_raw_parts(s.ptr, s.len)
    return .{ buf = slice, idx = 0 }
}

pub fn iter(b: &Bytes) Bytes {
    // TODO allow iter without reference
    return b.*
}

pub fn next(it: &Bytes) u8? {
    if (it.idx >= it.buf.len) {
        return null
    }

    const elem = it.buf[it.idx]
    it.idx = it.idx + 1
    return elem
}

// =============================================================================
// Chars Iterator
// =============================================================================

type Chars = struct {
    buf: u8[]
    idx: usize
}

pub fn chars(s: String) Chars {
    // TODO fix String to Slice(u8) coersion
    const slice = slice_from_raw_parts(s.ptr, s.len)
    return .{ buf = slice, idx = 0 }
}

pub fn chars(s: OwnedString) Chars {
    // TODO fix String to Slice(u8) coersion
    const slice = slice_from_raw_parts(s.ptr, s.len)
    return .{ buf = slice, idx = 0 }
}

pub fn iter(c: &Chars) Chars {
    return c.*
}

pub fn next(it: &Chars) char? {
    if (it.idx >= it.buf.len) {
        return null
    }

    const res = decode_char(it.buf[it.idx..])
    it.idx = it.idx + res.1
    return res.0
}

// =============================================================================
// Partition
// =============================================================================

// Split at the first occurrence of delimiter. Returns (before, after) as a tuple.
// No heap allocation. If delimiter not found, returns (s, "").
pub fn partition(s: String, delimiter: u8) (String, String) {
    for i in 0..s.len {
        if s[i] == delimiter {
            const before = s[0..i] as String
            const after = s[(i + 1)..s.len] as String
            return (before, after)
        }
    }
    return (s, "")
}
