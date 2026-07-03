//! TEST: directives_directive_args
//! EXIT: 0

import core.io

#foreign fn exit(code: i32)

pub fn main() i32 {
    exit(0)
    return 0
}
