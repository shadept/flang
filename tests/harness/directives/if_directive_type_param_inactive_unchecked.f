//! TEST: if_directive_type_param_inactive_unchecked
//! EXIT: 3

// The inactive branch of a `#if` over a type parameter is invisible to the checker for that
// instantiation: `clone` exists for `Pair` only, and the `i32` instantiation never resolves it.

import core.rtti

type Pair = struct {
    owned a: i32
    b: i32
}

fn clone(self: &Pair) Pair {
    return Pair { a = self.a, b = self.b }
}

fn weight(x: &$T) i32 {
    #if type_info(T).copyable {
        return 1
    } else {
        const c = x.clone()
        return c.b
    }
}

pub fn main() i32 {
    let n: i32 = 0
    let p = Pair { a = 1, b = 2 }
    return weight(&n) + weight(&p)
}
