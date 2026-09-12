// Source generator that produces forwarding overloads for any type T that has
// an `as_view() String` method.  Invoke as:  #string_reader(MyType)
//
// Also provides MemReader - a Reader implementation over a byte slice in memory. Any type with
// #string_reader gets a reader() method returning a MemReader.

import std.interface
import std.io.reader
import std.mem
import std.string

// Reader over a byte slice in memory.
// Create via mem_reader(s), then call mr.reader() to get a Reader interface. The MemReader must
// outlive the Reader (it holds the context pointer).
pub type MemReader = struct {
    data: u8[]
    pos: usize
}

pub fn mem_reader(s: String) MemReader {
    return .{ data = slice_from_raw_parts(s.ptr, s.len), pos = 0 }
}

fn read(self: &MemReader, buf: u8[]) usize {
    if self.pos >= self.data.len {
        return 0
    }
    let avail = self.data.len - self.pos
    let n = if buf.len < avail { buf.len } else { avail }
    memcpy(buf.ptr, self.data.ptr + self.pos, n)
    self.pos = self.pos + n
    return n
}

#implement(MemReader, Reader)

#define(string_reader, T: Type) {
    pub fn find(self: &#(T.name), needle: String) usize? { return find(self.as_view(), needle) }
    pub fn rfind(self: &#(T.name), needle: String) usize? { return rfind(self.as_view(), needle) }
    pub fn contains(self: &#(T.name), needle: String) bool { return contains(self.as_view(), needle) }
    pub fn starts_with(self: &#(T.name), prefix: String) bool { return starts_with(self.as_view(), prefix) }
    pub fn ends_with(self: &#(T.name), suffix: String) bool { return ends_with(self.as_view(), suffix) }
    pub fn trim(self: &#(T.name)) String { return trim(self.as_view()) }
    pub fn trim_start(self: &#(T.name)) String { return trim_start(self.as_view()) }
    pub fn trim_end(self: &#(T.name)) String { return trim_end(self.as_view()) }
}
