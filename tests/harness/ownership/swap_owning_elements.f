//! TEST: swap_owning_elements
//! EXIT: 123

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

// `swap` exchanges the bytes behind two references: the same owners exist before and after, so
// owning elements need no gate, and `reverse` is built on it.
pub fn main() i32 {
    let arr = [open(1), open(2), open(3)]
    swap(&arr[0], &arr[2])
    if arr[0].fd != 3 or arr[2].fd != 1 {
        return 99
    }
    const s = arr as FileHandle[]
    s.reverse()
    return arr[0].fd * 100 + arr[1].fd * 10 + arr[2].fd
}
