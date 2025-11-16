// String type - UTF-8 view, always null-terminated for C FFI
// Binary-compatible with u8[] slice
pub struct String {
    ptr: &u8,
    len: usize
}
