//! TEST: struct_op_index
//! EXIT: 42

pub struct MyVec {
    a: i32
    b: i32
    c: i32
}

pub fn op_index(v: &MyVec, index: i32) i32 {
    if (index == 0) {
        return v.a
    }
    if (index == 1) {
        return v.b
    }
    return v.c
}

pub fn main() i32 {
    let v: MyVec = .{ a = 10, b = 32, c = 99 }
    let a: i32 = v[0]
    let b: i32 = v[1]
    return a + b
}
