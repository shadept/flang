//! TEST: template_if_non_bool
//! COMPILE-ERROR: E2117

// Template `#if` is the same construct as the `#if` directive (RFC-021 §3):
// one evaluator, same rules. A string condition is an error, not "truthy".

#define(make, Name: Ident) {
    #if Name {
        fn #(Name)() i32 { return 1 }
    }
}

#make(thing)

pub fn main() i32 { return 0 }
