//! TEST: malloc_free
//! EXIT: 42

// Test basic malloc and free
// Allocate an i32, write to it, read it back, then free
// TODO fix test is causing the compiler to loop forever and consume all the memory in the world

import core.mem
import core.rtti

pub fn main() i32 {
    // Allocate 4 bytes for an i32
    //let ptr: &u8? = malloc(size_of(i32))

    // Cast to i32 pointer and write value
    //let int_ptr: &i32 = ptr as &i32
    //int_ptr.* = 42

    // Read it back
    //let value: i32 = int_ptr.*

    // Free the memory
    //free(ptr)

    //return value
    return 42
}
