// Source generator that produces forwarding overloads for any type T that has
// an `as_view() String` method.  Invoke as:  #string_reader(MyType)
//
// Also provides MemReader — a Reader implementation over a byte slice in memory.
// Any type with #string_reader gets a reader() method returning a MemReader.

import std.string
import std.mem
import std.io.reader
import std.interface

// Reader over a byte slice in memory.
// Create via mem_reader(s) or via the reader() method on String-like types.
// The source data must outlive the MemReader.
pub type MemReader = struct {
    data: u8[]
    pos: usize
}

pub fn mem_reader(s: String) MemReader {
    return .{ data = slice_from_raw_parts(s.ptr, s.len), pos = 0 }
}

fn read(self: &MemReader, buf: u8[]) usize {
    if self.pos >= self.data.len { return 0 }
    let avail = self.data.len - self.pos
    let n = if buf.len < avail { buf.len } else { avail }
    memcpy(buf.ptr, self.data.ptr + self.pos, n)
    self.pos = self.pos + n
    return n
}

#implement(MemReader, Reader)

pub fn reader(s: String) MemReader {
    return mem_reader(s)
}

#define(string_reader, T: Type) {
    pub fn find(s: #(T.name), needle: String) usize? { return find(s.as_view(), needle) }
    pub fn rfind(s: #(T.name), needle: String) usize? { return rfind(s.as_view(), needle) }
    pub fn contains(s: #(T.name), needle: String) bool { return contains(s.as_view(), needle) }
    pub fn starts_with(s: #(T.name), prefix: String) bool { return starts_with(s.as_view(), prefix) }
    pub fn ends_with(s: #(T.name), suffix: String) bool { return ends_with(s.as_view(), suffix) }
    pub fn trim(s: #(T.name)) String { return trim(s.as_view()) }
    pub fn trim_start(s: #(T.name)) String { return trim_start(s.as_view()) }
    pub fn trim_end(s: #(T.name)) String { return trim_end(s.as_view()) }
    pub fn reader(s: #(T.name)) MemReader { return reader(s.as_view()) }
}
