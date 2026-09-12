//! TEST: directives_error_directive_decl
//! COMPILE-ERROR: E2999 this file must not build on macos

// A declaration-level `#error` is evaluated over the closed context, so it can name the target.

#error($"this file must not build on {platform.os}", "pick another target")

pub fn main() i32 {
    return 0
}
