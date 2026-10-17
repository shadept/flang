//! TEST: temporary_receiver_adapt
//! EXIT: 0

// A temporary scalar receiver in each shape UFCS can give it: already the reference the parameter
// takes, a value taken by reference (spilled to a slot), and a reference taken by value.

fn plus_one(self: &i32) i32 {
    return self.* + 1
}

fn twice(self: i32) i32 {
    return self * 2
}

fn ref_of(x: &i32) &i32 {
    return x
}

fn seven() i32 {
    return 7
}

pub fn main() i32 {
    const n: i32 = 20
    if ref_of(&n).plus_one() != 21i32 {
        return 1
    }
    if seven().plus_one() != 8i32 {
        return 2
    }
    if ref_of(&n).twice() != 40i32 {
        return 3
    }
    return 0
}
