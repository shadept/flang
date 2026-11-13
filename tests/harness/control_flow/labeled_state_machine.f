//! TEST: labeled_state_machine
//! STDOUT: [ab]
//! STDOUT: [cde]
//! STDOUT: [f]
//! EXIT: 0

// A state machine as a state variable, a labeled `loop` and a `match` (RFC-042 §4).
import std.io.print
import std.string_builder

type State = enum {
    Gap
    Word(usize)
}

pub fn main() i32 {
    const src: String = " ab  cde f"
    let state: State = State.Gap
    let i: usize = 0
    scan: loop {
        state match {
            Gap => {
                if i == src.len {
                    break scan
                }
                const c: u8 = src[i]
                i = i + 1
                if c != b' ' {
                    state = State.Word(i - 1)
                }
                continue scan
            }
            Word(start) => {
                if i == src.len or src[i] == b' ' {
                    println($"[{src[start..i]}]")
                    state = State.Gap
                    continue scan
                }
                i = i + 1
            }
        }
    }
    return 0
}
