// The LSP server core: a single-threaded message loop over a Reader/Writer pair speaking
// std.rpc.jsonrpc, plus the lifecycle, document-sync, diagnostics and tier-1 feature handlers.
// Transport-agnostic - the bootstrap `lsp` subcommand hands it stdin/stdout, tests hand it a
// MemReader and a StringBuilder.
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
import std.io.fs
import flang_core.diagnostic
import flang_core.span
import flang_analysis.analyze
import flang_lsp.documents
import flang_lsp.handlers.document_symbol
import flang_lsp.handlers.folding_range
import flang_lsp.handlers.syntax_diagnostics
import flang_lsp.line_index
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
    exit_code: i32?
    next_id: i64
}

pub fn lsp_server(r: Reader, w: Writer, stdlib_path: String = "",
    version: String = "0.0.0") LspServer {
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
        self.dispatch(&msg)
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
        "workspace/didChangeWatchedFiles" => self.on_watched_files(msg)
        else => self.on_unknown(msg)
    }
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
fn publish_project(self: &LspServer, pi: usize) {
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
    }
}

// Re-check one open project with `dirty_path` re-parsed, then republish and refresh the status.
fn recheck_project(self: &LspServer, pi: usize, dirty_path: String) {
    let dirty: Set(String) = set()
    dirty.add(dirty_path)
    self.recheck_with(pi, &dirty)
    dirty.deinit()
}

fn recheck_with(self: &LspServer, pi: usize, dirty: &Set(String)) {
    const title = $"FLang: checking {self.ws.projects[pi].name.as_view()}"
    const token = self.progress_begin(title.as_view())
    title.deinit()
    reanalyze_project(&self.ws, pi, dirty, &self.docs)
    self.progress_end(token.as_view())
    token.deinit()
    self.publish_project(pi)
    self.send_status()
}

// ---- Watched files ----

// Disk changes from the client's file watcher. Open buffers win over disk, so a change to an open
// file is ignored here (didChange already delivered it). A changed `.f` re-checks its project; a
// created or deleted `.f`, or any `flang.toml` event, rebuilds the project whole (the module set
// changed).
fn on_watched_files(self: &LspServer, msg: &RpcMessage) {
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

test "unknown request errors, unknown notification is ignored" {
    let input = string_builder(512)
    defer input.deinit()
    frame_into(&input,
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"textDocument/hover\",\"params\":{}}")
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
