//! TEST: nested_helper_lib
//! SKIP: helper module for nested_type_* - not run directly

pub type Pub = struct {
    pub type Open = struct { x: i32 }
    pub type Mode = enum { On, Off(i32) }
    type Hidden = struct { x: i32 }
    o: Open
}

pub type Gen = struct(T) {
    pub type Cell = struct(U) { t: T, u: U }
    c: Cell(T)
}
