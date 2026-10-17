//! TEST: context_helper_lib
//! SKIP: helper module for the context tests - not run directly

pub context level: i32 = 5
context secret: i32 = 9

pub fn level_here() i32 {
    return context.level
}

pub fn secret_here() i32 {
    return context.secret
}
