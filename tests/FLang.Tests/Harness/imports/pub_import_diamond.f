//! TEST: pub_import_diamond
//! EXIT: 11

// Diamond: importing two modules that both pub-import _diamond_root must
// resolve cleanly to a single overload (no duplicate-import error, no
// ambiguity), since both paths reach the same defining module.

import _diamond_left
import _diamond_right

pub fn main() i32 {
    return diamond_value()
}
