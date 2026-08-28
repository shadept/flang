// The LSP server core: a single-threaded message loop over a Reader/Writer pair speaking
// std.rpc.jsonrpc, plus the lifecycle, document-sync, diagnostics and tier-1 feature handlers.
// Transport-agnostic - the `flang lsp` subcommand hands it stdin/stdout, tests hand it a MemReader
// and a StringBuilder.
//
// Analysis runs synchronously between messages: a didOpen of the first file under a `flang.toml`
// analyzes that whole project behind a `$/progress` spinner, a didSave re-checks it, and a
// keystroke gets parse-only (tier 1) diagnostics immediately. Requests never start analysis; they
// answer from the current buffers. With no stdlib path configured the server stays in tier-1-only
// mode (syntax diagnostics, symbols, folding) and never type-checks.
//
// Unknown requests get MethodNotFound, unknown notifications are dropped, both per JSON-RPC. `exit`
// ends the loop with code 0 when a `shutdown` request preceded it, 1 otherwise (LSP 3.17 exit
// semantics).

import std.dict
import std.encoding.codec
import std.encoding.json
import std.io.reader
import std.io.writer
import std.list
import std.option
import std.result
import std.rpc.jsonrpc
import std.set
import std.string
import std.string_builder
import std.string_reader
import std.test
import std.time
import std.io.file
import std.io.fs
import flang_core.diagnostic
import flang_core.span
import flang_analysis.analyze
import flang_analysis.project
import flang_analysis.resolver
import flang_fmt.fmt
import flang_typer.checker
import flang_typer.function_registry
import flang_typer.inference_results
import flang_typer.interner
import flang_typer.nominal_registry
import flang_typer.reporter
import flang_typer.result
import flang_lsp.documents
import flang_lsp.handlers.document_symbol
import flang_lsp.handlers.folding_range
import flang_lsp.handlers.inlay_hint
import flang_lsp.handlers.signature_help
import flang_lsp.handlers.syntax_diagnostics
import flang_lsp.index
import flang_lsp.line_index
import flang_lsp.query
import flang_lsp.uri
import flang_lsp.workspace

pub type LspServer = struct {
    reader: Reader
    writer: Writer
    docs: DocumentStore
    ws: Workspace
    version: OwnedString
    folders: List(OwnedString)
    encoding: PositionEncoding
    shutdown_requested: bool
    stdlib_warned: bool
    // Access logging to stderr: one line per message in and per message handled, method and id
    // only, never payloads. Off in tests; `flang lsp` turns it on.
    log_access: bool
    exit_code: i32?
    next_id: i64
}

pub fn lsp_server(r: Reader, w: Writer, stdlib_path: String = "", version: String = "0.0.0",
    log_access: bool = false) LspServer {
    return .{
        reader = r,
        writer = w,
        docs = document_store(),
        ws = workspace(stdlib_path),
        version = from_view(version),
        folders = list(0),
        encoding = PositionEncoding.Utf16,
        shutdown_requested = false,
        stdlib_warned = false,
        log_access = log_access,
        exit_code = null,
        next_id = 0,
    }
}

pub fn deinit(self: &LspServer) {
    self.folders.deinit()
    self.version.deinit()
    self.ws.deinit()
    self.docs.deinit()
}

// Serve until `exit` or the transport dies. Returns the process exit code.
pub fn run(self: &LspServer) i32 {
    loop {
        const got = read_message(self.reader)
        if got.is_err() {
            got.unwrap_err() match {
                BadJson | BadEnvelope => {
                    const nul = json_null()
                    write_error(self.writer, &nul, PARSE_ERROR, "invalid message")
                }
                else => {
                    // clean EOF or broken framing: the client is gone
                    return 1
                }
            }
            continue
        }
        let msg = got.unwrap()
        self.access_log("<-", &msg, null)
        const t0 = monotonic_ns()
        self.dispatch(&msg)
        self.access_log("->", &msg, Some((monotonic_ns() - t0) / 1000))
        msg.deinit()
        if self.exit_code.is_some() {
            return self.exit_code.unwrap()
        }
    }
    return 1
}

fn dispatch(self: &LspServer, msg: &RpcMessage) {
    const m = msg.method()
    if m.is_none() {
        return
    }
    m.unwrap() match {
        "initialize" => self.on_initialize(msg)
        "initialized" => self.send_status()
        "shutdown" => self.on_shutdown(msg)
        "exit" => self.on_exit()
        "textDocument/didOpen" => self.on_did_open(msg)
        "textDocument/didChange" => self.on_did_change(msg)
        "textDocument/didSave" => self.on_did_save(msg)
        "textDocument/didClose" => self.on_did_close(msg)
        "textDocument/documentSymbol" => self.on_document_symbol(msg)
        "textDocument/foldingRange" => self.on_folding_range(msg)
        "textDocument/hover" => self.on_hover(msg)
        "textDocument/definition" => self.on_definition(msg)
        "textDocument/typeDefinition" => self.on_type_definition(msg)
        "textDocument/references" => self.on_references(msg)
        "textDocument/inlayHint" => self.on_inlay_hint(msg)
        "textDocument/signatureHelp" => self.on_signature_help(msg)
        "textDocument/formatting" => self.on_formatting(msg)
        "workspace/symbol" => self.on_workspace_symbol(msg)
        "workspace/didChangeWatchedFiles" => self.on_watched_files(msg)
        else => self.on_unknown(msg)
    }
}

// One access-log line: `flang-lsp <- textDocument/hover #4` on arrival, the same with the handling
// time on completion. A client reply to a server-initiated request has no method and logs as
// `<reply>`.
fn access_log(self: &LspServer, dir: String, msg: &RpcMessage, elapsed_us: u64?) {
    if !self.log_access {
        return
    }
    let sb = string_builder(96)
    sb.append("flang-lsp ")
    sb.append(dir)
    sb.append(" ")
    sb.append(msg.method() ?? "<reply>")
    const id = msg.id()
    if id.is_some() {
        const n = id.unwrap().as_number()
        if n.is_some() {
            sb.append(" #")
            const nv: f64 = n.unwrap()
            sb.append(nv as i64)
        } else {
            sb.append(" #")
            sb.append(id.unwrap().as_string() ?? "?")
        }
    }
    elapsed_us match {
        Some(us) => {
            sb.append(" ")
            sb.append(us)
            sb.append("us")
        }
        None => {}
    }
    sb.append("\n")
    const _w = write(&stderr, sb.as_view())
    sb.deinit()
}

// ---- JSON param helpers ----

fn get_member(v: &JsonValue, name: String) &JsonValue? {
    return v.as_object() match {
        Some(o) => o.json_get_ref(name)
        None => null
    }
}

fn get_str(v: &JsonValue, name: String) String? {
    return get_member(v, name) match {
        Some(m) => m.as_string()
        None => null
    }
}

fn get_i64(v: &JsonValue, name: String) i64? {
    const m = get_member(v, name)
    if m.is_none() {
        return null
    }
    const n = m.unwrap().as_number()
    if n.is_none() {
        return null
    }
    const f: f64 = n.unwrap()
    const whole: i64 = f as i64
    return Some(whole)
}

// The `params.textDocument.uri` every textDocument request and notification carries.
fn doc_uri(msg: &RpcMessage) String? {
    const p = msg.params()
    if p.is_none() {
        return null
    }
    const td = get_member(p.unwrap(), "textDocument")
    if td.is_none() {
        return null
    }
    return get_str(td.unwrap(), "uri")
}

// ---- Raw JSON writing ----
//
// Payload-bearing messages (diagnostics, symbols, progress, status) are encoded straight into a
// StringBuilder envelope rather than built as JsonValue trees - the payloads are big and the tree
// would be allocated only to be serialized once.

fn envelope_notification(e: &Encoder, method: String) {
    e.begin_map(0)
    e.key("jsonrpc")
    e.encode_str("2.0")
    e.key("method")
    e.encode_str(method)
    e.key("params")
}

fn envelope_response(e: &Encoder, id: &JsonValue) {
    e.begin_map(0)
    e.key("jsonrpc")
    e.encode_str("2.0")
    e.key("id")
    id.serialize(e)
    e.key("result")
}

fn encode_pos(e: &Encoder, p: Position) {
    e.begin_map(0)
    e.key("line")
    e.encode_uint(p.line as u64, 8)
    e.key("character")
    e.encode_uint(p.character as u64, 8)
    e.end_map()
}

fn encode_span_range(e: &Encoder, idx: &LineIndex, text: String, span: SourceSpan,
    enc: PositionEncoding) {
    e.begin_map(0)
    e.key("start")
    encode_pos(e, idx.to_position(text, span.start, enc))
    e.key("end")
    encode_pos(e, idx.to_position(text, span.start + span.length, enc))
    e.end_map()
}

fn severity_code(s: Severity) i64 {
    return s match {
        Error => 1
        Warning => 2
        Info => 3
        Hint => 4
    }
}

fn encode_diag(e: &Encoder, idx: &LineIndex, text: String, d: &Diagnostic, enc: PositionEncoding) {
    e.begin_map(0)
    e.key("range")
    encode_span_range(e, idx, text, d.span, enc)
    e.key("severity")
    e.encode_int(severity_code(d.severity), 8)
    if d.code.len > 0 {
        e.key("code")
        e.encode_str(d.code)
    }
    e.key("source")
    e.encode_str("flang")
    e.key("message")
    if d.hint.as_view().len > 0 {
        const full = $"{d.message.as_view()}\n{d.hint.as_view()}"
        e.encode_str(full.as_view())
        full.deinit()
    } else {
        e.encode_str(d.message.as_view())
    }
    e.end_map()
}

// ---- Diagnostics publishing ----

// One publishDiagnostics notification for `uri`. A diagnostic without a location (none_span keeps
// start = 0) lands at the top of the file rather than being hidden.
fn publish_file_diags(self: &LspServer, uri: String, text: String, diags: &List(Diagnostic)) {
    let idx = line_index(text)
    defer idx.deinit()
    let sb = string_builder(512)
    defer sb.deinit()
    let jenc = json_encoder(sb.writer())
    let e = jenc.encoder()
    envelope_notification(&e, "textDocument/publishDiagnostics")
    e.begin_map(0)
    e.key("uri")
    e.encode_str(uri)
    e.key("diagnostics")
    e.begin_seq(diags.len)
    for &d in diags {
        encode_diag(&e, &idx, text, d, self.encoding)
    }
    e.end_seq()
    e.end_map()
    e.end_map()
    write_frame(self.writer, sb.as_view())
}

// Parse-only diagnostics for one open buffer - the per-keystroke path.
fn publish_syntax_diags(self: &LspServer, uri: String) {
    const doc = self.docs.get(uri)
    if doc.is_none() {
        return
    }
    let parsed = parse_doc(doc.unwrap().text.as_view())
    self.publish_file_diags(uri, doc.unwrap().text.as_view(), &parsed.diagnostics)
    parsed.deinit()
}

// The client's URI for `path`: the open document's own spelling when the file is open (so the
// publish lands on the exact buffer), a freshly encoded one otherwise.
fn uri_for_path(self: &LspServer, path: String) OwnedString {
    for entry in self.docs.docs.iter() {
        if entry.value.path.as_view() == path {
            return from_view(entry.key.as_view())
        }
    }
    return path_to_uri(path)
}

// Publish every project-origin file's diagnostics, including empty lists - that is what clears a
// fixed error on the client.
fn publish_project(self: &LspServer, pi: ProjectId) {
    const unit = &self.ws.projects[pi].unit
    for fid in 0..unit.modules.len {
        if fid >= unit.project_origin.len or !unit.project_origin[fid] {
            continue
        }
        let file_diags: List(Diagnostic) = list(0)
        for &d in unit.diagnostics {
            if d.span.file_id == fid as i32 {
                // shallow copy: Diagnostic owns nothing that a List teardown frees
                file_diags.push(d.*)
            }
        }
        const u = self.uri_for_path(unit.file_paths[fid].as_view())
        self.publish_file_diags(u.as_view(), unit.sources[fid].as_view(), &file_diags)
        u.deinit()
        file_diags.deinit()
    }
}

// ---- $/progress ----

// Server-initiated progress: create the token, then begin. The create response is read and dropped
// by the message loop like any other client response.
fn progress_begin(self: &LspServer, title: String) OwnedString {
    self.next_id = self.next_id + 1
    const token = $"flang-{self.next_id}"

    let params = json_object()
    params.as_object().unwrap().json_set("token", json_string(token.as_view()))
    write_request(self.writer, self.next_id, "window/workDoneProgress/create", Some(&params))
    params.deinit()

    let sb = string_builder(256)
    defer sb.deinit()
    let jenc = json_encoder(sb.writer())
    let e = jenc.encoder()
    envelope_notification(&e, "$/progress")
    e.begin_map(0)
    e.key("token")
    e.encode_str(token.as_view())
    e.key("value")
    e.begin_map(0)
    e.key("kind")
    e.encode_str("begin")
    e.key("title")
    e.encode_str(title)
    e.end_map()
    e.end_map()
    e.end_map()
    write_frame(self.writer, sb.as_view())
    return token
}

fn progress_end(self: &LspServer, token: String) {
    let sb = string_builder(128)
    defer sb.deinit()
    let jenc = json_encoder(sb.writer())
    let e = jenc.encoder()
    envelope_notification(&e, "$/progress")
    e.begin_map(0)
    e.key("token")
    e.encode_str(token)
    e.key("value")
    e.begin_map(0)
    e.key("kind")
    e.encode_str("end")
    e.end_map()
    e.end_map()
    e.end_map()
    write_frame(self.writer, sb.as_view())
}

// ---- flang/serverStatus ----

// Custom notification for the editor's status-bar item: compiler version, workspace folder names,
// and every open project with its current error count.
fn send_status(self: &LspServer) {
    let sb = string_builder(512)
    defer sb.deinit()
    let jenc = json_encoder(sb.writer())
    let e = jenc.encoder()
    envelope_notification(&e, "flang/serverStatus")
    e.begin_map(0)
    e.key("version")
    e.encode_str(self.version.as_view())
    e.key("folders")
    e.begin_seq(self.folders.len)
    for &f in self.folders {
        e.encode_str(f.as_view())
    }
    e.end_seq()
    e.key("projects")
    e.begin_seq(self.ws.projects.len)
    for &p in self.ws.projects {
        e.begin_map(0)
        e.key("name")
        e.encode_str(p.name.as_view())
        e.key("dir")
        e.encode_str(p.dir.as_view())
        e.key("errors")
        e.encode_uint(project_error_count(&p.unit) as u64, 8)
        e.end_map()
    }
    e.end_seq()
    e.end_map()
    e.end_map()
    write_frame(self.writer, sb.as_view())
}

// ---- Lifecycle ----

// The client's `general.positionEncodings` is a preference-ordered list; any occurrence of utf-8
// selects the byte-offset fast path. Absent or without utf-8 (VS Code), utf-16 is the mandatory
// default.
fn negotiate_encoding(params: &JsonValue?) PositionEncoding {
    if params.is_none() {
        return PositionEncoding.Utf16
    }
    const caps = get_member(params.unwrap(), "capabilities")
    if caps.is_none() {
        return PositionEncoding.Utf16
    }
    const general = get_member(caps.unwrap(), "general")
    if general.is_none() {
        return PositionEncoding.Utf16
    }
    const encodings = get_member(general.unwrap(), "positionEncodings")
    if encodings.is_none() {
        return PositionEncoding.Utf16
    }
    const arr = encodings.unwrap().as_array()
    if arr.is_none() {
        return PositionEncoding.Utf16
    }
    const items = arr.unwrap()
    for i in 0..items.len {
        const entry = &items[i]
        const s = entry.as_string()
        if s.is_some() and s.unwrap() == "utf-8" {
            return PositionEncoding.Utf8
        }
    }
    return PositionEncoding.Utf16
}

// Workspace folder names, for the status notification. `workspaceFolders` when present, else the
// last segment of `rootUri`'s path.
fn collect_folders(self: &LspServer, params: &JsonValue?) {
    if params.is_none() {
        return
    }
    const wf = get_member(params.unwrap(), "workspaceFolders")
    if wf.is_some() {
        const arr = wf.unwrap().as_array()
        if arr.is_some() {
            const items = arr.unwrap()
            for i in 0..items.len {
                const name = get_str(&items[i], "name")
                if name.is_some() {
                    self.folders.push(from_view(name.unwrap()))
                }
            }
        }
    }
    if self.folders.len > 0 {
        return
    }
    const root = get_str(params.unwrap(), "rootUri")
    if root.is_none() {
        return
    }
    const path = uri_to_path(root.unwrap())
    if path.is_none() {
        return
    }
    const p = path.unwrap()
    const cut = rfind(p.as_view(), '/')
    const name = cut match {
        Some(i) => p.as_view()[(i + 1)..p.as_view().len]
        None => p.as_view()
    }
    if name.len > 0 {
        self.folders.push(from_view(name))
    }
    p.deinit()
}

fn initialize_result(self: &LspServer) JsonValue {
    let sync = json_object()
    sync.as_object().unwrap().json_set("openClose", json_bool(true))
    sync.as_object().unwrap().json_set("change", json_number(1.0)) // TextDocumentSyncKind.Full
    sync.as_object().unwrap().json_set("save", json_bool(true))

    let caps = json_object()
    const enc_name = if is_utf8_encoding(self.encoding) { "utf-8" } else { "utf-16" }
    caps.as_object().unwrap().json_set("positionEncoding", json_string(enc_name))
    caps.as_object().unwrap().json_set("textDocumentSync", sync)
    caps.as_object().unwrap().json_set("documentSymbolProvider", json_bool(true))
    caps.as_object().unwrap().json_set("foldingRangeProvider", json_bool(true))
    caps.as_object().unwrap().json_set("workspaceSymbolProvider", json_bool(true))
    caps.as_object().unwrap().json_set("hoverProvider", json_bool(true))
    caps.as_object().unwrap().json_set("definitionProvider", json_bool(true))
    caps.as_object().unwrap().json_set("typeDefinitionProvider", json_bool(true))
    caps.as_object().unwrap().json_set("referencesProvider", json_bool(true))
    caps.as_object().unwrap().json_set("inlayHintProvider", json_bool(true))
    caps.as_object().unwrap().json_set("documentFormattingProvider", json_bool(true))
    let trig = json_array()
    trig.as_array().unwrap().push(json_string("("))
    trig.as_array().unwrap().push(json_string(","))
    let sig = json_object()
    sig.as_object().unwrap().json_set("triggerCharacters", trig)
    caps.as_object().unwrap().json_set("signatureHelpProvider", sig)

    let info = json_object()
    info.as_object().unwrap().json_set("name", json_string("flang-lsp"))
    info.as_object().unwrap().json_set("version", json_string(self.version.as_view()))

    let root = json_object()
    root.as_object().unwrap().json_set("capabilities", caps)
    root.as_object().unwrap().json_set("serverInfo", info)
    return root
}

fn is_utf8_encoding(enc: PositionEncoding) bool {
    return enc match { Utf8 => true, else => false }
}

fn on_initialize(self: &LspServer, msg: &RpcMessage) {
    self.encoding = negotiate_encoding(msg.params())
    self.collect_folders(msg.params())
    if msg.id().is_none() {
        return
    }
    let result = self.initialize_result()
    defer result.deinit()
    write_response(self.writer, msg.id().unwrap(), &result)
}

fn on_shutdown(self: &LspServer, msg: &RpcMessage) {
    self.shutdown_requested = true
    if msg.id().is_some() {
        const nul = json_null()
        write_response(self.writer, msg.id().unwrap(), &nul)
    }
}

fn on_exit(self: &LspServer) {
    self.exit_code = Some(if self.shutdown_requested { 0 } else { 1 })
}

fn on_unknown(self: &LspServer, msg: &RpcMessage) {
    if msg.is_request() {
        write_error(self.writer, msg.id().unwrap(), METHOD_NOT_FOUND, "unknown method")
    }
}

// ---- Document sync ----

fn on_did_open(self: &LspServer, msg: &RpcMessage) {
    const p = msg.params()
    if p.is_none() {
        return
    }
    const td = get_member(p.unwrap(), "textDocument")
    if td.is_none() {
        return
    }
    const uri = get_str(td.unwrap(), "uri")
    const text = get_str(td.unwrap(), "text")
    if uri.is_none() or text.is_none() {
        return
    }
    const version = get_i64(td.unwrap(), "version") ?? 0
    self.docs.open(uri.unwrap(), version, text.unwrap())

    self.publish_syntax_diags(uri.unwrap())
    const doc = self.docs.get(uri.unwrap())
    if doc.is_some() and doc.unwrap().path.as_view().len > 0 {
        self.ensure_project(doc.unwrap().path.as_view())
    }
}

fn on_did_change(self: &LspServer, msg: &RpcMessage) {
    const p = msg.params()
    if p.is_none() {
        return
    }
    const td = get_member(p.unwrap(), "textDocument")
    if td.is_none() {
        return
    }
    const uri = get_str(td.unwrap(), "uri")
    if uri.is_none() {
        return
    }
    const version = get_i64(td.unwrap(), "version") ?? 0

    const changes = get_member(p.unwrap(), "contentChanges")
    if changes.is_none() {
        return
    }
    const arr = changes.unwrap().as_array()
    if arr.is_none() {
        return
    }
    // Full sync: each element is a whole-document replacement; the last wins.
    const items = arr.unwrap()
    let text: String? = null
    for i in 0..items.len {
        const entry = &items[i]
        const t = get_str(entry, "text")
        if t.is_some() {
            text = t
        }
    }
    if text.is_none() {
        return
    }
    self.docs.change(uri.unwrap(), version, text.unwrap())
    // Parse-only feedback while typing; the type tier catches up on save.
    self.publish_syntax_diags(uri.unwrap())
}

fn on_did_save(self: &LspServer, msg: &RpcMessage) {
    const uri = doc_uri(msg)
    if uri.is_none() {
        return
    }
    const doc = self.docs.get(uri.unwrap())
    if doc.is_none() or doc.unwrap().path.as_view().len == 0 {
        return
    }
    const path = doc.unwrap().path.as_view()

    const pi = self.ws.project_of_path(path)
    if pi.is_none() {
        // A manifest may have appeared since the open (or the open never analyzed).
        self.ensure_project(path)
        return
    }
    self.recheck_project(pi.unwrap(), path)
}

fn on_did_close(self: &LspServer, msg: &RpcMessage) {
    const uri = doc_uri(msg)
    if uri.is_none() {
        return
    }
    self.docs.close(uri.unwrap())
}

// ---- Analysis driving ----

// Whether type-level analysis is available at all. Without a stdlib root every import would fail to
// resolve and diagnostics would be pure noise, so the server stays tier-1-only. A configured root
// that does not exist on disk gets the same treatment, plus a one-time editor warning.
fn can_analyze(self: &LspServer) bool {
    const root = self.ws.stdlib_path.as_view()
    if root.len == 0 {
        return false
    }
    if exists(root) {
        return true
    }
    self.warn_stdlib_missing()
    return false
}

fn warn_stdlib_missing(self: &LspServer) {
    if self.stdlib_warned {
        return
    }
    self.stdlib_warned = true
    let sb = string_builder(256)
    defer sb.deinit()
    let jenc = json_encoder(sb.writer())
    let e = jenc.encoder()
    envelope_notification(&e, "window/showMessage")
    e.begin_map(0)
    e.key("type")
    e.encode_int(2, 8) // MessageType.Warning
    e.key("message")
    const msg = $"FLang: stdlib not found at `{self.ws.stdlib_path.as_view()}`; type checking is disabled. Set flang.stdlibPath or pass -s."
    e.encode_str(msg.as_view())
    msg.deinit()
    e.end_map()
    e.end_map()
    write_frame(self.writer, sb.as_view())
}

// First contact with a file: analyze its project when no open project claims it yet.
fn ensure_project(self: &LspServer, path: String) {
    if !self.can_analyze() {
        return
    }
    if self.ws.project_of_path(path).is_some() {
        return
    }
    const dir = project_dir_for(path)
    if dir.is_none() {
        return
    }
    const d = dir.unwrap()

    const base = rfind(d.as_view(), '/') match {
        Some(i) => d.as_view()[(i + 1)..d.as_view().len]
        None => d.as_view()
    }
    const title = $"FLang: checking {base}"
    const token = self.progress_begin(title.as_view())
    title.deinit()
    const idx = open_project(&self.ws, d.as_view(), &self.docs)
    self.progress_end(token.as_view())
    token.deinit()
    d.deinit()

    if idx.is_some() {
        self.publish_project(idx.unwrap())
        self.send_status()
        self.request_hint_refresh()
    }
}

// Re-check one open project with `dirty_path` re-parsed, then republish and refresh the status.
fn recheck_project(self: &LspServer, pi: ProjectId, dirty_path: String) {
    let dirty: Set(String) = set()
    dirty.add(dirty_path)
    self.recheck_with(pi, &dirty)
    dirty.deinit()
}

fn recheck_with(self: &LspServer, pi: ProjectId, dirty: &Set(String)) {
    const title = $"FLang: checking {self.ws.projects[pi].name.as_view()}"
    const token = self.progress_begin(title.as_view())
    title.deinit()
    reanalyze_project(&self.ws, pi, dirty, &self.docs)
    self.progress_end(token.as_view())
    token.deinit()
    self.publish_project(pi)
    self.send_status()
    self.request_hint_refresh()
}

// ---- Watched files ----

// Disk changes from the client's file watcher. Open buffers win over disk, so a change to an open
// file is ignored here (didChange already delivered it). A changed `.f` re-checks its project; a
// created or deleted `.f`, or any `flang.toml` event, rebuilds the project whole (the module set
// changed).
fn on_watched_files(self: &LspServer, msg: &RpcMessage) {
    // ponytail: events dropped, parking RFC-023 §7's watcher-driven re-check - every agent write
    // burst re-analyzed whole projects, and the checker's per-re-demand leak (known-issues.md
    // "Checker leaks ...") balloons the server. didSave still refreshes; disk-only edits stay
    // stale until then. Remove this return once re-demand memory is fixed (add §7's debounce in
    // the same pass).
    return

    if !self.can_analyze() {
        return
    }
    const p = msg.params()
    if p.is_none() {
        return
    }
    const changes = get_member(p.unwrap(), "changes")
    if changes.is_none() {
        return
    }
    const arr = changes.unwrap().as_array()
    if arr.is_none() {
        return
    }

    let reopen = filled_list(self.ws.projects.len, false)
    defer reopen.deinit()
    let touched: List(OwnedString) = list(0)
    defer touched.deinit()
    let touched_owner: List(usize) = list(0)
    defer touched_owner.deinit()

    const items = arr.unwrap()
    for i in 0..items.len {
        const u = get_str(&items[i], "uri")
        if u.is_none() {
            continue
        }
        const kind = get_i64(&items[i], "type") ?? 2
        const got = uri_to_path(u.unwrap())
        if got.is_none() {
            continue
        }
        let path = got.unwrap()

        if ends_with(path.as_view(), "/flang.toml") {
            const owner = self.ws.find_project(parent_dir(path.as_view()))
            if owner.is_some() {
                reopen[owner.unwrap()] = true
            }
            path.deinit()
            continue
        }

        const owner = self.ws.project_of_path(path.as_view())
        if owner.is_none() {
            path.deinit()
            continue
        }
        if kind != 2 {
            // Created or Deleted: the module set changed.
            reopen[owner.unwrap()] = true
            path.deinit()
            continue
        }
        if self.is_open_path(path.as_view()) {
            path.deinit()
            continue
        }
        touched_owner.push(owner.unwrap())
        touched.push(path)
    }

    for pi in 0..self.ws.projects.len {
        if reopen[pi] {
            const title = $"FLang: checking {self.ws.projects[pi].name.as_view()}"
            const token = self.progress_begin(title.as_view())
            title.deinit()
            const ok = reopen_project(&self.ws, pi, &self.docs)
            self.progress_end(token.as_view())
            token.deinit()
            if ok {
                self.publish_project(pi)
                self.send_status()
                self.request_hint_refresh()
            }
            continue
        }
        let dirty: Set(String) = set()
        for i in 0..touched.len {
            if touched_owner[i] == pi {
                dirty.add(touched[i].as_view())
            }
        }
        if dirty.len() > 0 {
            self.recheck_with(pi, &dirty)
        }
        dirty.deinit()
    }
}

fn is_open_path(self: &LspServer, path: String) bool {
    for entry in self.docs.docs.iter() {
        if entry.value.path.as_view() == path {
            return true
        }
    }
    return false
}

// ---- Tier-1 requests ----

fn on_document_symbol(self: &LspServer, msg: &RpcMessage) {
    if !msg.is_request() {
        return
    }
    const uri = doc_uri(msg)
    let sb = string_builder(1024)
    defer sb.deinit()
    let jenc = json_encoder(sb.writer())
    let e = jenc.encoder()
    envelope_response(&e, msg.id().unwrap())

    const doc = if uri.is_some() { self.docs.get(uri.unwrap()) } else { null }
    if doc.is_none() {
        e.encode_null()
    } else {
        const text = doc.unwrap().text.as_view()
        let parsed = parse_doc(text)
        let syms = document_symbols(&parsed.module)
        encode_symbols(&e, &syms, &doc.unwrap().index, text, self.encoding)
        syms.deinit()
        parsed.deinit()
    }
    e.end_map()
    write_frame(self.writer, sb.as_view())
}

fn encode_symbols(e: &Encoder, syms: &List(DocSymbol), idx: &LineIndex, text: String,
    enc: PositionEncoding) {
    e.begin_seq(syms.len)
    for &s in syms {
        e.begin_map(0)
        e.key("name")
        e.encode_str(s.name.as_view())
        e.key("kind")
        e.encode_int(s.kind as i64, 8)
        e.key("range")
        encode_span_range(e, idx, text, s.span, enc)
        e.key("selectionRange")
        encode_span_range(e, idx, text, s.span, enc)
        if s.children.len > 0 {
            e.key("children")
            encode_symbols(e, &s.children, idx, text, enc)
        }
        e.end_map()
    }
    e.end_seq()
}

fn on_folding_range(self: &LspServer, msg: &RpcMessage) {
    if !msg.is_request() {
        return
    }
    const uri = doc_uri(msg)
    let sb = string_builder(512)
    defer sb.deinit()
    let jenc = json_encoder(sb.writer())
    let e = jenc.encoder()
    envelope_response(&e, msg.id().unwrap())

    const doc = if uri.is_some() { self.docs.get(uri.unwrap()) } else { null }
    if doc.is_none() {
        e.encode_null()
    } else {
        let folds = folding_ranges(doc.unwrap().text.as_view())
        e.begin_seq(folds.len)
        for &f in folds {
            e.begin_map(0)
            e.key("startLine")
            e.encode_uint(f.start_line as u64, 8)
            e.key("endLine")
            e.encode_uint(f.end_line as u64, 8)
            e.end_map()
        }
        e.end_seq()
        folds.deinit()
    }
    e.end_map()
    write_frame(self.writer, sb.as_view())
}

// ---- workspace/symbol ----

// Name-level search over every open project's ModuleIndex - the cross-file query path (RFC-023
// §8). Answers from the last analysis; the index refreshes on save and watcher events, like the
// type tier.
fn on_workspace_symbol(self: &LspServer, msg: &RpcMessage) {
    if !msg.is_request() {
        return
    }
    const p = msg.params()
    const query = if p.is_some() { get_str(p.unwrap(), "query") ?? "" } else { "" }

    let sb = string_builder(1024)
    defer sb.deinit()
    let jenc = json_encoder(sb.writer())
    let e = jenc.encoder()
    envelope_response(&e, msg.id().unwrap())
    e.begin_seq(0)
    for pi in 0..self.ws.projects.len {
        self.encode_project_symbols(&e, pi, query)
    }
    e.end_seq()
    e.end_map()
    write_frame(self.writer, sb.as_view())
}

// SymbolInformation entries for one project's matches, grouped by file so the line index and URI
// are built once per file that has any.
fn encode_project_symbols(self: &LspServer, e: &Encoder, pi: ProjectId, query: String) {
    const unit = &self.ws.projects[pi].unit
    const index = &self.ws.projects[pi].index
    for fid in 0..index.len {
        let any = false
        for &s in index[fid].symbols {
            if symbol_matches(s.name.as_view(), query) {
                any = true
            }
        }
        if !any {
            continue
        }

        const text = unit.sources[fid].as_view()
        let lidx = line_index(text)
        const u = self.uri_for_path(unit.file_paths[fid].as_view())
        for &s in index[fid].symbols {
            if !symbol_matches(s.name.as_view(), query) {
                continue
            }
            e.begin_map(0)
            e.key("name")
            e.encode_str(s.name.as_view())
            e.key("kind")
            e.encode_int(s.kind as i64, 8)
            if s.container.as_view().len > 0 {
                e.key("containerName")
                e.encode_str(s.container.as_view())
            }
            e.key("location")
            e.begin_map(0)
            e.key("uri")
            e.encode_str(u.as_view())
            e.key("range")
            encode_span_range(e, &lidx, text, s.span, self.encoding)
            e.end_map()
            e.end_map()
        }
        u.deinit()
        lidx.deinit()
    }
}

// ---- Cursor-request plumbing (hover, definition, references, hints) ----

// The analyzed context behind a positional request: which open project the document belongs to and
// its file id inside that project's unit. Null when the file is not part of any analyzed project -
// the request then answers null/empty rather than guessing.
type ReqCtx = struct {
    pi: ProjectId
    fid: i32
}

fn request_ctx(self: &LspServer, msg: &RpcMessage) ReqCtx? {
    const uri = doc_uri(msg)
    if uri.is_none() {
        return null
    }
    const doc = self.docs.get(uri.unwrap())
    if doc.is_none() or doc.unwrap().path.as_view().len == 0 {
        return null
    }
    const pi = self.ws.project_of_path(doc.unwrap().path.as_view())
    if pi.is_none() {
        return null
    }
    const fid = file_id_of(&self.ws.projects[pi.unwrap()].unit, doc.unwrap().path.as_view())
    if fid.is_none() {
        return null
    }
    return Some(ReqCtx { pi = pi.unwrap(), fid = fid.unwrap() })
}

// A `{line, character}` object as a Position, or null when either field is missing.
fn pos_of(v: &JsonValue) Position? {
    const line = get_i64(v, "line")
    const ch = get_i64(v, "character")
    if line.is_none() or ch.is_none() {
        return null
    }
    const l: i64 = line.unwrap()
    const c: i64 = ch.unwrap()
    return Some(Position { line = (l as u32), character = (c as u32) })
}

// `params.position`, or null.
fn req_position(msg: &RpcMessage) Position? {
    const p = msg.params()
    if p.is_none() {
        return null
    }
    return get_member(p.unwrap(), "position") match {
        Some(v) => pos_of(v)
        None => null
    }
}

// The analyzed context plus the request's cursor offset, the opening move of every positional
// handler. The offset indexes the ANALYZED source of `fid`, so answers stay consistent with the
// last analysis even when it trails unsaved keystrokes (the type tier catches up on save).
type Cursor = struct {
    pi: ProjectId
    fid: i32
    offset: usize
}

fn cursor_at(self: &LspServer, msg: &RpcMessage) Cursor? {
    const ctx = self.request_ctx(msg)
    const pos = req_position(msg)
    if ctx.is_none() or pos.is_none() {
        return null
    }
    const pi = ctx.unwrap().pi
    const fid = ctx.unwrap().fid
    const text = self.ws.projects[pi].unit.sources[fid as usize].as_view()
    let idx = line_index(text)
    const off = idx.to_offset(text, pos.unwrap(), self.encoding)
    idx.deinit()
    return Some(Cursor { pi = pi, fid = fid, offset = off })
}

fn respond_null(self: &LspServer, msg: &RpcMessage) {
    const nul = json_null()
    write_response(self.writer, msg.id().unwrap(), &nul)
}

// One LSP Location for `span`, resolved inside project `pi` (the span's file id indexes that
// project's unit).
fn encode_span_location(self: &LspServer, e: &Encoder, pi: ProjectId, span: SourceSpan) {
    const unit = &self.ws.projects[pi].unit
    const fid = span.file_id as usize
    const text = unit.sources[fid].as_view()
    let idx = line_index(text)
    const u = self.uri_for_path(unit.file_paths[fid].as_view())
    e.begin_map(0)
    e.key("uri")
    e.encode_str(u.as_view())
    e.key("range")
    encode_span_range(e, &idx, text, span, self.encoding)
    e.end_map()
    u.deinit()
    idx.deinit()
}

fn location_span_ok(self: &LspServer, pi: ProjectId, span: SourceSpan) bool {
    if span.file_id < 0 {
        return false
    }
    return (span.file_id as usize) < self.ws.projects[pi].unit.sources.len
}

// The declaration's source text from its span start to the body brace (or the span end for bodiless
// declarations), trailing whitespace trimmed - the hover/signature label for a function.
fn decl_label(self: &LspServer, pi: ProjectId, span: SourceSpan) String? {
    if !self.location_span_ok(pi, span) {
        return null
    }
    const text = self.ws.projects[pi].unit.sources[span.file_id as usize].as_view()
    let end = span.start + span.length
    if end > text.len {
        end = text.len
    }
    let i = span.start
    while i < end {
        if text[i] == '{' {
            end = i
            break
        }
        i = i + 1
    }
    while end > span.start and (text[end - 1] == ' ' or text[end - 1] == '\n'
        or text[end - 1] == '\r' or text[end - 1] == '\t') {
        end = end - 1
    }
    if end <= span.start {
        return null
    }
    return Some(text[span.start..end])
}

// What brings the binding declared at exactly `span` into scope - `let`, `const`, `param`, `for` -
// or null when no binder's name node sits there. The returned string is a literal, safe past the
// binder list's teardown.
fn binder_intro(self: &LspServer, pi: ProjectId, span: SourceSpan) String? {
    const unit = &self.ws.projects[pi].unit
    if span.file_id < 0 or span.file_id as usize >= unit.modules.len {
        return null
    }
    let bs = module_binders(&unit.modules[span.file_id as usize])
    let out: String? = null
    for &b in bs {
        if b.name_span.file_id == span.file_id and b.name_span.start == span.start
            and b.name_span.length == span.length {
            out = Some(b.intro)
            break
        }
    }
    bs.deinit()
    return out
}

// ---- textDocument/hover ----

// Hover is word-anchored: it answers only when the cursor sits on an identifier, from the innermost
// recorded node that STARTS at that identifier (the binder's name node, the param slot, the
// callee's call node), and it reports the identifier's range - never a whole statement's. A
// function target renders its declaration slice, anything else its checked type. Void never
// answers; inside a generic body free signature vars render by their declared `$T` names.
fn on_hover(self: &LspServer, msg: &RpcMessage) {
    if !msg.is_request() {
        return
    }
    const cur = self.cursor_at(msg)
    if cur.is_none() {
        self.respond_null(msg)
        return
    }
    const pi = cur.unwrap().pi
    const fid = cur.unwrap().fid
    const offset = cur.unwrap().offset
    const unit = &self.ws.projects[pi].unit
    const result = &unit.result
    const text = unit.sources[fid as usize].as_view()

    const word = identifier_at(text, offset)
    if word.is_none() {
        self.respond_null(msg)
        return
    }
    const wstart = word.unwrap().start
    const wname = word.unwrap().name

    const tg = target_at(result, fid, offset)
    const th = typed_at(result, fid, offset)

    let label: OwnedString? = null

    // A resolved target answers when its node is anchored to the word: starting at it (reads,
    // callees), ending at it (enum variant refs `Color.Red`), or - for function targets only -
    // containing it with a matching name (a UFCS call node spans the receiver too). Locals fall
    // through to the typed branch, whose `name: T` form beats a declaration slice.
    if tg.is_some() {
        const target = tg.unwrap().target
        const tspan = tg.unwrap().span
        const wend = wstart + wname.len
        let accept = tspan.start == wstart or tspan.start + tspan.length == wend
        if !accept {
            accept = target match {
                RtFunction(id) => result.functions.find_by_id(id) match {
                    Some(s) => s.name == wname
                    None => false
                }
                RtSpecialized(sid) => result.specializations.specs.get_ref(sid) match {
                    Some(sp) => sp.name == wname
                    None => false
                }
                _ => false
            }
        }
        const is_local = target match {
            RtLocal(_) => true
            _ => false
        }
        if accept and !is_local {
            const dspan = cursor_decl_span(result, &tg.unwrap(), text, wstart, wend)
            if dspan.is_some() and self.location_span_ok(pi, dspan.unwrap()) {
                const l = self.decl_label(pi, dspan.unwrap())
                if l.is_some() {
                    label = Some(from_view(l.unwrap()))
                }
            }
        }
    }

    if label.is_none() and th.is_some() and th.unwrap().span.start == wstart {
        const ty = th.unwrap().ty
        const vars = type_param_names(&unit.checker)
        if renderable_ty(result, ty, vars) and !is_void_ty(result, ty) {
            const rendered = render_ty(result, ty, Some(vars))
            // What brings the binding into scope prefixes the hover (`param q: i32`): the hovered
            // node is the binder itself, or the read's RtLocal target points at it.
            let intro = self.binder_intro(pi, th.unwrap().span)
            if intro.is_none() and tg.is_some() {
                tg.unwrap().target match {
                    RtLocal(n) => {
                        const ds = span_of_node(result, n)
                        if ds.is_some() {
                            intro = self.binder_intro(pi, ds.unwrap())
                        }
                    }
                    _ => {}
                }
            }
            if intro.is_some() {
                label = Some($"{intro.unwrap()} {wname}: {rendered.as_view()}")
                rendered.deinit()
            } else if th.unwrap().span.length == wname.len {
                label = Some($"{wname}: {rendered.as_view()}")
                rendered.deinit()
            } else {
                label = Some(rendered)
            }
        }
    }

    const span = SourceSpan { file_id = fid, start = wstart, length = wname.len }

    // Member position (`recv.word`): the checker records no target for field access, so resolve the
    // receiver's type - the node ending at the dot - and look the field up in the nominal registry.
    // A member word that is not a field falls through (a UFCS method already answered above).
    let is_member = wstart > 0 and text[wstart - 1] == '.'
    if label.is_none() and is_member {
        const fh = member_at(result, fid, text, wstart, wname)
        if fh.is_some() {
            const vars = type_param_names(&unit.checker)
            const rendered = render_ty(result, fh.unwrap().ty, Some(vars))
            label = Some($"field {wname}: {rendered.as_view()}")
            rendered.deinit()
        }
    }

    // A body no checker table covers (an uninstantiated generic template): a binder declared in the
    // enclosing function still hovers with its annotation text, and its existence suppresses the
    // registry fallback below - the word names the local, not some same-named global.
    let is_binder = false
    if label.is_none() and (fid as usize) < unit.modules.len {
        let binders = module_binders(&unit.modules[fid as usize])
        for &b in binders {
            if b.name != wname or !span_contains(b.owner, offset) {
                continue
            }
            is_binder = true
            const ann = b.annotation
            if ann.is_none() or !self.location_span_ok(pi, ann.unwrap()) {
                continue
            }
            const a = ann.unwrap()
            if a.length == 0 {
                continue
            }
            const slice = text[a.start..(a.start + a.length)]
            label = Some($"{b.intro} {wname}: {slice}")
            break
        }
        binders.deinit()
    }

    // Name-level fallback, mirroring definition's registry tier, so hover answers wherever goto
    // does - a callee inside an uninstantiated generic body included (no overlay exists for it). A
    // member word only qualifies when call-shaped: a UFCS method IS a free function, but a plain
    // `.field` matching a same-named global would mislead.
    if label.is_none() and !is_binder {
        const wend = wstart + wname.len
        const call_shaped = wend < text.len and text[wend] == '('
        if !is_member or call_shaped {
            label = self.registry_hover(pi, wname)
        }
    }

    if label.is_none() {
        self.respond_null(msg)
        return
    }

    let sb = string_builder(512)
    defer sb.deinit()
    let jenc = json_encoder(sb.writer())
    let e = jenc.encoder()
    envelope_response(&e, msg.id().unwrap())
    e.begin_map(0)
    e.key("contents")
    e.begin_map(0)
    e.key("kind")
    e.encode_str("markdown")
    e.key("value")
    const md = $"```flang\n{label.unwrap().as_view()}\n```"
    e.encode_str(md.as_view())
    md.deinit()
    e.end_map()
    e.key("range")
    let lidx = line_index(text)
    encode_span_range(&e, &lidx, text, span, self.encoding)
    lidx.deinit()
    e.end_map()
    e.end_map()
    write_frame(self.writer, sb.as_view())
    label.unwrap().deinit()
}

// Every declaration named `name` in project `pi`'s registries: the function overload set, then
// nominal types matched on their FQN's last segment. Stdlib and dependencies included, which the
// project-origin-only ModuleIndex cannot cover. The name-level tier of both hover and definition.
fn registry_decl_spans(self: &LspServer, pi: ProjectId, name: String) List(SourceSpan) {
    const result = &self.ws.projects[pi].unit.result
    let out: List(SourceSpan) = list(4)
    const overloads = result.functions.by_name.get_ref(name)
    if overloads.is_some() {
        for &s in overloads.unwrap() {
            if !s.retired and self.location_span_ok(pi, s.decl_span) {
                out.push(s.decl_span)
            }
        }
    }
    for entry in result.nominals.by_fqn.iter() {
        if short_name(entry.key) != name {
            continue
        }
        const def = result.nominals.find(entry.value)
        if def.is_none() {
            continue
        }
        const span = def.unwrap().* match {
            NomStruct(sd) => sd.decl_span
            NomEnum(ed) => ed.decl_span
        }
        if self.location_span_ok(pi, span) {
            out.push(span)
        }
    }
    return out
}

// Those declarations as stacked labels, capped so a wide overload set stays readable.
fn registry_hover(self: &LspServer, pi: ProjectId, name: String) OwnedString? {
    let spans = self.registry_decl_spans(pi, name)
    defer spans.deinit()
    let sb = string_builder(128)
    let count: usize = 0
    let shown: usize = 0
    for &span in spans {
        const l = self.decl_label(pi, span.*)
        if l.is_none() {
            continue
        }
        count = count + 1
        if shown >= 5 {
            continue
        }
        if shown > 0 {
            sb.append("\n")
        }
        sb.append(l.unwrap())
        shown = shown + 1
    }
    if shown == 0 {
        sb.deinit()
        return null
    }
    if count > shown {
        sb.append("\n... and ")
        sb.append(count - shown)
        sb.append(" more")
    }
    const out = sb.to_string()
    sb.deinit()
    return Some(out)
}

// ---- textDocument/definition ----

// Resolution order: the checker's resolved target at the cursor (locals, params, functions, fields,
// variants, consts); then a name-level ModuleIndex lookup across the workspace, which covers
// everything the checker records no use-edge for - type names, template `#name`s.
fn on_definition(self: &LspServer, msg: &RpcMessage) {
    if !msg.is_request() {
        return
    }
    const cur = self.cursor_at(msg)
    if cur.is_none() {
        self.respond_null(msg)
        return
    }
    const pi = cur.unwrap().pi
    const fid = cur.unwrap().fid
    const offset = cur.unwrap().offset
    const unit = &self.ws.projects[pi].unit
    const result = &unit.result

    let sb = string_builder(512)
    defer sb.deinit()
    let jenc = json_encoder(sb.writer())
    let e = jenc.encoder()
    envelope_response(&e, msg.id().unwrap())
    e.begin_seq(0)

    const text = unit.sources[fid as usize].as_view()
    const word = identifier_at(text, offset)

    let found = false
    const tg = target_at(result, fid, offset)
    if tg.is_some() {
        // A cursor off any word (an operator, punctuation) still resolves its covering target; the
        // qualifier rule needs a word, so the span pair collapses to the offset itself.
        const ws = word match { Some(w) => w.start, None => offset }
        const we = word match { Some(w) => w.start + w.name.len, None => offset }
        const span = cursor_decl_span(result, &tg.unwrap(), text, ws, we)
        if span.is_some() and self.location_span_ok(pi, span.unwrap()) {
            self.encode_span_location(&e, pi, span.unwrap())
            found = true
        }
    }
    if !found {
        if word.is_some() {
            const wstart = word.unwrap().start
            const wname = word.unwrap().name
            const is_member = wstart > 0 and text[wstart - 1] == '.'
            // Member position: the receiver's type carries the field declaration - the checker
            // records no target for field access.
            const fh = member_at(result, fid, text, wstart, wname)
            if fh.is_some() and self.location_span_ok(pi, fh.unwrap().decl_span) {
                self.encode_span_location(&e, pi, fh.unwrap().decl_span)
                found = true
            }
            const wend = wstart + wname.len
            const call_shaped = wend < text.len and text[wend] == '('
            if !found and (!is_member or call_shaped) {
                if !self.encode_registry_matches(&e, pi, wname) {
                    self.encode_index_matches(&e, wname)
                }
            }
        }
    }

    e.end_seq()
    e.end_map()
    write_frame(self.writer, sb.as_view())
}

// Those declarations as Locations. Returns whether anything matched.
fn encode_registry_matches(self: &LspServer, e: &Encoder, pi: ProjectId, name: String) bool {
    let spans = self.registry_decl_spans(pi, name)
    defer spans.deinit()
    for &span in spans {
        self.encode_span_location(e, pi, span.*)
    }
    return spans.len > 0
}

// Every workspace index symbol named exactly `name`, as Locations.
fn encode_index_matches(self: &LspServer, e: &Encoder, name: String) {
    for pi in 0..self.ws.projects.len {
        const index = &self.ws.projects[pi].index
        for fid in 0..index.len {
            for &s in index[fid].symbols {
                if s.name.as_view() != name {
                    continue
                }
                if self.location_span_ok(pi, s.span) {
                    self.encode_span_location(e, pi, s.span)
                }
            }
        }
    }
}

// ---- textDocument/typeDefinition ----

fn on_type_definition(self: &LspServer, msg: &RpcMessage) {
    if !msg.is_request() {
        return
    }
    const cur = self.cursor_at(msg)
    if cur.is_none() {
        self.respond_null(msg)
        return
    }
    const pi = cur.unwrap().pi
    const fid = cur.unwrap().fid
    const unit = &self.ws.projects[pi].unit
    const result = &unit.result

    let sb = string_builder(256)
    defer sb.deinit()
    let jenc = json_encoder(sb.writer())
    let e = jenc.encoder()
    envelope_response(&e, msg.id().unwrap())
    e.begin_seq(0)
    const th = typed_at(result, fid, cur.unwrap().offset)
    if th.is_some() {
        const span = nominal_decl_span(result, th.unwrap().ty)
        if span.is_some() and self.location_span_ok(pi, span.unwrap()) {
            self.encode_span_location(&e, pi, span.unwrap())
        }
    }
    e.end_seq()
    e.end_map()
    write_frame(self.writer, sb.as_view())
}

// ---- textDocument/references ----

// Inverts the project's resolved-target edges. A cursor on a use site takes its target; a cursor on
// a function declaration (no use-edge on the name) falls back to the name's whole overload set.
// Scoped to the project owning the file - target ids are per-project registries.
fn on_references(self: &LspServer, msg: &RpcMessage) {
    if !msg.is_request() {
        return
    }
    const cur = self.cursor_at(msg)
    if cur.is_none() {
        self.respond_null(msg)
        return
    }
    const pi = cur.unwrap().pi
    const fid = cur.unwrap().fid
    const offset = cur.unwrap().offset
    const unit = &self.ws.projects[pi].unit
    const result = &unit.result
    const include_decl = references_include_decl(msg)

    let targets: List(ResolvedTarget) = list(2)
    defer targets.deinit()
    const tg = target_at(result, fid, offset)
    if tg.is_some() {
        targets.push(tg.unwrap().target)
    } else {
        const text = unit.sources[fid as usize].as_view()
        const word = identifier_at(text, offset)
        if word.is_some() {
            const overloads = result.functions.by_name.get_ref(word.unwrap().name)
            if overloads.is_some() {
                for &s in overloads.unwrap() {
                    if !s.retired {
                        targets.push(ResolvedTarget.RtFunction(s.id))
                    }
                }
            }
        }
    }

    let sb = string_builder(1024)
    defer sb.deinit()
    let jenc = json_encoder(sb.writer())
    let e = jenc.encoder()
    envelope_response(&e, msg.id().unwrap())
    e.begin_seq(0)
    for &t in targets {
        if include_decl {
            // ponytail: an RtConst target double-lists its decl (the ConstDecl node carries its own
            // RtConst edge); dedupe if it ever annoys.
            const ds = target_decl_span(result, t)
            if ds.is_some() and self.location_span_ok(pi, ds.unwrap()) {
                self.encode_span_location(&e, pi, ds.unwrap())
            }
        }
        let spans = reference_spans(result, t)
        for &s in spans {
            if self.location_span_ok(pi, s.*) {
                self.encode_span_location(&e, pi, s.*)
            }
        }
        spans.deinit()
    }
    e.end_seq()
    e.end_map()
    write_frame(self.writer, sb.as_view())
}

fn references_include_decl(msg: &RpcMessage) bool {
    const p = msg.params()
    if p.is_none() {
        return true
    }
    const c = get_member(p.unwrap(), "context")
    if c.is_none() {
        return true
    }
    const b = get_member(c.unwrap(), "includeDeclaration")
    if b.is_none() {
        return true
    }
    return b.unwrap().as_bool() ?? true
}

// ---- textDocument/inlayHint ----

// Ask the client to re-request inlay hints. Sent after every analysis: hint positions are only
// valid against the freshly analyzed text, and the client does not otherwise know an analysis
// happened (a save changes no buffer). A client without refresh support answers with an error,
// which the message loop drops like any other reply.
fn request_hint_refresh(self: &LspServer) {
    self.next_id = self.next_id + 1
    write_request(self.writer, self.next_id, "workspace/inlayHint/refresh", null)
}

// Type hints for annotation-less `let` and `for` binders in the requested range: types from the
// last analysis, positions against the buffer the client is displaying. When the live buffer has
// drifted from the analyzed text, sites are re-derived from a fresh parse of the live text and
// paired with the analyzed binders (`live_hint_sites`), so ordinary edits keep every hint in place;
// the post-analysis refresh trues everything up.
fn on_inlay_hint(self: &LspServer, msg: &RpcMessage) {
    if !msg.is_request() {
        return
    }
    const ctx = self.request_ctx(msg)
    if ctx.is_none() {
        self.respond_null(msg)
        return
    }
    const pi = ctx.unwrap().pi
    const fid = ctx.unwrap().fid
    const unit = &self.ws.projects[pi].unit
    const result = &unit.result
    if fid as usize >= unit.modules.len {
        self.respond_null(msg)
        return
    }
    const atext = unit.sources[fid as usize].as_view()
    const uri = doc_uri(msg)
    const doc = if uri.is_some() { self.docs.get(uri.unwrap()) } else { null }
    // The text positions are computed against: the live buffer when open, else the analyzed text.
    const text = if doc.is_some() { doc.unwrap().text.as_view() } else { atext }
    let lidx = line_index(text)
    defer lidx.deinit()

    // The requested range, as offsets; the whole file when absent.
    let lo: usize = 0
    let hi = text.len
    const p = msg.params()
    if p.is_some() {
        const range = get_member(p.unwrap(), "range")
        if range.is_some() {
            const s = range_bound(range.unwrap(), "start")
            const en = range_bound(range.unwrap(), "end")
            if s.is_some() {
                lo = lidx.to_offset(text, s.unwrap(), self.encoding)
            }
            if en.is_some() {
                hi = lidx.to_offset(text, en.unwrap(), self.encoding)
            }
        }
    }

    let sites = if text == atext { hint_sites(&unit.modules[fid as usize]) }
    else { live_hint_sites(text, &unit.modules[fid as usize]) }
    defer sites.deinit()
    const vars = type_param_names(&unit.checker)
    let sb = string_builder(1024)
    defer sb.deinit()
    let jenc = json_encoder(sb.writer())
    let e = jenc.encoder()
    envelope_response(&e, msg.id().unwrap())
    e.begin_seq(0)
    for &site in sites {
        if site.offset < lo or site.offset > hi {
            continue
        }
        const ty = type_of_node(result, site.node)
        if ty.is_none() or !renderable_ty(result, ty.unwrap(), vars) or is_void_ty(result,
            ty.unwrap()) {
            continue
        }
        const rendered = render_ty(result, ty.unwrap(), Some(vars))
        e.begin_map(0)
        e.key("position")
        encode_pos(&e, lidx.to_position(text, site.offset, self.encoding))
        e.key("label")
        const l = $": {rendered.as_view()}"
        e.encode_str(l.as_view())
        l.deinit()
        rendered.deinit()
        e.key("kind")
        e.encode_int(1, 8) // InlayHintKind.Type
        e.end_map()
    }
    e.end_seq()
    e.end_map()
    write_frame(self.writer, sb.as_view())
}

fn range_bound(range: &JsonValue, key: String) Position? {
    return get_member(range, key) match {
        Some(v) => pos_of(v)
        None => null
    }
}

// ---- textDocument/signatureHelp ----

// Works off the LIVE buffer (the analysis is stale exactly when signature help fires): a backward
// scan finds the callee and argument index, the function registry supplies the overload set, and
// each signature label is the declaration's own source slice.
fn on_signature_help(self: &LspServer, msg: &RpcMessage) {
    if !msg.is_request() {
        return
    }
    const uri = doc_uri(msg)
    const doc = if uri.is_some() { self.docs.get(uri.unwrap()) } else { null }
    const ctx = self.request_ctx(msg)
    const pos = req_position(msg)
    if doc.is_none() or ctx.is_none() or pos.is_none() {
        self.respond_null(msg)
        return
    }
    const pi = ctx.unwrap().pi
    const text = doc.unwrap().text.as_view()
    const offset = doc.unwrap().index.to_offset(text, pos.unwrap(), self.encoding)

    const site = call_site_at(text, offset)
    if site.is_none() {
        self.respond_null(msg)
        return
    }
    let cs = site.unwrap()
    const result = &self.ws.projects[pi].unit.result
    const overloads = result.functions.by_name.get_ref(cs.name.as_view())
    if overloads.is_none() or overloads.unwrap().len == 0 {
        cs.deinit()
        self.respond_null(msg)
        return
    }

    let sb = string_builder(1024)
    defer sb.deinit()
    let jenc = json_encoder(sb.writer())
    let e = jenc.encoder()
    envelope_response(&e, msg.id().unwrap())
    e.begin_map(0)
    e.key("signatures")
    e.begin_seq(0)
    let emitted: usize = 0
    let active_sig: usize = 0
    let active_found = false
    for &s in overloads.unwrap() {
        if s.retired {
            continue
        }
        const label = self.decl_label(pi, s.decl_span)
        if label.is_none() {
            continue
        }
        let params = param_labels(label.unwrap())
        // The first overload that still has a parameter slot for the active index wins the
        // highlight; 0 otherwise.
        if !active_found and params.len > cs.active {
            active_sig = emitted
            active_found = true
        }
        e.begin_map(0)
        e.key("label")
        e.encode_str(label.unwrap())
        e.key("parameters")
        e.begin_seq(params.len)
        for &pl in params {
            e.begin_map(0)
            e.key("label")
            e.encode_str(pl.*)
            e.end_map()
        }
        e.end_seq()
        e.end_map()
        params.deinit()
        emitted = emitted + 1
    }
    e.end_seq()
    e.key("activeSignature")
    e.encode_uint(active_sig as u64, 8)
    e.key("activeParameter")
    e.encode_uint(cs.active as u64, 8)
    e.end_map()
    e.end_map()
    write_frame(self.writer, sb.as_view())
    cs.deinit()
}

// ---- textDocument/formatting ----

// Formats the LIVE buffer through lib/flang_fmt - the same passes `flang fmt` runs - honoring the
// project's `[fmt]` table when a manifest is reachable from the document's path. One whole-document
// TextEdit when anything changed, an empty list when already clean, null when the source refuses to
// format (a parse error mid-edit).
fn on_formatting(self: &LspServer, msg: &RpcMessage) {
    if !msg.is_request() {
        return
    }
    const uri = doc_uri(msg)
    const doc = if uri.is_some() { self.docs.get(uri.unwrap()) } else { null }
    if doc.is_none() {
        self.respond_null(msg)
        return
    }
    const text = doc.unwrap().text.as_view()

    let cfg = default_config()
    if doc.unwrap().path.as_view().len > 0 {
        apply_project_fmt(doc.unwrap().path.as_view(), &cfg)
    }

    const res = format_source(text, &cfg)
    if res.is_err() {
        self.respond_null(msg)
        return
    }
    let formatted = res.unwrap()
    defer formatted.deinit()

    let sb = string_builder(formatted.as_view().len + 256)
    defer sb.deinit()
    let jenc = json_encoder(sb.writer())
    let e = jenc.encoder()
    envelope_response(&e, msg.id().unwrap())
    e.begin_seq(0)
    if formatted.as_view() != text {
        e.begin_map(0)
        e.key("range")
        e.begin_map(0)
        e.key("start")
        encode_pos(&e, Position { line = 0u32, character = 0u32 })
        e.key("end")
        encode_pos(&e, doc.unwrap().index.to_position(text, text.len, self.encoding))
        e.end_map()
        e.key("newText")
        e.encode_str(formatted.as_view())
        e.end_map()
    }
    e.end_seq()
    e.end_map()
    write_frame(self.writer, sb.as_view())
}

// The `[fmt]` table of the manifest governing `path`, applied onto `cfg`. Unknown keys are silently
// ignored - `flang fmt` already warns about them on the command line.
fn apply_project_fmt(path: String, cfg: &FmtConfig) {
    const dir = project_dir_for(path)
    if dir.is_none() {
        return
    }
    let d = dir.unwrap()
    const manifest = $"{d.as_view()}/flang.toml"
    d.deinit()
    const got = read_text(manifest.as_view())
    manifest.deinit()
    if got.is_none() {
        return
    }
    let toml = got.unwrap()
    let proj = parse_project(toml.as_view())
    for &e in proj.fmt {
        const _ok = set_option(cfg, e.key.as_view(), e.value.as_view())
    }
    proj.deinit()
    toml.deinit()
}

// =============================================================================
// Tests - canned JSON-RPC transcripts through MemReader / StringBuilder
// =============================================================================

fn frame_into(sb: &StringBuilder, body: String) {
    write_frame(sb.writer(), body)
}

test "initialize negotiates utf-8 when offered" {
    let input = string_builder(512)
    defer input.deinit()
    frame_into(&input,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-16\",\"utf-8\"]}}}}")

    let out = string_builder(512)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    const code = srv.run()

    assert_eq(code, 1, "stream ended without exit")
    assert_true(contains(out.as_view(), "\"positionEncoding\":\"utf-8\""), "utf-8 accepted")
    assert_true(contains(out.as_view(), "\"id\":1"), "response addressed to the request")
    assert_true(contains(out.as_view(), "\"change\":1"), "full sync advertised")
    assert_true(contains(out.as_view(), "\"save\":true"), "save notifications requested")
    assert_true(contains(out.as_view(), "\"documentSymbolProvider\":true"), "symbols advertised")
    assert_true(contains(out.as_view(), "\"foldingRangeProvider\":true"), "folding advertised")
    assert_true(contains(out.as_view(), "\"workspaceSymbolProvider\":true"),
        "workspace symbols advertised")
}

test "initialize falls back to utf-16" {
    let input = string_builder(256)
    defer input.deinit()
    frame_into(&input,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{}}}")

    let out = string_builder(512)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    srv.run()

    assert_true(contains(out.as_view(), "\"positionEncoding\":\"utf-16\""), "utf-16 is the default")
}

test "initialized reports server status with version and folders" {
    let input = string_builder(512)
    defer input.deinit()
    frame_into(&input,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"workspaceFolders\":[{\"uri\":\"file:///c%3A/w\",\"name\":\"w\"}]}}")
    frame_into(&input, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}")

    let out = string_builder(1024)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer(), "", "9.9.9")
    defer srv.deinit()
    srv.run()

    assert_true(contains(out.as_view(), "\"method\":\"flang/serverStatus\""), "status notification")
    assert_true(contains(out.as_view(), "\"version\":\"9.9.9\""), "compiler version included")
    assert_true(contains(out.as_view(), "\"folders\":[\"w\"]"), "workspace folder names included")
    assert_true(contains(out.as_view(), "\"projects\":[]"), "no projects open yet")
}

test "shutdown then exit returns 0" {
    let input = string_builder(256)
    defer input.deinit()
    frame_into(&input, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"shutdown\"}")
    frame_into(&input, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}")

    let out = string_builder(256)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    const code = srv.run()

    assert_eq(code, 0, "orderly shutdown")
    assert_true(contains(out.as_view(), "\"id\":1,\"result\":null"), "shutdown acknowledged")
}

test "exit without shutdown returns 1" {
    let input = string_builder(128)
    defer input.deinit()
    frame_into(&input, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}")

    let out = string_builder(128)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    assert_eq(srv.run(), 1, "abrupt exit is an error per LSP")
}

test "didOpen and didChange replace the buffer, didClose drops it" {
    let input = string_builder(1024)
    defer input.deinit()
    frame_into(&input,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\",\"version\":1,\"text\":\"const A: i32 = 1\"}}}")
    frame_into(&input,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\",\"version\":2},\"contentChanges\":[{\"text\":\"const B: i32 = 2\"}]}}")

    let out = string_builder(2048)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    srv.run()

    const doc = srv.docs.get("file:///t.f")
    assert_true(doc.is_some(), "document open")
    assert_eq(doc.unwrap().text.as_view(), "const B: i32 = 2", "full sync replaced the text")
    assert_eq(doc.unwrap().version, 2, "version tracked")
    assert_eq(doc.unwrap().path.as_view(), "/t.f", "file uri resolves to a path")

    let input2 = string_builder(256)
    defer input2.deinit()
    frame_into(&input2,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\"}}}")
    let mr2 = mem_reader(input2.as_view())
    srv.reader = mr2.reader()
    srv.run()
    assert_true(srv.docs.get("file:///t.f").is_none(), "closed document dropped")
}

test "a keystroke publishes syntax diagnostics and a fix clears them" {
    let input = string_builder(1024)
    defer input.deinit()
    frame_into(&input,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\",\"version\":1,\"text\":\"fn broken( {\"}}}")

    let out = string_builder(4096)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    srv.run()
    assert_true(contains(out.as_view(), "\"method\":\"textDocument/publishDiagnostics\""),
        "diagnostics published on open")
    assert_true(contains(out.as_view(), "\"severity\":1"), "the parse error is an error")
    assert_true(contains(out.as_view(), "\"source\":\"flang\""), "labelled as ours")

    let input2 = string_builder(512)
    defer input2.deinit()
    frame_into(&input2,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\",\"version\":2},\"contentChanges\":[{\"text\":\"fn ok() { return }\"}]}}")
    let out2 = string_builder(1024)
    defer out2.deinit()
    let mr2 = mem_reader(input2.as_view())
    srv.reader = mr2.reader()
    srv.writer = out2.writer()
    srv.run()
    assert_true(contains(out2.as_view(), "\"diagnostics\":[]"), "the fix publishes an empty list")
}

test "documentSymbol answers with the outline" {
    let input = string_builder(1024)
    defer input.deinit()
    frame_into(&input,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\",\"version\":1,\"text\":\"pub fn go() i32 { return 1 }\\npub type P = struct { x: i32 }\"}}}")
    frame_into(&input,
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\"}}}")

    let out = string_builder(4096)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    srv.run()

    assert_true(contains(out.as_view(), "\"id\":4,\"result\":["), "request answered with an array")
    assert_true(contains(out.as_view(), "\"name\":\"go\""), "function listed")
    assert_true(contains(out.as_view(), "\"kind\":12"), "as a function")
    assert_true(contains(out.as_view(), "\"name\":\"P\""), "struct listed")
    assert_true(contains(out.as_view(), "\"children\":[{\"name\":\"x\""), "field nested under it")
    assert_true(contains(out.as_view(), "\"selectionRange\""), "selection range present")
}

test "documentSymbol for an unknown document answers null" {
    let input = string_builder(512)
    defer input.deinit()
    frame_into(&input,
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file:///nope.f\"}}}")

    let out = string_builder(512)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    srv.run()
    assert_true(contains(out.as_view(), "\"id\":5,\"result\":null"), "no buffer, null result")
}

test "foldingRange answers with delimiter folds" {
    let input = string_builder(1024)
    defer input.deinit()
    frame_into(&input,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\",\"version\":1,\"text\":\"fn a() {\\n    let x = 1\\n    return\\n}\"}}}")
    frame_into(&input,
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"textDocument/foldingRange\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\"}}}")

    let out = string_builder(4096)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    srv.run()

    assert_true(contains(out.as_view(), "\"id\":6,\"result\":[{\"startLine\":0,\"endLine\":2}]"),
        "the body folds, closing brace stays visible")
}

test "workspace/symbol with no open projects answers an empty list" {
    let input = string_builder(512)
    defer input.deinit()
    frame_into(&input,
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"go\"}}")

    let out = string_builder(512)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    srv.run()
    assert_true(contains(out.as_view(), "\"id\":7,\"result\":[]"), "empty result, not an error")
}

test "workspace/symbol answers matches with kinds, containers and locations" {
    let input = string_builder(1024)
    defer input.deinit()
    frame_into(&input,
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"\"}}")
    frame_into(&input,
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"po\"}}")

    let out = string_builder(8192)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()

    // An open project fabricated around an in-memory analysis - no disk, no stdlib.
    let srcs: List(OwnedString) = list(1)
    srcs.push(from_view("pub fn point() i32 { return 1 }\npub type Point = struct { x: i32 }\n"))
    let fqns: List(String) = list(1)
    fqns.push("t.m")
    let unit = analyze_source_set(srcs, &fqns)
    fqns.deinit()
    // Pushed through an explicit reference: see known-issues "Method Mutation Through a One-Hop
    // Field of a By-Value Local Is Dropped" (reference compiler).
    let origin = &unit.project_origin
    origin.push(true)
    let index = build_indexes(&unit)
    let proj = parse_project("[project]\nname = \"t\"\n")
    let ctx = resolve_ctx(&proj, "")
    proj.deinit()
    srv.ws.projects.push(OpenProject {
        dir = from_view("/t"),
        name = from_view("t"),
        ctx = ctx,
        unit = unit,
        index = index,
    })
    srv.run()

    assert_true(contains(out.as_view(), "\"id\":8,\"result\":["), "empty query answered")
    assert_true(contains(out.as_view(), "\"name\":\"x\",\"kind\":8,\"containerName\":\"Point\""),
        "member carries its container")
    assert_true(contains(out.as_view(), "\"name\":\"point\",\"kind\":12"), "function with kind")
    assert_true(contains(out.as_view(), "\"name\":\"Point\",\"kind\":23"), "struct with kind")
    assert_true(contains(out.as_view(), "\"range\":{\"start\":{\"line\":"), "location has a range")

    // The filtered query drops the field but keeps both `po` matches, case-insensitively.
    const tail = out.as_view()[find(out.as_view(), "\"id\":9").unwrap()..out.as_view().len]
    assert_true(contains(tail, "\"name\":\"point\""), "substring match kept")
    assert_true(contains(tail, "\"name\":\"Point\""), "case-insensitive match kept")
    assert_true(!contains(tail, "\"name\":\"x\""), "non-matching member dropped")
}

// A small analyzed project for the cursor-request tests, fabricated in memory: one file at
// /t/m.f, no disk, no stdlib.
const DEMO_SRC: String = "pub fn point(q: i32) i32 { return q }\npub type P = struct { x: i32 }\npub fn go(n: i32) i32 {\n    let a = point(3)\n    let s = P { x = 1 }\n    for v in 0..n {\n        let b = v\n    }\n    return a\n}\n// see Wide\npub fn pick(x: $T) $T { return x }\npub fn wait(k: i32) {\n    while k > 0 {\n        k = k - 1\n    }\n}\npub fn use_pick() i32 { return pick(7) }\npub fn wrap(y: $T) i32 { return point(8) }\npub fn use_wrap() i32 { return wrap(true) }\npub fn lone(z: $T) i32 { return point(4) }\npub fn read_x(pp: P) i32 { return pp.x }\npub fn solo(w: $T, point: i32) i32 { return point }\npub type E = enum { A B }\npub fn pick_e() E { return E.A }\n"

fn demo_project_into(srv: &LspServer) {
    let srcs: List(OwnedString) = list(2)
    srcs.push(from_view(DEMO_SRC))
    // A second, NON-project-origin module (a stand-in for stdlib/dependency code): absent from the
    // ModuleIndex, so its declarations resolve only through the registry fallback.
    srcs.push(from_view("pub type Wide = struct { w: i32 }\n"))
    let fqns: List(String) = list(2)
    fqns.push("/t/m.f")
    fqns.push("/t/dep.f")
    let unit = analyze_source_set(srcs, &fqns)
    fqns.deinit()
    let origin = &unit.project_origin
    origin.push(true)
    origin.push(false)
    let index = build_indexes(&unit)
    let proj = parse_project("[project]\nname = \"t\"\n")
    let ctx = resolve_ctx(&proj, "")
    proj.deinit()
    srv.ws.projects.push(OpenProject {
        dir = from_view("/t"),
        name = from_view("t"),
        ctx = ctx,
        unit = unit,
        index = index,
    })
}

// The demo source as a JSON string body (newlines escaped).
fn demo_src_json() OwnedString {
    let sb = string_builder(DEMO_SRC.len + 32)
    for i in 0..DEMO_SRC.len {
        if DEMO_SRC[i] == '\n' {
            sb.append("\\n")
        } else {
            sb.append(DEMO_SRC[i..(i + 1)])
        }
    }
    const out = sb.to_string()
    sb.deinit()
    return out
}

fn demo_input(request: String) StringBuilder {
    let input = string_builder(4096)
    const src = demo_src_json()
    const open = $"{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///t/m.f\",\"version\":1,\"text\":\"{src.as_view()}\"}}}}}}"
    src.deinit()
    frame_into(&input, open.as_view())
    open.deinit()
    frame_into(&input, request)
    return input
}

fn demo_run(request: String, out: &StringBuilder) {
    let input = demo_input(request)
    defer input.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    demo_project_into(&srv)
    srv.run()
}

test "hover on a local read renders name and type" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run("{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":8,\"character\":11}}}",
        &out)
    assert_true(contains(out.as_view(), "```flang"), "flang code block")
    assert_true(contains(out.as_view(), "let a: i32"), "scope intro, name and type")
}

test "hover on a for-loop binder renders the element type" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run("{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":5,\"character\":8}}}",
        &out)
    assert_true(contains(out.as_view(), "for v: i32"), "loop variable hover with its intro")
}

test "hover on a callee names the function" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run("{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":3,\"character\":13}}}",
        &out)
    assert_true(contains(out.as_view(), "point"), "function named")
    assert_true(contains(out.as_view(), "i32"), "signature or type shown")
}

test "definition on a call lands on the declaration" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run("{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":3,\"character\":13}}}",
        &out)
    assert_true(contains(out.as_view(), "\"id\":13,\"result\":[{"), "a location came back")
    assert_true(contains(out.as_view(), "\"uri\":\"file:///t/m.f\""), "same file")
    assert_true(contains(out.as_view(), "\"start\":{\"line\":0,"), "the declaration line")
}

test "hover on a function parameter renders its type" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run("{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":0,\"character\":13}}}",
        &out)
    assert_true(contains(out.as_view(), "```flang\\nparam q: i32\\n```"),
        "parameter with its intro, name and type")
}

test "hover inside a generic body answers from the instantiation overlay" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run("{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":11,\"character\":31}}}",
        &out)
    assert_true(contains(out.as_view(), "param x: i32"),
        "the concrete instantiation's type answers, with the binder intro")
}

test "hover on a callee inside a generic body shows the declaration" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run("{\"jsonrpc\":\"2.0\",\"id\":25,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":18,\"character\":33}}}",
        &out)
    assert_true(contains(out.as_view(), "pub fn point(q: i32) i32"),
        "callee hover matches the non-generic behaviour")
}

test "hover on a generic callee shows its declaration" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run("{\"jsonrpc\":\"2.0\",\"id\":26,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":17,\"character\":32}}}",
        &out)
    assert_true(contains(out.as_view(), "pub fn pick(x: $T) $T"),
        "generic declaration slice, body cut at the brace")
}

test "hover on a callee inside an uninstantiated generic answers by name" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run("{\"jsonrpc\":\"2.0\",\"id\":27,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":20,\"character\":33}}}",
        &out)
    assert_true(contains(out.as_view(), "pub fn point(q: i32) i32"),
        "no overlay exists, the registry answers like goto does")
}

test "hover on a member field renders the field type" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run("{\"jsonrpc\":\"2.0\",\"id\":28,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":21,\"character\":37}}}",
        &out)
    assert_true(contains(out.as_view(), "```flang\\nfield x: i32\\n```"),
        "field intro, name and type")
}

test "definition on a member field lands on the field declaration" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run("{\"jsonrpc\":\"2.0\",\"id\":29,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":21,\"character\":37}}}",
        &out)
    assert_true(contains(out.as_view(), "\"id\":29,\"result\":[{"), "a location came back")
    assert_true(contains(out.as_view(), "\"line\":1,\"character\":22"),
        "the field inside the struct, not some same-named global")
}

test "a param shadowing a function name hovers as the param" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run("{\"jsonrpc\":\"2.0\",\"id\":30,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":22,\"character\":45}}}",
        &out)
    assert_true(contains(out.as_view(), "point: i32"), "the binder's annotation answers")
    assert_true(!contains(out.as_view(), "pub fn point"),
        "the same-named function does not hijack the hover")
}

test "the qualifier of Enum.Variant resolves to the enum, the member to the variant" {
    let out = string_builder(4096)
    defer out.deinit()
    // definition on `E` in `E.A`
    demo_run("{\"jsonrpc\":\"2.0\",\"id\":33,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":24,\"character\":27}}}",
        &out)
    assert_true(contains(out.as_view(), "\"line\":23,\"character\":0"),
        "qualifier lands on the enum declaration")

    let out2 = string_builder(4096)
    defer out2.deinit()
    // definition on `A` in `E.A`
    demo_run("{\"jsonrpc\":\"2.0\",\"id\":34,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":24,\"character\":29}}}",
        &out2)
    assert_true(contains(out2.as_view(), "\"line\":23,\"character\":20"),
        "member lands on the variant inside the enum body")

    let out3 = string_builder(4096)
    defer out3.deinit()
    // hover on `E` in `E.A`
    demo_run("{\"jsonrpc\":\"2.0\",\"id\":35,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":24,\"character\":27}}}",
        &out3)
    assert_true(contains(out3.as_view(), "pub type E = enum"), "qualifier hovers as the enum")
}

test "hover on keywords and annotations answers null" {
    let out = string_builder(4096)
    defer out.deinit()
    // `while` keyword
    demo_run("{\"jsonrpc\":\"2.0\",\"id\":23,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":13,\"character\":5}}}",
        &out)
    assert_true(contains(out.as_view(), "\"id\":23,\"result\":null"), "no void whole-loop hover")

    let out2 = string_builder(4096)
    defer out2.deinit()
    // the `i32` inside go's parameter annotation
    demo_run("{\"jsonrpc\":\"2.0\",\"id\":24,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":2,\"character\":14}}}",
        &out2)
    assert_true(contains(out2.as_view(), "\"id\":24,\"result\":null"),
        "no whole-statement hover from an annotation")
}

test "definition resolves a non-indexed type through the registry" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run("{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":10,\"character\":8}}}",
        &out)
    assert_true(contains(out.as_view(), "\"id\":21,\"result\":[{"), "a location came back")
    assert_true(contains(out.as_view(), "\"uri\":\"file:///t/dep.f\""),
        "the dependency module's file")
}

test "definition on a type name falls back to the symbol index" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run("{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":4,\"character\":12}}}",
        &out)
    assert_true(contains(out.as_view(), "\"id\":14,\"result\":[{"), "a location came back")
    assert_true(contains(out.as_view(), "\"line\":1,"), "the struct declaration line")
}

test "typeDefinition on a struct-typed local lands on the struct" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run("{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"textDocument/typeDefinition\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":4,\"character\":8}}}",
        &out)
    assert_true(contains(out.as_view(), "\"id\":15,\"result\":[{"), "a location came back")
    assert_true(contains(out.as_view(), "\"line\":1,"), "the struct declaration line")
}

test "references on a parameter finds declaration and reads" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run("{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"textDocument/references\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":0,\"character\":34},\"context\":{\"includeDeclaration\":true}}}",
        &out)
    assert_true(contains(out.as_view(), "\"id\":16,\"result\":[{"), "locations came back")
    assert_true(contains(out.as_view(), "\"character\":34"), "the read site listed")
    assert_true(contains(out.as_view(), "\"character\":13"), "the declaration listed")
}

test "inlayHint lists annotation-less binders with their types" {
    let out = string_builder(8192)
    defer out.deinit()
    demo_run("{\"jsonrpc\":\"2.0\",\"id\":17,\"method\":\"textDocument/inlayHint\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"}}}",
        &out)
    assert_true(contains(out.as_view(), "\"label\":\": i32\""), "int binders hinted")
    assert_true(contains(out.as_view(), "\"label\":\": P\""), "struct binder hinted")
    assert_true(contains(out.as_view(), "\"kind\":1"), "typed as type hints")
}

test "inlayHint answers empty when the edited buffer shares no binders" {
    let out = string_builder(8192)
    defer out.deinit()
    let input = demo_input("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\",\"version\":2},\"contentChanges\":[{\"text\":\"pub fn nothing() { }\"}]}}")
    frame_into(&input,
        "{\"jsonrpc\":\"2.0\",\"id\":31,\"method\":\"textDocument/inlayHint\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"}}}")
    defer input.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    demo_project_into(&srv)
    srv.run()
    assert_true(contains(out.as_view(), "\"id\":31,\"result\":[]"),
        "nothing pairs, nothing renders")
}

test "inlayHint follows unsaved edits to live positions" {
    let out = string_builder(16384)
    defer out.deinit()
    // The same source shifted down one line: every binder pairs, every hint moves with it.
    const src = demo_src_json()
    const change = $"{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///t/m.f\",\"version\":2}},\"contentChanges\":[{{\"text\":\"// pad\\n{src.as_view()}\"}}]}}}}"
    src.deinit()
    let input = demo_input(change.as_view())
    change.deinit()
    frame_into(&input,
        "{\"jsonrpc\":\"2.0\",\"id\":32,\"method\":\"textDocument/inlayHint\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"}}}")
    defer input.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    demo_project_into(&srv)
    srv.run()
    assert_true(contains(out.as_view(),
            "\"position\":{\"line\":4,\"character\":9},\"label\":\": i32\""),
        "the first hint renders one line below its analyzed position")
    assert_true(contains(out.as_view(), "\"label\":\": P\""), "later binders keep pairing")
}

test "signatureHelp inside a call shows the declaration and active parameter" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run("{\"jsonrpc\":\"2.0\",\"id\":18,\"method\":\"textDocument/signatureHelp\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":3,\"character\":18}}}",
        &out)
    assert_true(contains(out.as_view(), "\"label\":\"pub fn point(q: i32) i32\""),
        "declaration slice as the signature label")
    assert_true(contains(out.as_view(), "\"parameters\":[{\"label\":\"q: i32\"}]"),
        "parameter label sliced out")
    assert_true(contains(out.as_view(), "\"activeParameter\":0"), "first argument active")
}

test "hover outside any analyzed project answers null" {
    let input = string_builder(512)
    defer input.deinit()
    frame_into(&input,
        "{\"jsonrpc\":\"2.0\",\"id\":19,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///nowhere.f\"},\"position\":{\"line\":0,\"character\":0}}}")
    let out = string_builder(512)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    srv.run()
    assert_true(contains(out.as_view(), "\"id\":19,\"result\":null"), "null, not an error")
}

test "formatting answers one whole-document edit" {
    let input = string_builder(1024)
    defer input.deinit()
    frame_into(&input,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\",\"version\":1,\"text\":\"fn go() {\\n        return\\n}\\n\"}}}")
    frame_into(&input,
        "{\"jsonrpc\":\"2.0\",\"id\":40,\"method\":\"textDocument/formatting\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\"},\"options\":{\"tabSize\":4}}}")

    let out = string_builder(4096)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    srv.run()

    assert_true(contains(out.as_view(), "\"id\":40,\"result\":[{"), "an edit came back")
    assert_true(contains(out.as_view(), "\"start\":{\"line\":0,\"character\":0}"),
        "edit starts at the top")
    assert_true(contains(out.as_view(), "\"newText\":\"fn go() {\\n    return\\n}\\n\""),
        "over-indent reduced to four spaces")
}

test "formatting a clean document answers no edits" {
    let input = string_builder(1024)
    defer input.deinit()
    frame_into(&input,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\",\"version\":1,\"text\":\"fn go() {\\n    return\\n}\\n\"}}}")
    frame_into(&input,
        "{\"jsonrpc\":\"2.0\",\"id\":41,\"method\":\"textDocument/formatting\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\"}}}")

    let out = string_builder(4096)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    srv.run()
    assert_true(contains(out.as_view(), "\"id\":41,\"result\":[]"), "nothing to change")
}

test "unknown request errors, unknown notification is ignored" {
    let input = string_builder(512)
    defer input.deinit()
    frame_into(&input,
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"textDocument/rename\",\"params\":{}}")
    frame_into(&input, "{\"jsonrpc\":\"2.0\",\"method\":\"$/setTrace\",\"params\":{}}")

    let out = string_builder(512)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    srv.run()

    assert_true(contains(out.as_view(), "\"id\":9,\"error\":{\"code\":-32601"),
        "request answered with MethodNotFound")
    assert_true(!contains(out.as_view(), "setTrace"), "notification produced no traffic")
}

test "malformed body gets a ParseError response and the loop continues" {
    let input = string_builder(512)
    defer input.deinit()
    frame_into(&input, "{not json")
    frame_into(&input, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"shutdown\"}")

    let out = string_builder(512)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    srv.run()

    assert_true(contains(out.as_view(), "\"code\":-32700"), "ParseError reported")
    assert_true(contains(out.as_view(), "\"id\":1,\"result\":null"), "later messages still served")
}
