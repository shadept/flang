// Panic function for FLang runtime
// Part of Milestone 16: Test Framework

import core.string
import core.io

// C runtime functions for program termination
#foreign fn exit(code: i32) never

// Panic: print message and terminate with exit code 1
pub fn panic(msg: String) never {
    println(msg)
    exit(1)
}
