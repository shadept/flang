# RFC-023: Language server - in-process, self-hosted, retires FLang.Lsp

**Type:** Compiler tool + stdlib addition
**Status:** In progress - phases 1-7 landed (`std.rpc.jsonrpc`; `lib/flang_lsp` skeleton: lifecycle, encoding negotiation, full sync, line index; in-process `flang lsp -s <stdlib>`; publishDiagnostics + `$/progress` over lazily-opened projects with buffer overrides; tier 1: documentSymbol, foldingRange, syntax diagnostics per keystroke; `flang/serverStatus` + extension status bar + `flang.serverFlavor` switch; ModuleIndex + workspace/symbol)
**Depends on:** RFC-022 (demand-driven checker)
**Retires:** `src/FLang.Lsp` (3,729 lines, C#, OmniSharp)

## Summary

`flang lsp` becomes a real language server, in-process, built on the demand-driven
checker from RFC-022.

1. **In-process.** `lib/flang_lsp` (kind = lib), driven by a `lsp` subcommand in
   `bootstrap/src/main.f`. No spawned sibling binary - `spawn_tool` requires the
   tool on PATH and `build.cs` never installs one, so `flang lsp` is broken by
   construction today.
2. **`std.rpc.jsonrpc`** - Content-Length framing plus JSON-RPC 2.0 envelope over
   a `Reader`/`Writer` pair. Transport-agnostic; stdio is the only transport.
   Namespaced under `std.rpc` rather than the stdlib root: protocols sit above
   formats (`std.encoding`) and transports (`std.io`), and the root stays for
   fundamentals.
3. **Single-threaded.** Analysis never runs inside a request handler.
4. **v1 = C# parity + completion.**

## Motivation

The current server is incomplete (no completion, formatting, rename, semantic
tokens, folding, code actions, call hierarchy), depends on an external C#
package, and is the last user-facing reason the reference compiler exists.

Go-to-definition is weak for reasons that are data gaps in the typer, not LSP
bugs - `Field` and `VariantDef` carry no `decl_span`, and `RtLocal(NodeId)` cites
a lossy fingerprint that cannot be inverted to a span. RFC-022 §9 closes them.

## Design

### 1. Vocabulary

- **module** - one `.f` file, one compilation unit
- **project** - the modules under one root `flang.toml`
- **workspace** - the set of projects open in the LSP

To be added to `CONTEXT.md`.

### 2. Concurrency model

stdlib has no threads, no atomics, no synchronisation primitives, and the checker
is shared mutable state throughout. LSP 3.17 explicitly sanctions this:

> "If the server implementation uses a single threaded synchronous programming
> language then there is little a server can do to react to a `$/cancelRequest`
> notification."

The spec mandates **no** timeouts on requests or on `initialize`, and
`vscode-languageclient` leaves request promises pending. A blocking server reads
as sluggish, not dead.

**Invariant: analysis never runs inside a request handler.** Handlers answer from
the demand graph's current state, or answer empty. Demand is driven from the
message loop's idle path, polling stdin between units of work. This yields
`$/progress` from inside the loop, soft cancellation when a newer edit arrives,
and cheap requests answered while a larger demand is still settling.

### 3. Answer availability

Answers grow as demand settles, per module. Two rules:

- **Closed types only.** During settling, `node_types` entries can still contain
  free type variables. Zonk on demand and answer only when the result has no free
  vars; otherwise answer empty. A wrong type is never shown.
- **Tier 1 is immediate.** `didOpen` parses the module (~5 ms) and serves
  everything needing no types - syntax diagnostics, document symbols, folding,
  semantic tokens - while type-dependent answers fill in behind `$/progress`.

`$/progress` percentage is derived from demand-set size; the ETA widget is queue
depth.

### 4. `std.rpc.jsonrpc`

Three layers, only the third of which exists today:

```
  framing    Content-Length: N\r\n\r\n{json}   over a byte stream    NEW
  envelope   JSON-RPC 2.0 request/response/notification/error        NEW
  format     the bytes inside                        std.encoding.json
```

Written against `Reader`/`Writer` (the `#interface`-generated vtable types), so
it is testable in-process with `MemReader` and a string-backed writer - no
process, no editor, no socket. A socket transport later is a new `Reader`/`Writer`
implementation, not a change here.

**Casing.** The JSON-RPC envelope is `jsonrpc id method params result error code
message data` - all single lowercase words, identical under snake_case. **No
conflict with FLang conventions.** LSP *payloads* are camelCase throughout
(`textDocument`, `contentChanges`, `rootUri`, `workDoneToken`), which is the
serialization library's problem, not `std.rpc.jsonrpc`'s. This is why the module
can land and be proven before the schema library exists.

**Unions.** `id` is `integer | string`, and a response is `result` XOR `error`.
`#derive` is structs-only, so v1 hand-writes the envelope codec. For `id`
specifically the server never interprets it: `RpcMessage` owns the parsed
document, the id stays a `JsonValue` borrowed from it, and write_response /
write_error re-serialize it as-is (integer ids re-emit without a fractional
part; JSON integers are exact in f64 through 2^53). Once the schema library
supports per-field transforms and transparent union detection, the envelope
migrates to derive.

### 5. Serialization dependency

LSP payload types are hand-written over `JsonValue` plus a small typed-accessor
helper set for v1, and migrate to `#derive` once the schema library supports:

- per-field rename and naming-convention conversion (snake_case <-> camelCase)
- optional-field omission (LSP fields are overwhelmingly optional; today
  `deserialize` does `let result: T` uninitialised and leaves unmatched keys as
  garbage)
- enums / transparent unions
- container fields (`List(T)`, `T?`, `Dict`)
- no fixed key cap (today `for _i in 0..1024`)

That work is its own track with its own requirements. Deliberately not shaped by
LSP's deadline - `oneOf` and camelCase are JSON-schema-isms and must not bend a
format-agnostic codec.

### 6. Position encoding

`SourceSpan` is byte offsets. LSP `Position` is `{line, character}` where
`character` counts UTF-16 code units by default.

**Negotiated: utf-8 preferred, utf-16 fallback.** The server picks from
`general.positionEncodings` and echoes its choice in
`capabilities.positionEncoding`. VS Code offers utf-16 only (two long-standing
open issues on `vscode-languageserver-node` ask for utf-8), so the conversion
path must exist; utf-8 is the fast path for clients that offer it.

utf-8 does **not** mean sending byte offsets - `Position` stays `{line,
character}` in every encoding; utf-8 only means `character` counts bytes within
the line. So the per-document line index (byte offsets of line starts, rebuilt
per version) is needed either way; utf-8 only removes the intra-line scan.

Per-line ASCII fast path: flag a line pure-ASCII on index build and skip the scan
entirely, which covers effectively all FLang source. `std/encoding/utf8.f` covers
the rest.

### 7. Document sync and external edits

`TextDocumentSyncKind.Full`. Largest file in this repo is `lower.f` at 337 KB;
traffic is irrelevant on a local pipe, the line index rebuilds per version
regardless, and Incremental's failure mode is silent buffer corruption that
surfaces as mysteriously wrong spans.

| who edits | what arrives |
|---|---|
| editor | `textDocument/didChange` |
| agent writes to disk, file not open | `workspace/didChangeWatchedFiles` |
| agent writes to disk, file open and unmodified | VS Code reloads -> `didChange` with whole content |
| agent writes to disk, file open and modified | divergence |

Agents writing files directly is a first-class workload here. Full sync suits it:
an external whole-file rewrite *is* a full resync.

**Open buffers always win over disk during analysis.** Watchers registered for
`**/*.f` and `**/flang.toml`.

**Invalidate immediately, debounce the publish.** A watcher event bumps the
module's revision - O(1) under RFC-022, no work happens. Re-demand is what gets
debounced (~300 ms), and an in-flight demand abandoned mid-burst costs only what
it had computed. A 20-file agent burst leaves the graph correct at every instant.

### 8. Index seam

`ModuleIndex` - one per module, pointer-free (owned strings and `SourceSpan`s
only), keyed by source content hash. Holds declared symbols (name, kind,
`decl_span`, rendered signature, doc comment, member/variant list), the module's
import edges, and `file_id -> path`.

Built in memory from the analysis in v1 and thrown away on rebuild. A later
on-disk cache is a `load(hash)` / `store(hash)` pair and nothing else. The
`cache/cache.json` manifest pattern (version, flags hash, per-entry content hash)
is the precedent to follow.

**Rule, to stop the index becoming a second source of truth: cross-file and
name-level queries go to the index; cursor-level and type-level queries go to the
checker.**

### 9. Features and their data sources

| feature | source |
|---|---|
| publishDiagnostics | per-query diagnostics (RFC-022 §5), sorted by `(file_id, start)` |
| documentSymbol, foldingRange | `ModuleIndex` (tier 1, no types) |
| workspace/symbol | `ModuleIndex` across the workspace |
| hover | `node_types` at cursor + doc comment from `ModuleIndex` |
| definition | `resolved_targets` -> registry `decl_span` (needs RFC-022 §9) |
| typeDefinition | `node_types` -> `NominalDef.decl_span` |
| references | inverted `resolved_targets` / `resolved_ops` edges |
| inlayHint | `node_types` on let-bindings and parameters |
| signatureHelp | `FunctionScheme` overload set at the call site |
| completion | `ModuleIndex` (names in scope) + `node_types` (member access) |
| flang/generatedContent | `AnalyzedProject.generated` (`TemplateOutput`) |

Cursor -> node requires a span-containment walk over the module AST - the
analogue of the C# `AstNodeFinder` (348 lines).

`checkTests = true` for the LSP: `test {}` bodies are checked so the editor sees
them, unlike `flang build`.

### 10. Client

Extension lives at `C:\Users\Shade\Projects\vscode-flang` (v0.2.5), to move into
this repo later. It launches `flang --lsp --stdlib-path <p>`; it will be changed
to `flang lsp -s <p>`. Server selection is already a user setting
(`flang.serverPath`), which is the transition mechanism - point it at `flang-ref`
or `flang` as needed.

`flang/generatedContent` and the `flang-generated://` scheme are implemented on
the server side. Note: v0.2.5 in that checkout has zero references to the scheme
in source, bundle or manifest, yet go-to-generated reportedly works on macOS - so
either a different build is installed there or it resolves a real `.generated.f`
path. `docs/architecture.md:213` claims the extension registers a
`TextDocumentContentProvider`; that is not true of v0.2.5 and needs correcting or
confirming.

## Testing

Transcript tests as `test {}` blocks colocated in `lib/flang_lsp`: canned
JSON-RPC fed through `MemReader`, asserted against expected bytes out. No
process, no editor.

Coverage: initialize/shutdown handshake, each feature's request/response shape,
position round-tripping through a non-ASCII line, Full-sync buffer replacement,
watcher-driven invalidation, and diagnostics clearing when an error is fixed
(the failure mode a global diagnostic sink would have caused).

## Implementation phases

- [x] 1. std.rpc.jsonrpc: framing + envelope over Reader/Writer, with transcript tests
- [x] 2. lib/flang_lsp skeleton: initialize, shutdown, sync, line index, position codec
- [x] 3. publishDiagnostics + $/progress (workspace open -> full demand -> publish)
- [x] 4. tier 1: documentSymbol, foldingRange, syntax diagnostics on keystroke

Phase 3-4 deviations from the design above, all downstream of one fact: stdio
`Reader` cannot poll, so the idle-path demand driving of §2 and the ~300 ms
debounce of §7 are not implementable yet.

- Analysis runs synchronously between messages, behind `$/progress`
  begin/end (no percentage - there is no loop to yield from). A request
  arriving mid-analysis waits; the spec sanctions this (§2).
- Projects open lazily (first didOpen under a `flang.toml`), not eagerly on
  workspace open - analyzing every project of a monorepo up front would block
  the first didOpen for many seconds each.
- Keystrokes get tier-1 parse-only diagnostics; the type tier catches up on
  didSave and on watcher events (changed file -> re-check with that file
  dirty; created/deleted file or manifest edit -> project rebuilt whole).
- foldingRange is token-based (delimiter nesting over the lexer stream), not
  AST-based: survives parse errors, covers every nesting level, ~40 lines.
- `test {}` bodies are still unchecked - the self-host checker skips Test
  decls entirely today, so `checkTests` (§9) waits on that.
- Extension work scheduled for phase 10 landed early (v0.3.0): a
  `flang.serverFlavor` setting switches between `flang-ref --lsp
  --stdlib-path <p>` and `flang lsp -s <p>`, and a status-bar item renders
  the server's custom `flang/serverStatus` notification (compiler version,
  workspace folders, open projects with error counts). Phase 10 remains: flip
  the default flavor and retire the reference server.
- [x] 5. ModuleIndex + workspace/symbol

Phase 5 scope notes. `ModuleIndex` (`lib/flang_lsp/src/index.f`) holds what its
one consumer needs: name, kind, `decl_span`, container name - the
documentSymbol outline flattened. The §8 fields without a consumer yet
(rendered signature, doc comment, import edges, content-hash keying) arrive
with theirs - hover (phase 6) and the on-disk cache (out of scope). Indexes
live on `OpenProject` parallel to `unit.modules`, rebuilt whole after every
analysis (an AST walk, microseconds per module); only project-origin modules
are indexed, so workspace/symbol reports the user's own code, not the
stdlib's. Matching is ASCII case-insensitive substring - the client fuzzy-ranks
on top.
- [x] 6. hover, definition, typeDefinition, references
- [x] 7. inlayHint, signatureHelp

Phase 6-7 notes. Cursor-to-node is a linear scan over the span tables for
the innermost recorded span containing the offset
(`lib/flang_lsp/src/query.f`) - no AST-finder analogue needed. The base
tables are scanned first, then the specialization overlays: a generic
template's body is only checked per instantiation (into the overlay), so
inside a generic body answers carry one concrete instantiation's types, and
an uninstantiated template answers nothing.

Hover coverage beats the reference server by design: `let`/`for` binder
names and function/lambda parameters carry their own typed nodes (the
parser grew `LetStmt.name_span` / `ForStmt.var_span`; the checker records
the bound type there and points `RtLocal` at it, so goto on a read lands on
the name), and patterns, sub-patterns and match guards were already typed
per node. Hover is word-anchored: it answers only with a node that STARTS
at the identifier under the cursor and reports the identifier's range -
never a whole statement's - so annotations, keywords and `void`-typed
statement nodes answer null. Closed types only per §3, with one relaxation:
a free var carrying a declared type-parameter name (`checker.tp_names`,
threaded through the diagnostics renderer `format_with_names`) renders as
that name.

Variable hovers carry what brings the binding into scope: `let a: i32`,
`const n: usize`, `param q: i32`, `for v: i32`, `field x: i32` - the intro
comes off the module's binder list (matched by the declaration node's
span) and from the receiver-typed field lookup; type/function hovers stay
declaration slices.

Hover falls back to the same registry tier definition uses (stacked overload
labels, capped), so hover answers wherever goto does - a callee inside an
uninstantiated generic body included. Words that are binders in the
enclosing function suppress that fallback (and hover with their declared
annotation) so a param shadowing a global's name never shows the global.
Member position (`recv.word`) resolves through the receiver's type - the
typed node ending at the dot, looked up in the nominal registry - since the
checker records no target for field access; a member word only reaches the
registry fallback when call-shaped (UFCS methods are free functions).
`Enum.Variant` records one variant target spanning the whole reference, so
a cursor on the qualifier (the word a `.` follows) resolves the ENUM's
declaration, the member the variant's - in hover and definition both.

The server writes an access log to stderr when launched via `flang lsp`
(method + id per message in, plus handling time - never payloads), and the
per-parse CST is freed after projection (`free_cst`; it used to leak on
every keystroke - see known-issues on CST ownership).

§7's watcher-driven re-check is PARKED: `workspace/didChangeWatchedFiles`
events are dropped at the top of the handler (the code stays behind the
early return). Every agent write burst re-analyzed whole projects, and the
checker's per-re-demand leak (known-issues) balloons a long-lived server.
didSave still refreshes; disk-only edits stay stale until then. Un-park
together with the re-demand memory fix, adding §7's ~300 ms debounce in
the same pass.

Definition resolves in three tiers: resolved target at the cursor (locals,
params, functions, fields, variants, consts, specialized generics); then
the identifier under the cursor against the project's registries (nominal
FQN tails and function overload sets - stdlib and dependencies included);
then the ModuleIndex across the workspace for what registries don't hold -
template `#name`s, tests, consts. references inverts `resolved_targets`
(overlays included, deduped across instantiations), project-scoped; a
cursor on a function declaration falls back to the name's overload set.
signatureHelp works off the LIVE buffer (backward paren scan, registry
overload set by name, labels sliced from each declaration's own source up
to the body brace) since the analysis is stale exactly when it fires.
inlayHint walks the module AST for annotation-less `let`/`for` binders.
Types come from the last analysis; positions from the buffer the client
displays: when the live text has drifted, sites are re-derived from a
fresh parse of it and paired by name/order with the analyzed binders
(`live_hint_sites`), so ordinary edits keep every hint at its live offset
and only an added/removed/renamed binder drops the hints below it until
the next analysis. Every completed analysis sends
`workspace/inlayHint/refresh` so the client re-requests (a save changes no
buffer, so the client would otherwise keep stale hints).
Deferred: doc comments in hover (needs ModuleIndex doc-comment capture),
operator references (`resolved_ops` not inverted), cross-project
references.
- [ ] 8. completion
- [ ] 9. flang/generatedContent
- [ ] 10. extension switched to `flang lsp`

## Out of scope

- Sockets / HTTP in stdlib. stdio is what editors launch; a socket transport is
  a later `Reader`/`Writer` implementation.
- On-disk analysis cache (the index seam is built, the persistence is not).
- rename, codeAction, callHierarchy, semanticTokens, formatting - all post-v1.
  Formatting can import `lib/flang_fmt` (`format_source`) directly.
- Moving the extension into this repo.

## Open questions

1. Does go-to-generated resolve `flang-generated://` or a real file path? Decides
   whether phase 9 is a server feature or already working via `file://`.
2. RESOLVED: `textDocument/formatting` imports `lib/flang_fmt` directly
   (`format_source` over the live buffer, the project's `[fmt]` table
   applied when a manifest is reachable) - no shell-out, one
   whole-document TextEdit. The editor's default format shortcut works
   through the standard capability.
