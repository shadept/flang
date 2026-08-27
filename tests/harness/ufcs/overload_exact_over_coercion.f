//! TEST: overload_exact_over_coercion
//! EXIT: 0

// An argument matching a parameter type as-is beats one needing an implicit
// conversion, whatever the types' structure: a String literal picks the
// String overload over a u8[] sibling (String -> u8[] decay stays available
// when no String parameter exists).

type Sink = struct {
    last: i32
}

fn put(s: &Sink, text: String) i32 {
    s.last = 1
    return s.last
}

fn put(s: &Sink, data: u8[]) i32 {
    s.last = 2
    return s.last
}

pub fn main() i32 {
    let s = Sink { last = 0 }

    if put(&s, "hello") != 1 {
        return 1
    }

    // The decay still applies when only the slice overload can take it.
    const text = "bytes"
    if put(&s, text.as_raw_bytes()) != 2 {
        return 2
    }

    return 0
}
