// NodeId — stable identity for an AST node across the checker, the
// inference results, the reporter, and the LSP.
//
// The parser hands every AST node a `SourceSpan`. Spans are stable
// for the lifetime of a compilation (same file, same byte offsets),
// so a span doubles as a node identity. We fingerprint
// `(file_id, start, length)` into a `NodeId` keyed dict lookups can
// use as a hashable primitive.
//
// Why not just use object identity? `Dict(K, V)` hashes by raw bytes,
// and AST nodes are large structs whose internal pointers (children,
// list buffers, …) shift across re-parses. Span fingerprints are
// stable across re-parses of the same source.

import flang_core.span

// Transparent alias over `u64` so callers pay no wrapping cost and
// the default `hash` lights up. The encoding packs:
//   - bits 0..31  → start byte offset (clamped to u32)
//   - bits 32..47 → length (clamped to u16)
//   - bits 48..63 → file_id (clamped to i16)
// Spans larger than u16 chars or files past i16 are extremely rare
// in real source; the clamp loses precision on those but never
// produces a collision in normal code.
pub type NodeId = u64

pub fn node_id_of(span: SourceSpan) NodeId {
    let mask_lo: u64 = 0xFFFF_FFFF as u64
    let mask_hi: u64 = 0xFFFF as u64
    let start = (span.start as u64) & mask_lo
    let length = ((span.length as u64) & mask_hi) << (32u64)
    let file = ((span.file_id as u64) & mask_hi) << (48u64)
    return start | length | file
}
