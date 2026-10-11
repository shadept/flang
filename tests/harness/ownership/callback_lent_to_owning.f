//! TEST: callback_lent_to_owning
//! COMPILE-ERROR: E2134 callback_lent_to_owning.f
//! EXIT: 1

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: move FileHandle) i32 {
    return h.fd
}

fn each(s: $T[], f: $F) where F: fn(T) {
    for i in 0..s.len {
        f(s[i])
    }
}

fn dispose(h: move FileHandle) {}

// `each` lends `s[i]` (`F: fn(T)`); `dispose` needs ownership. Its bound refuses it here.
pub fn main() i32 {
    let xs: [FileHandle; 2] = [open(3), open(4)]
    each(xs, dispose)              // error E2134
    return 0
}
