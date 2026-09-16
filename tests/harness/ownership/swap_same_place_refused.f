//! TEST: swap_same_place_refused
//! COMPILE-ERROR: E2133
//! EXIT: 1

type Handle = struct {
    owned fd: i32
}

// Two claims on one place: the exchange would take the value out twice. Two DIFFERENT elements of
// one container are fine (sort_owning_elements) - what rule 9 refuses is the same place twice.
pub fn main() i32 {
    let h = Handle { fd = 3 }
    swap(&h, &h)
    return 0
}
