//! TEST: rtti_type_params
//! EXIT: 0

// Test that type_params and type_args are correct

import core.rtti

fn check_no_params(t: Type($T)) i32 {
    return t.type_params.len as i32 + t.type_args.len as i32
}

pub fn main() i32 {
    // i32 has 0 type params and 0 type args
    return check_no_params(i32)
}
