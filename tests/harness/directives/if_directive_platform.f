//! TEST: if_directive_platform
//! EXIT: 0

// Tests compile-time #if with platform.os comparisons.
// One branch must be active on the build platform.

fn get_os_name() i32 {
    let result: i32 = 0
    #if(platform.os == "macos") {
        result = 1
    } else {
        result = 2
    }
    return result
}

pub fn main() i32 {
    const os: i32 = get_os_name()
    // os must be non-zero (one of the branches ran)
    if (os == 0) {
        return 1
    }
    return 0
}
