//! TEST: directives_error_directive_generic
//! COMPILE-ERROR: E2999 needs copyable elements, Handle owns something

// A `#error` reached inside an instantiation reports at the call site, formatted with the
// specialization's type parameters.

type Handle = struct {
    owned fd: i32
}

fn spill(src: $T[], dest: T[]) usize {
    #if !type_info(T).copyable {
        #error($"needs copyable elements, {T.name} owns something",
            $"clone each element with clone(&{T.name}, allocator)")
    }
    return 0
}

pub fn main() i32 {
    let a: Handle[] = []
    let b: Handle[] = []
    return spill(a, b) as i32
}
