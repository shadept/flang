//! TEST: foreign_fstring_layout
//! EXIT: 0

import core.foreign

// `FString` is laid out as C's `{ const char *ptr; size_t len; }`: the pointer first, the length
// right after it, nothing else.
pub fn main() i32 {
    const t = type_info(FString)
    if t.fields.len != 2usize or t.fields[0].name != "ptr" or t.fields[0].offset != 0usize {
        return 1
    }
    if t.fields[1].name != "len" or t.fields[1].offset != size_of(&u8) {
        return 2
    }
    if size_of(FString) != size_of(&u8) + size_of(usize) {
        return 3
    }
    const c: FString = "abc".to_fstr()
    if c.len != 3usize {
        return 4
    }
    return 0
}
