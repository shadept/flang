//! TEST: owned_fields_copyable_types
//! EXIT: 3
//! SKIP: RFC-027 not implemented

type HandleBundle = struct {
    owned a: u32
    owned b: u32
}

let closed: i32 = 0

fn close_handle(h: u32) {
    closed = closed + 1
}

// `owned` is on the FIELD; the field's type is a copyable u32, so `deinit`
// reads both without any move at all.
fn deinit(self: HandleBundle) {
    close_handle(self.a)
    close_handle(self.b)
}

pub fn main() i32 {
    let hb = HandleBundle { a = 7u32, b = 8u32 }
    (move hb).deinit()
    return closed + 1
}
