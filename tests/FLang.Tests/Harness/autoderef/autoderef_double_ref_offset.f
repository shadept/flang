//! TEST: autoderef_double_ref_offset
//! EXIT: 55

struct Data {
    first: i32,
    second: i32,
    third: i32
}

pub fn getSecond(pp: &&Data) i32 {
    // Double auto-deref AND access non-first field
    return pp.second
}

pub fn getThird(pp: &&Data) i32 {
    // Double auto-deref AND access third field
    return pp.third
}

pub fn main() i32 {
    let d: Data = Data { first = 11, second = 22, third = 33 }
    let ptr: &Data = &d
    return getSecond(&ptr) + getThird(&ptr)
}
