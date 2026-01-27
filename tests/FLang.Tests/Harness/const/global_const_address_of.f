//! TEST: global_const_address_of
//! EXIT: 42

struct Inner {
    value: i32
}

struct Wrapper {
    ptr: &u8,
    tag: i32
}

const inner_state = Inner { value = 42 }
const wrapper = Wrapper {
    ptr = &inner_state as &u8,
    tag = 7
}

pub fn main() i32 {
    let p = wrapper.ptr as &Inner
    return p.value
}
