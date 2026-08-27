// Fixture for the unused-import (W1004) tests: a leaf module with no imports of its own, so a
// test project can resolve `import p.leaf` from an override buffer without a stdlib on disk.

pub type Marker = struct {
    v: i32
}

pub fn leaf() i32 {
    return 3
}
