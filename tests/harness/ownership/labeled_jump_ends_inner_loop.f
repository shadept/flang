//! TEST: labeled_jump_ends_inner_loop
//! EXIT: 3

// A labeled jump never reaches the inner loop's head again, so a move before it happens once.
type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: move FileHandle) i32 {
    return h.fd
}

pub fn main() i32 {
    let total: i32 = 0
    outer: for i in 0..2 as i32 {
        const h = open(i + 1)
        loop {
            total = total + h.close()
            continue outer
        }
    }
    const last = open(0)
    done: loop {
        loop {
            total = total + last.close()
            break done
        }
    }
    return total
}
