//! TEST: enum_naked_tag_value
//! EXIT: 0
//! STDOUT: 12 8 23 6 7 -1 1

// A naked enum's explicit `= N` is its wire tag: `e as i32` yields the declared value, not the
// declaration index, and `n as E` reads that same value back. Auto-incremented and negative tags
// go through the same numbering.

type Kind = enum {
    Field = 8
    Function = 12
    Struct = 23
}

type Status = enum {
    A
    B
    C = 6
    D
}

type Sign = enum {
    Negative = -1
    Zero = 0
    Positive = 1
}

fn show(v: i32) {
    print(v)
    print(" ")
}

pub fn main() i32 {
    show(Kind.Function as i32)
    show(Kind.Field as i32)
    show(Kind.Struct as i32)
    show(Status.C as i32)
    show(Status.D as i32)
    show(Sign.Negative as i32)

    // Back the other way: the tag names the variant it was taken from.
    const round: Sign = 1i32 as Sign
    const tag: i32 = round match {
        Negative => -1,
        Zero => 0,
        Positive => 1
    }
    println(tag)
    return 0
}
