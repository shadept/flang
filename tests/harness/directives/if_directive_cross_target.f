//! TEST: if_directive_cross_target
//! TARGET-OS: linux
//! EXIT: 0

// --target-os overrides the #if compile-time context: this compiles as a
// Linux build regardless of the host, so the linux branch is the one
// checked and lowered. (Pure code — the emitted C runs on any host.)

pub fn main() i32 {
    #if platform.os == "linux" {
        return 0
    } else {
        return 1
    }
}
