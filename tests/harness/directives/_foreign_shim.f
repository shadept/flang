//! TEST: foreign_shim_helper
//! SKIP: helper module for foreign_union and foreign_opaque - not run directly

// C side: _foreign_shim.c, linked because it sits beside this module.

pub type Num = #foreign union {
    f: f32
    d: f64
}

pub type Counter = #foreign struct {}

#foreign pub fn shim_twice(n: Num) Num
#foreign pub fn counter_new(start: i32) &Counter?
#foreign pub fn counter_add(c: &Counter, by: i32)
#foreign pub fn counter_get(c: &Counter) i32
#foreign pub fn counter_free(c: &Counter)
