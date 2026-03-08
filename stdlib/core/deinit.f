// Universal no-op deinit for primitive types and non-owning views.
// Every type in FLang should have a deinit function so that generic
// containers (Dict, List, etc.) can unconditionally call key.deinit()
// and value.deinit() without knowing whether the type owns heap memory.
//
// Types that own heap memory (OwnedString, List, Dict, etc.) provide
// their own deinit that frees through the allocator.

pub fn deinit(self: &bool) {}
pub fn deinit(self: &u8) {}
pub fn deinit(self: &u16) {}
pub fn deinit(self: &u32) {}
pub fn deinit(self: &u64) {}
pub fn deinit(self: &i8) {}
pub fn deinit(self: &i16) {}
pub fn deinit(self: &i32) {}
pub fn deinit(self: &i64) {}
pub fn deinit(self: &usize) {}
pub fn deinit(self: &isize) {}
pub fn deinit(self: &f32) {}
pub fn deinit(self: &f64) {}

// String is a non-owning view (ptr + len), no memory to free.
pub fn deinit(self: &String) {}
