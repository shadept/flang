// Panic: report and terminate.

import core.string
import core.io

// C runtime functions for program termination
#foreign fn exit(code: i32) never

// Hands control back to the test runner, which records the current test as failed and carries on
// with the next one. Outside a test binary it terminates the process exactly like `exit(1)`, so a
// `#if runtime.testing` build that is not actually under a runner still dies on a panic.
//
// Only panics take this route. A deliberate `exit` stays a real process exit, under a test runner
// as anywhere else.
#foreign fn __flang_test_abort() never

// Panic: print message and terminate with exit code 1
pub fn panic(msg: String) never {
    println(msg)
    #if runtime.testing {
        __flang_test_abort()
    }
    exit(1)
}
