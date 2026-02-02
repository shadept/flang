//! TEST: rtti_type_params
//! EXIT: 0

// Test that type_params and type_args are correct

import core.rtti

pub fn main() i32 {
    // i32 has 0 type params and 0 type args
    let t = i32
    let params = t.type_params.len as i32
    let args = t.type_args.len as i32
    return params + args
}
