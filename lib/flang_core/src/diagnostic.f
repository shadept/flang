// Diagnostic — the shared error/warning/hint type emitted by every phase
// of the compiler and consumed by the CLI, the LSP, the formatter, and
// `flang fix`. Code actions ship attached to the diagnostic so the same
// fix surfaces in both the CLI and the LSP from a single source.

import std.list
import std.string
import flang_core.span

// Severity ladder used by every phase. The order matters: clients filter
// by `severity >= some_floor` to suppress hints during CI runs, for
// example. Adding a new level means agreeing on its place in the order.
pub type Severity = enum {
    // Suggestions the user can ignore — unused imports, naming nits.
    Hint = 0
    // Informational notes attached to another diagnostic — not standalone.
    Info = 1
    // Compiler warnings (W2003 unknown directive, etc.). Build still
    // succeeds.
    Warning = 2
    // Hard errors. Build fails.
    Error = 3
}

// A single diagnostic. `code` is the canonical identifier (E1234 / W2003);
// `message` is the one-line summary; `hint` is the optional secondary
// guidance (often a "did you mean …?" suggestion). `span` points at the
// offending source range — `none_span()` for diagnostics with no
// location.
pub type Diagnostic = struct {
    severity: Severity
    code: String
    message: OwnedString
    hint: OwnedString
    span: SourceSpan
}

pub fn error(code: String, message: OwnedString, span: SourceSpan) Diagnostic {
    let empty_hint: OwnedString
    return .{
        severity = Severity.Error,
        code = code,
        message = message,
        hint = empty_hint,
        span = span,
    }
}
