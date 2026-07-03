//! TEST: test_parser_hang_repro
//! EXIT: 0

// Named struct construction with generic type args: TypeName(TypeArg) { ... }
// Previously gave a semantic error; now supported.

type Foo = struct(T) {
    value: T
}

pub fn main() i32 {
    let x = Foo(i32) { value = 5 }
    return 0
}
