// Trivia — whitespace, comments, blank lines.
//
// Non-semantic byte ranges attached to adjacent tokens as leading or
// trailing. Concatenating every token's leading + text + trailing
// reproduces the source file byte-for-byte: this is the invariant the
// formatter relies on.

pub type TriviaKind = enum {
    Whitespace
    LineComment
}

// A single piece of trivia. `text` is a view into the original source buffer
// (no copy). Lifetime is tied to the source file's backing string.
pub type Trivia = struct {
    kind: TriviaKind
    text: String
}
