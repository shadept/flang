// Diagnostic - the shared error/warning/hint type emitted by every phase of the compiler and
// consumed by the CLI, the LSP and the formatter. `flang_core.render` draws the terminal form; the
// LSP encodes the same values into the protocol's own shape.

import std.string

import flang_core.span

// Severity ladder used by every phase. The order matters: clients filter by `severity >=
// some_floor` to suppress hints during CI runs, for example. Adding a new level means agreeing on
// its place in the order.
pub type Severity = enum {
    // Suggestions the user can ignore - unused imports, naming nits.
    Hint = 0
    // Informational notes attached to another diagnostic - not standalone.
    Info = 1
    // Compiler warnings (W2003 unknown directive, etc.). Build still succeeds.
    Warning = 2
    // Hard errors. Build fails.
    Error = 3
}

// A single diagnostic. `code` is the canonical identifier (E1234 / W2003); `message` is the
// one-line summary; `hint` is the optional secondary
// guidance (often a "did you mean …?" suggestion). `span` points at the
// offending source range - `none_span()` for diagnostics with no location.
pub type Diagnostic = struct {
    severity: Severity
    code: String
    message: OwnedString
    hint: OwnedString
    span: SourceSpan
}

// `message` and `hint` are owned by the diagnostic that holds them; `code` is a borrow of a static
// literal. Copying a diagnostic into a second container copies the OWNERSHIP with it, so a copy
// that outlives its source is made with `clone_diag`, and a bulk move leaves the source with
// `List.release` rather than `clear`.
pub fn deinit(self: move Diagnostic) {
    self.message.deinit()
    self.hint.deinit()
}

// The element form: a list of diagnostics releases each with its allocator in hand. The strings
// carry their own.
pub fn deinit(self: move Diagnostic, allocator: &Allocator) {
    self.deinit()
}

pub fn error(code: String, message: move OwnedString, span: SourceSpan) Diagnostic {
    let empty_hint: OwnedString
    return .{
        severity = Severity.Error,
        code = code,
        message = move message,
        hint = move empty_hint,
        span = span,
    }
}

// The same diagnostic at another span: the message and hint move across, so `d` is dead. This is
// how a phase that parses a fragment shifts its diagnostics onto file offsets.
pub fn respan(d: move Diagnostic, span: SourceSpan) Diagnostic {
    return .{
        severity = d.severity,
        code = d.code,
        message = move d.message,
        hint = move d.hint,
        span = span,
    }
}

// A copy owning its own message and hint, so one diagnostic can be replayed into a list that frees
// what it holds without consuming the original. `code` is a static view and copies as-is.
pub fn clone_diag(d: &Diagnostic) Diagnostic {
    return .{
        severity = d.severity,
        code = d.code,
        message = from_view(d.message.view),
        hint = from_view(d.hint.view),
        span = d.span,
    }
}
