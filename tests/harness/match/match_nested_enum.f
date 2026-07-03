//! TEST: match_nested_enum
//! EXIT: 42

type Inner = enum {
    Value(i32)
    Empty
}

type Outer = enum {
    Wrapped(Inner)
    Direct(i32)
}

pub fn main() i32 {
    let inner: Inner = Inner.Value(42)
    let outer: Outer = Outer.Wrapped(inner)
    
    return outer match {
        Direct(x) => x,
        Wrapped(i) => unwrap_inner(i)
    }
}

fn unwrap_inner(i: Inner) i32 {
    return i match {
        Value(x) => x,
        Empty => 0
    }
}

