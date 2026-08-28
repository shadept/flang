// Fixture for the `flang test` runner. Expected to fail: `test-all.cs` asserts the exit code, the
// summary line and that the block after the failing one still ran.
//
// What it pins:
//   - a passing block reports `ok`
//   - a failed assertion panics, the runner reports FAILED and does not die with it
//   - the block AFTER a failure still runs, so recovery lands back in the loop
//   - a project whose `main` exists does not run it - the runner is the entry point
//   - the process exits non-zero when anything failed

import std.test

fn main() i32 {
    println("FIXTURE-MAIN-RAN")
    return 0
}

test "a passing block" {
    assert_eq(1i32 + 1i32, 2i32, "arithmetic works")
}

test "a failing block" {
    assert_eq(1i32 + 1i32, 3i32, "FIXTURE-EXPECTED-FAILURE")
}

test "a block after the failure" {
    assert_true(true, "the runner carried on")
}
