//! TEST: struct_op_set_index
//! EXIT: 55

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

pub fn op_set_index(v: &MyVec, index: i32, value: i32) {
    if (index == 0) {
        v.a = value
    }
    if (index == 1) {
        v.b = value
    }
    if (index == 2) {
        v.c = value
    }
}

pub fn main() i32 {
    let v: MyVec = .{ a = 0, b = 0, c = 0 }
    v[0] = 10
    v[1] = 20
    v[2] = 25
    return v[0] + v[1] + v[2]
}
