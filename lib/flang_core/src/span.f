// SourceSpan — a byte range inside a known source file.
//
// `file_id` is workspace-stable: the same logical file keeps the same id
// across compilations, which is what makes cross-file find-references
// and persistent indexes work.

// A source location, identified by workspace-stable file id and a byte
// range within that file. Line and column are derived on demand from the
// owning Source's line-endings table — not stored here.
pub type SourceSpan = struct {
    file_id: i32
    // Inclusive byte offset of the first character.
    start: usize
    // Length in bytes; `start + length` is the exclusive end.
    length: usize
}

// Sentinel for diagnostics with no associated source location (e.g.
// "no input files"). `file_id = -1` is the agreed marker.
pub fn none_span() SourceSpan {
    return .{ file_id = -1, start = 0, length = 0 }
}

pub fn is_none(span: SourceSpan) bool {
    return span.file_id < 0
}
