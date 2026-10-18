// The LSP server core: a single-threaded message loop over a Reader/Writer pair speaking
// std.rpc.jsonrpc, plus the lifecycle, document-sync, diagnostics and tier-1 feature handlers.
// Transport-agnostic - the `flang lsp` subcommand hands it stdin/stdout, tests hand it a MemReader
// and a StringBuilder.
//
// Analysis runs synchronously between messages: a didOpen of the first file under a `flang.toml`
// analyzes that whole project behind a `$/progress` spinner, a didSave re-checks it, and a
// keystroke gets fresh parse (tier 1) diagnostics immediately, beside the last analysis's for that
// file. Requests never start analysis; they
// answer from the current buffers. With no stdlib path configured the server stays in tier-1-only
// mode (syntax diagnostics, symbols, folding) and never type-checks.
//
// Unknown requests get MethodNotFound, unknown notifications are dropped, both per JSON-RPC. `exit`
// ends the loop with code 0 when a `shutdown` request preceded it, 1 otherwise (LSP 3.17 exit
// semantics).

import std.collections.dict
import std.collections.list
import std.collections.set
import std.encoding.codec
import std.encoding.json
import std.encoding.value
import std.io.file
import std.io.fs
import std.io.reader
import std.io.writer
import std.option
import std.result
import std.rpc.jsonrpc
import std.string
import std.string_builder
import std.string_reader
import std.test
import std.time

import flang_analysis.analyze
import flang_analysis.project
import flang_analysis.resolver
import flang_core.diagnostic
import flang_core.span
import flang_fmt.fmt
import flang_parser.trivia
import flang_typer.checker
import flang_typer.function_registry
import flang_typer.inference_results
import flang_typer.interner
import flang_typer.node_id
import flang_typer.nominal_registry
import flang_typer.reporter
import flang_typer.result
import flang_typer.type
import flang_typer.well_known

import flang_lsp.documents
import flang_lsp.handlers.document_symbol
import flang_lsp.handlers.folding_range
import flang_lsp.handlers.hover
import flang_lsp.handlers.inlay_hint
import flang_lsp.handlers.rename
import flang_lsp.handlers.signature_help
import flang_lsp.handlers.syntax_diagnostics
import flang_lsp.index
import flang_lsp.line_index
import flang_lsp.protocol
import flang_lsp.query
import flang_lsp.uri
import flang_lsp.workspace

pub type LspServer = struct {
    reader: Reader
    out: RpcWriter
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
    // The client accepts LocationLink from definition (`linkSupport`), which lets an import
    // highlight its whole dotted path rather than the word under the cursor.
    definition_links: bool
    // The client registered `flang.runTest` (`capabilities.experimental.commands.commands`), so a
    // code lens may name it.
    run_test_command: bool
    exit_code: i32?
    next_id: i64
}

pub fn lsp_server(
    r: Reader,
    w: Writer,
    stdlib_path: String = "",
    version: String = "0.0.0",
    log_access: bool = false,
) LspServer {
    return .{
        reader = r,
        out = rpc_writer(w, json_options(KeyCase.Camel)),
        docs = document_store(),
        ws = workspace(stdlib_path),
        version = from_view(version),
        folders = list(0),
        encoding = PositionEncoding.Utf16,
        shutdown_requested = false,
        stdlib_warned = false,
        log_access = log_access,
        definition_links = false,
        run_test_command = false,
        exit_code = null,
        next_id = 0,
    }
}

pub fn deinit(self: move LspServer) {
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
                    const nul = Value.Null
                    self.out.respond_error(&nul, PARSE_ERROR, "invalid message")
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
        "textDocument/codeLens" => self.on_code_lens(msg)
        "textDocument/prepareRename" => self.on_prepare_rename(msg)
        "textDocument/rename" => self.on_rename(msg)
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
        const n = id.unwrap().as_i64()
        if n.is_some() {
            sb.append(" #")
            sb.append(n.unwrap())
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

fn get_member(v: &Value, name: String) &Value? {
    return v.get(name)
}

fn get_str(v: &Value, name: String) String? {
    return get_member(v, name) match {
        Some(m) => m.as_string()
        None => null
    }
}

fn get_i64(v: &Value, name: String) i64? {
    const m = get_member(v, name)
    if m.is_none() {
        return null
    }
    const n = m.unwrap().as_i64()
    if n.is_some() {
        return n
    }
    const f = m.unwrap().as_f64()
    if f.is_none() {
        return null
    }
    const whole: i64 = f.unwrap() as i64
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

// ---- Wire values ----

fn lsp_range(idx: &LineIndex, text: String, span: SourceSpan, enc: PositionEncoding) LspRange {
    return .{
        start = idx.to_position(text, span.start, enc),
        end = idx.to_position(text, span.start + span.length, enc),
    }
}

fn severity_code(s: Severity) i32 {
    return s match {
        Error => 1
        Warning => 2
        Info => 3
        Hint => 4
    }
}

// The hint, when there is one, follows the message on its own line: LSP has no member for it.
fn lsp_diagnostic(
    idx: &LineIndex,
    text: String,
    d: &Diagnostic,
    enc: PositionEncoding,
) LspDiagnostic {
    const message = if d.hint.view.len > 0 {
        $"{d.message.view}\n{d.hint.view}"
    } else {
        from_view(d.message.view)
    }
    return .{
        range = lsp_range(idx, text, d.span, enc),
        severity = severity_code(d.severity),
        code = if d.code.len > 0 { Some(d.code) } else { null },
        source = "flang",
        message = move message,
    }
}

// ---- Diagnostics publishing ----

// One publishDiagnostics notification for `uri`. A diagnostic without a location (none_span keeps
// start = 0) lands at the top of the file rather than being hidden. Replaces the hover label,
// releasing what it held: assigning over a live binding leaks it (E2126).
fn set_hover_label(slot: &Option(OwnedString), text: move OwnedString) {
    install(slot, Some(move text))
}

fn publish_file_diags(self: &LspServer, uri: String, text: String, diags: &List(&Diagnostic)) {
    // ponytail: rebuilds a LineIndex per call, so one analysis costs one full scan of every
    // project-origin file (125 of them for the compiler) just to publish diagnostics. `Document`
    // already caches an index for OPEN buffers and invalidates it on change (documents.f), but
    // `text` here is usually an analyzed `unit.sources` entry with no such home. Upgrade path: a
    // `List(LineIndex)` on the project parallel to `unit.sources`, rebuilt with the analysis that
    // replaces them - same invalidation point, no new lifetime. Same fix serves the four other
    // `line_index(text)` builds in this file.
    let idx = line_index(text)
    defer idx.deinit()
    let params = PublishDiagnosticsParams {
        uri = uri,
        diagnostics = diags.map { lsp_diagnostic(&idx, text, it, self.encoding) },
    }
    defer params.deinit()
    self.out.notify("textDocument/publishDiagnostics", &params)
}

// One open buffer's diagnostics: its live parse errors, then what the last analysis found in the
// file. Those keep the positions of the text they were found in until the next save re-checks it,
// so an edit shifts them rather than hiding them.
fn publish_open_file(self: &LspServer, uri: String) {
    const doc = self.docs.get(uri)
    if doc.is_none() {
        return
    }
    const d = doc.unwrap()
    let parsed = parse_doc(d.text.view)
    defer parsed.deinit()
    let diagnostics: List(LspDiagnostic) = list(parsed.diagnostics.len)
    for &x in parsed.diagnostics {
        diagnostics.push(lsp_diagnostic(&d.index, d.text.view, x, self.encoding))
    }
    self.analyzed_diags(d.path.view, &parsed.diagnostics, &diagnostics)
    let params = PublishDiagnosticsParams { uri = uri, diagnostics = move diagnostics }
    defer params.deinit()
    self.out.notify("textDocument/publishDiagnostics", &params)
}

// The last analysis's diagnostics for `path` onto `out`, positioned in the text it analyzed. The
// syntax ones are the live parse's to report: frontend codes (E1xxx), and any it reports itself.
fn analyzed_diags(
    self: &LspServer,
    path: String,
    live: &List(Diagnostic),
    out: &List(LspDiagnostic),
) {
    const pi = if path.len > 0 { self.ws.project_of_path(path) } else { null }
    if pi.is_none() {
        return
    }
    const unit = &self.ws.projects[pi.unwrap()].unit
    const fid = file_id_of(unit, path)
    if fid.is_none() {
        return
    }
    const text = unit.sources[fid.unwrap() as usize].view
    let idx = line_index(text)
    defer idx.deinit()
    for &x in unit.diagnostics {
        const in_file = x.span.file_id == fid.unwrap()
        if !in_file or starts_with(x.code, "E1") or reported(live, x) {
            continue
        }
        out.push(lsp_diagnostic(&idx, text, x, self.encoding))
    }
}

fn reported(live: &List(Diagnostic), d: &Diagnostic) bool {
    for &l in live {
        const same_span = l.span.start == d.span.start and l.span.length == d.span.length
        if same_span and l.code == d.code and l.message.view == d.message.view {
            return true
        }
    }
    return false
}

// The client's URI for `path`: the open document's own spelling when the file is open (so the
// publish lands on the exact buffer), a freshly encoded one otherwise.
fn uri_for_path(self: &LspServer, path: String) OwnedString {
    for entry in self.docs.docs.iter() {
        if entry.value.path.view == path {
            return from_view(entry.key.view)
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
        // Lent for the publish: the unit keeps every diagnostic it holds.
        let file_diags: List(&Diagnostic) = list(0)
        for &d in unit.diagnostics {
            if d.span.file_id == fid as i32 {
                file_diags.push(d)
            }
        }
        const u = self.uri_for_path(unit.file_paths[fid].view)
        self.publish_file_diags(u.view, unit.sources[fid].view, &file_diags)
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
    const create = WorkDoneProgressCreateParams { token = token.view }
    self.out.request(self.next_id, "window/workDoneProgress/create", &create)
    const begin = ProgressParams {
        token = token.view,
        value = WorkDoneProgress { kind = "begin", title = Some(title) },
    }
    self.out.notify("$/progress", &begin)
    return token
}

fn progress_end(self: &LspServer, token: String) {
    const end = ProgressParams {
        token = token,
        value = WorkDoneProgress { kind = "end", title = null },
    }
    self.out.notify("$/progress", &end)
}

// ---- flang/serverStatus ----

// Custom notification for the editor's status-bar item: compiler version, workspace folder names,
// and every open project with its current error count.
fn send_status(self: &LspServer) {
    let projects: List(ProjectStatus) = list(self.ws.projects.len)
    for &p in self.ws.projects {
        projects.push(ProjectStatus {
            name = p.name.view,
            dir = p.dir.view,
            errors = project_error_count(&p.unit),
        })
    }
    let status = ServerStatus {
        version = self.version.view,
        folders = self.folders.map { it.view },
        projects = move projects,
    }
    defer status.deinit()
    self.out.notify("flang/serverStatus", &status)
}

// ---- Lifecycle ----

// The client's `general.positionEncodings` is a preference-ordered list; any occurrence of utf-8
// selects the byte-offset fast path. Absent or without utf-8 (VS Code), utf-16 is the mandatory
// default.
// The member at a dotted path of object keys, or null where the path leaves the object.
fn member_path(params: &Value?, path: String[]) &Value? {
    if params.is_none() {
        return null
    }
    let cur = params.unwrap()
    for key in path {
        const next = get_member(cur, key)
        if next.is_none() {
            return null
        }
        cur = next.unwrap()
    }
    return Some(cur)
}

// `capabilities.textDocument.definition.linkSupport`, false when absent.
fn definition_link_support(params: &Value?) bool {
    const link = member_path(params, ["capabilities", "textDocument", "definition", "linkSupport"])
    return link match {
        Some(v) => v.as_bool() ?? false
        None => false
    }
}

// Whether `capabilities.experimental.commands.commands` lists `name`: the client-side commands a
// server may reference, the convention rust-analyzer established.
fn client_has_command(params: &Value?, name: String) bool {
    const cmds = member_path(params, ["capabilities", "experimental", "commands", "commands"])
    const arr = cmds match {
        Some(v) => v.as_array()
        None => null
    }
    if arr.is_none() {
        return false
    }
    const items = arr.unwrap()
    for i in 0..items.len {
        if (items[i].as_string() ?? "") == name {
            return true
        }
    }
    return false
}

fn negotiate_encoding(params: &Value?) PositionEncoding {
    const encodings = member_path(params, ["capabilities", "general", "positionEncodings"])
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
fn collect_folders(self: &LspServer, params: &Value?) {
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
    const cut = rfind(p.view, '/')
    const name = cut match {
        Some(i) => p.view[(i + 1)..p.view.len]
        None => p.view
    }
    if name.len > 0 {
        self.folders.push(from_view(name))
    }
    p.deinit()
}

// `triggers` are the signature-help trigger characters; the result views them.
fn initialize_result(self: &LspServer, triggers: String[]) InitializeResult {
    let lens: CodeLensOptions? = null
    if self.run_test_command {
        lens = Some(CodeLensOptions { resolve_provider = false })
    }
    return .{ capabilities = ServerCapabilities {
        position_encoding = if is_utf8_encoding(self.encoding) { "utf-8" } else { "utf-16" },
        // TextDocumentSyncKind.Full
        text_document_sync = TextDocumentSyncOptions { open_close = true, change = 1, save = true },
        document_symbol_provider = true,
        folding_range_provider = true,
        workspace_symbol_provider = true,
        hover_provider = true,
        definition_provider = true,
        type_definition_provider = true,
        references_provider = true,
        inlay_hint_provider = true,
        document_formatting_provider = true,
        code_lens_provider = lens,
        signature_help_provider = SignatureHelpOptions { trigger_characters = triggers },
        rename_provider = RenameOptions { prepare_provider = true },
    }, server_info = ServerInfo { name = "flang-lsp", version = self.version.view } }
}

fn is_utf8_encoding(enc: PositionEncoding) bool {
    return enc match { Utf8 => true, else => false }
}

fn on_initialize(self: &LspServer, msg: &RpcMessage) {
    self.encoding = negotiate_encoding(msg.params())
    self.definition_links = definition_link_support(msg.params())
    self.run_test_command = client_has_command(msg.params(), "flang.runTest")
    self.collect_folders(msg.params())
    if msg.id().is_none() {
        return
    }
    const triggers = ["(", ","]
    const result = self.initialize_result(triggers)
    self.out.respond(msg.id().unwrap(), &result)
}

fn on_shutdown(self: &LspServer, msg: &RpcMessage) {
    self.shutdown_requested = true
    if msg.id().is_some() {
        const nul = Value.Null
        self.out.respond(msg.id().unwrap(), &nul)
    }
}

fn on_exit(self: &LspServer) {
    self.exit_code = Some(if self.shutdown_requested { 0 } else { 1 })
}

fn on_unknown(self: &LspServer, msg: &RpcMessage) {
    if msg.is_request() {
        self.out.respond_error(msg.id().unwrap(), METHOD_NOT_FOUND, "unknown method")
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

    self.publish_open_file(uri.unwrap())
    const doc = self.docs.get(uri.unwrap())
    if doc.is_some() and doc.unwrap().path.view.len > 0 {
        self.ensure_project(doc.unwrap().path.view)
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
    // Fresh parse errors while typing, beside the last analysis's; the type tier catches up on
    // save.
    self.publish_open_file(uri.unwrap())
}

fn on_did_save(self: &LspServer, msg: &RpcMessage) {
    const uri = doc_uri(msg)
    if uri.is_none() {
        return
    }
    const doc = self.docs.get(uri.unwrap())
    if doc.is_none() or doc.unwrap().path.view.len == 0 {
        return
    }
    const path = doc.unwrap().path.view

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
    const root = self.ws.stdlib_path.view
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
    const text = $"FLang: stdlib not found at `{self.ws.stdlib_path.view}`; type checking is disabled. Set flang.stdlibPath or pass -s."
    defer text.deinit()
    // MessageType.Warning
    const params = ShowMessageParams { type_ = 2, message = text.view }
    self.out.notify("window/showMessage", &params)
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

    const base = rfind(d.view, '/') match {
        Some(i) => d.view[(i + 1)..d.view.len]
        None => d.view
    }
    const title = $"FLang: checking {base}"
    const token = self.progress_begin(title.view)
    title.deinit()
    const idx = open_project(&self.ws, d.view, &self.docs)
    self.progress_end(token.view)
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
    const title = $"FLang: checking {self.ws.projects[pi].name.view}"
    const token = self.progress_begin(title.view)
    title.deinit()
    reanalyze_project(&self.ws, pi, dirty, &self.docs)
    self.progress_end(token.view)
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

        if ends_with(path.view, "/flang.toml") {
            const owner = self.ws.find_project(parent_dir(path.view))
            if owner.is_some() {
                reopen[owner.unwrap()] = true
            }
            path.deinit()
            continue
        }

        const owner = self.ws.project_of_path(path.view)
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
        if self.is_open_path(path.view) {
            path.deinit()
            continue
        }
        touched_owner.push(owner.unwrap())
        touched.push(path)
    }

    for pi in 0..self.ws.projects.len {
        if reopen[pi] {
            const title = $"FLang: checking {self.ws.projects[pi].name.view}"
            const token = self.progress_begin(title.view)
            title.deinit()
            const ok = reopen_project(&self.ws, pi, &self.docs)
            self.progress_end(token.view)
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
                dirty.add(touched[i].view)
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
        if entry.value.path.view == path {
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
    const doc = if uri.is_some() { self.docs.get(uri.unwrap()) } else { null }
    if doc.is_none() {
        self.respond_null(msg)
        return
    }
    const d = doc.unwrap()
    let parsed = parse_doc(d.text.view)
    defer parsed.deinit()
    let syms = document_symbols(&parsed.module)
    defer syms.deinit()
    let out = lsp_symbols(&syms, &d.index, d.text.view, self.encoding)
    defer out.deinit()
    self.out.respond(msg.id().unwrap(), &out)
}

fn lsp_symbols(
    syms: &List(DocSymbol),
    idx: &LineIndex,
    text: String,
    enc: PositionEncoding,
) List(DocumentSymbol) {
    let out: List(DocumentSymbol) = list(syms.len)
    for &s in syms {
        const range = lsp_range(idx, text, s.span, enc)
        out.push(DocumentSymbol {
            name = s.name.view,
            kind = s.kind as i32,
            range = range,
            selection_range = range,
            children = lsp_children(s, idx, text, enc),
        })
    }
    return out
}

fn lsp_children(
    s: &DocSymbol,
    idx: &LineIndex,
    text: String,
    enc: PositionEncoding,
) List(DocumentSymbol)? {
    if s.children.len == 0 {
        return null
    }
    return Some(lsp_symbols(&s.children, idx, text, enc))
}

fn on_folding_range(self: &LspServer, msg: &RpcMessage) {
    if !msg.is_request() {
        return
    }
    const uri = doc_uri(msg)
    const doc = if uri.is_some() { self.docs.get(uri.unwrap()) } else { null }
    if doc.is_none() {
        self.respond_null(msg)
        return
    }
    let folds = folding_ranges(doc.unwrap().text.view)
    defer folds.deinit()
    let out = folds.map { f => FoldingRange { start_line = f.start_line, end_line = f.end_line } }
    defer out.deinit()
    self.out.respond(msg.id().unwrap(), &out)
}

// ---- textDocument/codeLens ----

// A "Run test" lens on every `test {}` block, parse-only like the outline. The command's one
// argument is `{dir, file, name}`: the project directory, the file relative to it, and the label -
// what `flang test <file> --name <name>` run from `dir` needs. A buffer outside any project gets no
// lenses: there is nothing to run it with.
fn on_code_lens(self: &LspServer, msg: &RpcMessage) {
    if !msg.is_request() {
        return
    }
    const uri = doc_uri(msg)
    const doc = if uri.is_some() { self.docs.get(uri.unwrap()) } else { null }
    const dir = if doc.is_some() { self.test_dir(doc.unwrap().path.view) } else { null }
    let lenses: List(CodeLens) = list(0)
    defer lenses.deinit()
    if dir.is_none() {
        self.out.respond(msg.id().unwrap(), &lenses)
        return
    }

    let dv = dir.unwrap()
    defer dv.deinit()
    const d = doc.unwrap()
    let parsed = parse_doc(d.text.view)
    defer parsed.deinit()
    const file = d.path.view[(dv.view.len + 1)..d.path.view.len]
    for &decl in parsed.module.decls {
        decl.* match {
            Test(t) => {
                let arguments: List(TestTarget) = list(1)
                arguments.push(TestTarget { dir = dv.view, file = file, name = t.label })
                lenses.push(CodeLens {
                    range = lsp_range(&d.index, d.text.view, t.span, self.encoding),
                    command = RunTestCommand {
                        title = "Run test",
                        command = "flang.runTest",
                        arguments = move arguments,
                    },
                })
            }
            _ => {}
        }
    }
    self.out.respond(msg.id().unwrap(), &lenses)
}

// The project directory a test in `path` runs from: the open project's, else the nearest
// manifest's.
fn test_dir(self: &LspServer, path: String) OwnedString? {
    if path.len == 0 {
        return null
    }
    return self.ws.project_of_path(path) match {
        Some(pi) => Some(from_view(self.ws.projects[pi].dir.view))
        None => project_dir_for(path)
    }
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

    let out: List(SymbolInformation) = list(0)
    defer out.deinit()
    for pi in 0..self.ws.projects.len {
        self.project_symbols(pi, query, &out)
    }
    self.out.respond(msg.id().unwrap(), &out)
}

// SymbolInformation entries for one project's matches onto `out`, grouped by file so the line index
// is built once per file that has any.
fn project_symbols(self: &LspServer, pi: ProjectId, query: String, out: &List(SymbolInformation)) {
    const unit = &self.ws.projects[pi].unit
    const index = &self.ws.projects[pi].index
    for fid in 0..index.len {
        let any = false
        for &s in index[fid].symbols {
            if symbol_matches(s.name.view, query) {
                any = true
            }
        }
        if !any {
            continue
        }

        const text = unit.sources[fid].view
        let lidx = line_index(text)
        const u = self.uri_for_path(unit.file_paths[fid].view)
        for &s in index[fid].symbols {
            if !symbol_matches(s.name.view, query) {
                continue
            }
            let container: String? = null
            if s.container.view.len > 0 {
                container = Some(s.container.view)
            }
            out.push(SymbolInformation {
                name = s.name.view,
                kind = s.kind as i32,
                container_name = container,
                location = Location {
                    uri = from_view(u.view),
                    range = lsp_range(&lidx, text, s.span, self.encoding),
                },
            })
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
    if doc.is_none() or doc.unwrap().path.view.len == 0 {
        return null
    }
    const pi = self.ws.project_of_path(doc.unwrap().path.view)
    if pi.is_none() {
        return null
    }
    const fid = file_id_of(&self.ws.projects[pi.unwrap()].unit, doc.unwrap().path.view)
    if fid.is_none() {
        return null
    }
    return Some(ReqCtx { pi = pi.unwrap(), fid = fid.unwrap() })
}

// A `{line, character}` object as a Position, or null when either field is missing.
fn pos_of(v: &Value) Position? {
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
    const text = self.ws.projects[pi].unit.sources[fid as usize].view
    let idx = line_index(text)
    const off = idx.to_offset(text, pos.unwrap(), self.encoding)
    idx.deinit()
    return Some(Cursor { pi = pi, fid = fid, offset = off })
}

fn respond_null(self: &LspServer, msg: &RpcMessage) {
    const nul = Value.Null
    self.out.respond(msg.id().unwrap(), &nul)
}

// One LSP LocationLink from `origin` (in the requesting file) to `target`, both resolved inside
// project `pi`. The target's range doubles as its selection range.
fn span_link(self: &LspServer, pi: ProjectId, origin: SourceSpan, target: SourceSpan) LocationLink {
    const unit = &self.ws.projects[pi].unit
    const origin_text = unit.sources[origin.file_id as usize].view
    let origin_idx = line_index(origin_text)
    defer origin_idx.deinit()
    const target_text = unit.sources[target.file_id as usize].view
    let target_idx = line_index(target_text)
    defer target_idx.deinit()
    const range = lsp_range(&target_idx, target_text, target, self.encoding)
    return .{
        origin_selection_range = lsp_range(&origin_idx, origin_text, origin, self.encoding),
        target_uri = self.uri_for_path(unit.file_paths[target.file_id as usize].view),
        target_range = range,
        target_selection_range = range,
    }
}

// One LSP Location for `span`, resolved inside project `pi` (the span's file id indexes that
// project's unit).
fn span_location(self: &LspServer, pi: ProjectId, span: SourceSpan) Location {
    const unit = &self.ws.projects[pi].unit
    const fid = span.file_id as usize
    const text = unit.sources[fid].view
    let idx = line_index(text)
    defer idx.deinit()
    return .{
        uri = self.uri_for_path(unit.file_paths[fid].view),
        range = lsp_range(&idx, text, span, self.encoding),
    }
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
    const text = self.ws.projects[pi].unit.sources[span.file_id as usize].view
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

// `F` hovers with what constrains it: `F where F: fn(T, T) Ord`.
fn append_bound(result: &TypeCheckResult, ty: Ty, hit: &TemplateHit, rendered: &OwnedString) {
    const v = result.interner.node(ty) match {
        NVar(tv) => tv.id
        _ => return
    }
    const bound = hit.bounds.get_ref(v)
    const name = hit.names.get(v)
    if bound.is_none() or name.is_none() {
        return
    }
    const joined = $"{rendered.view} where {name.unwrap()}: {bound.unwrap().view}"
    replace(rendered, joined).deinit()
}

// Whether a type reference names a type parameter, which hovers as `typevar T`: neither `Self`,
// whose declaration is the type it names, nor an associated type, declared `type Item`.
fn is_type_param_ref(
    result: &TypeCheckResult,
    target: &ResolvedTarget,
    word: String,
    decl_text: String,
) bool {
    const is_type_ref = target.* match {
        RtType(_) => true
        _ => false
    }
    return is_type_ref and word != "Self" and !decl_text.starts_with("type ")
        and !names_nominal(result, target)
}

// A variant reads `E.Some(T)`, a field `field x: i32`; any other declaration as written.
fn target_label(result: &TypeCheckResult, target: &ResolvedTarget, slice: String) OwnedString {
    return target.* match {
        RtEnumVariant(nom, _) => result.nominals.find(nom) match {
            Some(def) => def.* match {
                NomEnum(ed) => $"{short_name(ed.fqn)}.{slice}"
                NomStruct(_) => from_view(slice)
            }
            None => from_view(slice)
        }
        RtStructField(_, _) => $"field {slice}"
        _ => from_view(slice)
    }
}

// The docstring of the declaration at `span` - the comment run glued above its first token.
fn doc_for(self: &LspServer, pi: ProjectId, span: SourceSpan) OwnedString? {
    if !self.location_span_ok(pi, span) {
        return null
    }
    return doc_above(self.ws.projects[pi].unit.sources[span.file_id as usize].view, span.start)
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
    const text = unit.sources[fid as usize].view

    // An import names one file: its path, with that module's docstring. Never falls through - a
    // path segment like `list` would otherwise hover as every declaration of that name.
    const imp = import_at(&unit.modules[fid as usize], offset)
    if imp.is_some() {
        let ref = imp.unwrap()
        defer ref.deinit()
        const target = file_id_of_fqn(unit, ref.path.view)
        const doc: OwnedString? = if target.is_some() {
            module_doc(unit.sources[target.unwrap() as usize].view)
        } else {
            null
        }
        self.respond_hover(msg, $"import {ref.path.view}", doc, text, ref.span)
        return
    }

    // The compile-time context in a `#if` head hovers as the `core.comptime` declaration it reads
    // as: `const platform: Platform`, `field os: String`.
    const ct = comptime_at(result, text, fid, offset)
    if ct.is_some() {
        const hit = ct.unwrap()
        const doc = self.doc_for(pi, hit.decl)
        const label = if hit.binding.is_some() {
            $"const {hit.binding.unwrap()}"
        } else {
            $"field {self.decl_label(pi, hit.decl) ?? ""}"
        }
        self.respond_hover(msg, label, doc, text, hit.word)
        return
    }

    // A generator's `#name` hovers as its `#define` and what the expansion declared.
    const hashed = identifier_at(text, offset) match {
        Some(w) => starts_with(w.name, "#") and w.name != "#if"
        None => false
    }
    const extra = if hashed { generator_hover(unit, fid, offset) } else { null }
    if extra.is_some() {
        const x = extra.unwrap()
        const span = x.span
        const md = x.markdown()
        x.deinit()
        self.respond_markdown(msg, md, text, span)
        return
    }

    const word = identifier_at(text, offset)
    if word.is_none() {
        self.respond_null(msg)
        return
    }
    const wstart = word.unwrap().start
    const wname = word.unwrap().name

    // The `context` keyword as an expression (`context.f`, `context(..)`, a copy) is the current
    // context; before a name it declares a field, which has nothing to show.
    if wname == "context" and !declares_field(text, wstart + wname.len) {
        const kw = SourceSpan { file_id = fid, start = wstart, length = wname.len }
        self.respond_hover(msg, context_label(result), null, text, kw)
        return
    }

    const tg = target_at(result, fid, offset)
    // Inside a generic body, the types its rigid check gave (`cmp: F`) answer before one
    // instantiation's (`cmp: fn(i32, i32) Ord`), for a node that is the word itself: a callee's
    // call node answers with its declaration below.
    const tmpl = template_type_at(&unit.checker, fid, offset)
    const from_tmpl = tmpl.is_some() and tmpl.unwrap().span.start == wstart
        and tmpl.unwrap().span.length == wname.len
    const th = if from_tmpl {
        Some(TypedHit { node = 0 as NodeId, span = tmpl.unwrap().span, ty = tmpl.unwrap().ty })
    } else {
        typed_at(result, fid, offset)
    }

    let label: OwnedString? = null
    // The declaration whose docstring joins the label, when the label came from one.
    let doc_span: SourceSpan? = null

    // A resolved target answers when its node is anchored to the word: starting at it (reads,
    // callees), ending at it (enum variant refs `Color.Red`), or - for function targets only -
    // containing it with a matching name (a UFCS call node spans the receiver too). Locals fall
    // through to the typed branch, whose `name: T` form beats a declaration slice; a local target
    // with no type at the word is a type reference (`I.Item`, RFC-036) and shows its declaration.
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
                // A payload variant's construction spans its arguments: `Dir.Up(1)`.
                RtEnumVariant(_, _) => name_offset(text, tspan, wname, false) == Some(wstart)
                _ => false
            }
        }
        const is_local = target match {
            RtLocal(_) => true
            _ => false
        }
        const typed_here = th.is_some() and th.unwrap().span.start == wstart
        if accept and (!is_local or !typed_here) {
            const dspan = cursor_decl_span(result, &tg.unwrap(), text, wstart, wend)
            if dspan.is_some() and self.location_span_ok(pi, dspan.unwrap()) {
                const l = self.decl_label(pi, dspan.unwrap())
                if l.is_some() and is_type_param_ref(result, &target, wname, l.unwrap()) {
                    set_hover_label(&label, $"typevar {wname}")
                } else if l.is_some() {
                    set_hover_label(&label, target_label(result, &target, l.unwrap()))
                    doc_span = dspan
                }
            }
        }
    }

    if label.is_none() and th.is_some() and th.unwrap().span.start == wstart {
        const ty = th.unwrap().ty
        const vars = if from_tmpl { tmpl.unwrap().names } else { type_param_names(&unit.checker) }
        if renderable_ty(result, ty, vars) and !is_void_ty(result, ty) {
            let rendered = render_ty(result, ty, Some(vars))
            if from_tmpl {
                append_bound(result, ty, &tmpl.unwrap(), &rendered)
            }
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
                set_hover_label(&label, $"{intro.unwrap()} {wname}: {rendered.view}")
                rendered.deinit()
            } else if th.unwrap().span.length == wname.len {
                set_hover_label(&label, $"{wname}: {rendered.view}")
                rendered.deinit()
            } else {
                set_hover_label(&label, rendered)
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
            set_hover_label(&label, $"field {wname}: {rendered.view}")
            rendered.deinit()
            doc_span = Some(fh.unwrap().decl_span)
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
            set_hover_label(&label, $"{b.intro} {wname}: {slice}")
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
            let rh = self.registry_hover(pi, wname)
            if rh.is_some() {
                let hover = rh.unwrap()
                doc_span = hover.sole
                set_hover_label(&label, hover.label)
            }
        }
    }

    if label.is_none() {
        self.respond_null(msg)
        return
    }
    const doc = if doc_span.is_some() { self.doc_for(pi, doc_span.unwrap()) } else { null }
    self.respond_hover(msg, label.unwrap(), doc, text, span)
}

// `context: Context`, then every field of the program's context with its type and declaring module.
// The compiler assembles `Context` from the `context` declarations, so no source lists them.
fn context_label(result: &TypeCheckResult) OwnedString {
    let sb = string_builder(256)
    sb.append("context: Context")
    const id = result.nominals.by_fqn.get(FQN_CONTEXT)
    const def = if id.is_some() { result.nominals.find(id.unwrap()) } else { null }
    if def.is_some() {
        def.unwrap().* match {
            NomStruct(sd) => context_fields_into(&sb, result, &sd)
            NomEnum(_) => {}
        }
    }
    const out = sb.to_string()
    sb.deinit()
    return out
}

fn context_fields_into(sb: &StringBuilder, result: &TypeCheckResult, sd: &StructDef) {
    if sd.fields.len == 0 {
        return
    }
    sb.append("\n\ntype Context = struct {")
    for i in 0..sd.fields.len {
        const f = &sd.fields[i]
        const ty = render_ty(result, f.ty)
        sb.append("\n    ")
        sb.append(f.name)
        sb.append(": ")
        sb.append(ty.view)
        ty.deinit()
        if i < result.context_fields.len {
            const fqn = result.context_fields[i].view
            const dot = rfind(fqn, '.')
            if dot.is_some() {
                sb.append(" // ")
                sb.append(fqn[0..dot.unwrap()])
            }
        }
    }
    sb.append("\n}")
}

// Whether an identifier follows `at` past spaces: `context name: T` declares a context field.
fn declares_field(text: String, at: usize) bool {
    let i = at
    while i < text.len and (text[i] == ' ' or text[i] == '\t') {
        i = i + 1
    }
    return i < text.len and is_ident_char(text[i])
}

// The hover response: `label` as a flang code block, the docstring `doc` rendered as markdown below
// it, over `span` in `text`. Consumes both.
fn respond_hover(
    self: &LspServer,
    msg: &RpcMessage,
    label: move OwnedString,
    doc: move OwnedString?,
    text: String,
    span: SourceSpan,
) {
    const none: OwnedString? = null
    const md = hover_markdown(label.view, &doc, &none)
    label.deinit()
    if doc.is_some() {
        doc.unwrap().deinit()
    }
    self.respond_markdown(msg, md, text, span)
}

fn respond_markdown(
    self: &LspServer,
    msg: &RpcMessage,
    md: move OwnedString,
    text: String,
    span: SourceSpan,
) {
    let lidx = line_index(text)
    defer lidx.deinit()
    let hover = Hover {
        contents = MarkupContent { kind = "markdown", value = move md },
        range = lsp_range(&lidx, text, span, self.encoding),
    }
    defer hover.deinit()
    self.out.respond(msg.id().unwrap(), &hover)
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

// Those declarations as stacked labels, capped so a wide overload set stays readable. `sole` is the
// one declaration when the name has exactly one - the docstring belongs to it alone.
type RegistryHover = struct {
    label: OwnedString
    sole: SourceSpan?
}

fn registry_hover(self: &LspServer, pi: ProjectId, name: String) RegistryHover? {
    let spans = self.registry_decl_spans(pi, name)
    defer spans.deinit()
    let sb = string_builder(128)
    let count: usize = 0
    let shown: usize = 0
    let sole: SourceSpan? = null
    for &span in spans {
        const l = self.decl_label(pi, span.*)
        if l.is_none() {
            continue
        }
        count = count + 1
        sole = if count == 1 { Some(span.*) } else { null }
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
    return Some(RegistryHover { label = move out, sole = sole })
}

// ---- textDocument/definition ----

// Resolution order: an `import` under the cursor goes to the file it names; else the checker's
// resolved target at the cursor (locals, params, functions, fields, variants, consts); then a
// name-level ModuleIndex lookup across the workspace, which covers everything the checker records
// no use-edge for - type names, template `#name`s.
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

    let locs: List(Location) = list(0)
    defer locs.deinit()

    const text = unit.sources[fid as usize].view

    // An import names one file: answer with its start, and never fall through to the name tiers - a
    // path segment like `list` would otherwise match every declaration of that name. As a
    // LocationLink when the client takes one, so the whole dotted path highlights as the origin.
    const imp = import_at(&unit.modules[fid as usize], offset)
    if imp.is_some() {
        let ref = imp.unwrap()
        defer ref.deinit()
        const target = file_id_of_fqn(unit, ref.path.view)
        if target.is_some() {
            const start = SourceSpan { file_id = target.unwrap(), start = 0, length = 0 }
            if self.definition_links {
                let links: List(LocationLink) = list(1)
                defer links.deinit()
                links.push(self.span_link(pi, ref.span, start))
                self.out.respond(msg.id().unwrap(), &links)
                return
            }
            locs.push(self.span_location(pi, start))
        }
        self.out.respond(msg.id().unwrap(), &locs)
        return
    }

    // The compile-time context in a `#if` head goes to the `core.comptime` declaration.
    const ct = comptime_at(result, text, fid, offset)
    if ct.is_some() {
        if self.location_span_ok(pi, ct.unwrap().decl) {
            locs.push(self.span_location(pi, ct.unwrap().decl))
        }
        self.out.respond(msg.id().unwrap(), &locs)
        return
    }

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
            locs.push(self.span_location(pi, span.unwrap()))
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
                locs.push(self.span_location(pi, fh.unwrap().decl_span))
                found = true
            }
            const wend = wstart + wname.len
            const call_shaped = wend < text.len and text[wend] == '('
            if !found and (!is_member or call_shaped) {
                if !self.registry_matches(pi, wname, &locs) {
                    self.index_matches(wname, &locs)
                }
            }
        }
    }

    self.out.respond(msg.id().unwrap(), &locs)
}

// Those declarations as Locations onto `out`. Returns whether anything matched.
fn registry_matches(self: &LspServer, pi: ProjectId, name: String, out: &List(Location)) bool {
    let spans = self.registry_decl_spans(pi, name)
    defer spans.deinit()
    for &span in spans {
        out.push(self.span_location(pi, span.*))
    }
    return spans.len > 0
}

// Every workspace index symbol named exactly `name`, as Locations onto `out`.
fn index_matches(self: &LspServer, name: String, out: &List(Location)) {
    for pi in 0..self.ws.projects.len {
        const index = &self.ws.projects[pi].index
        for fid in 0..index.len {
            for &s in index[fid].symbols {
                if s.name.view != name {
                    continue
                }
                if self.location_span_ok(pi, s.span) {
                    out.push(self.span_location(pi, s.span))
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

    let locs: List(Location) = list(1)
    defer locs.deinit()
    const th = typed_at(result, fid, cur.unwrap().offset)
    if th.is_some() {
        const span = nominal_decl_span(result, th.unwrap().ty)
        if span.is_some() and self.location_span_ok(pi, span.unwrap()) {
            locs.push(self.span_location(pi, span.unwrap()))
        }
    }
    self.out.respond(msg.id().unwrap(), &locs)
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
        const text = unit.sources[fid as usize].view
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

    let locs: List(Location) = list(0)
    defer locs.deinit()
    for &t in targets {
        if include_decl {
            // ponytail: an RtConst target double-lists its decl (the ConstDecl node carries its own
            // RtConst edge); dedupe if it ever annoys.
            const ds = target_decl_span(result, t)
            if ds.is_some() and self.location_span_ok(pi, ds.unwrap()) {
                locs.push(self.span_location(pi, ds.unwrap()))
            }
        }
        let spans = reference_spans(result, t)
        for &s in spans {
            if self.location_span_ok(pi, s.*) {
                locs.push(self.span_location(pi, s.*))
            }
        }
        spans.deinit()
    }
    self.out.respond(msg.id().unwrap(), &locs)
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
    self.out.request(self.next_id, "workspace/inlayHint/refresh")
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
    const atext = unit.sources[fid as usize].view
    const uri = doc_uri(msg)
    const doc = if uri.is_some() { self.docs.get(uri.unwrap()) } else { null }
    // The text positions are computed against: the live buffer when open, else the analyzed text.
    const text = if doc.is_some() { doc.unwrap().text.view } else { atext }
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
    let hints: List(InlayHint) = list(0)
    defer hints.deinit()
    for &site in sites {
        if site.offset < lo or site.offset > hi {
            continue
        }
        const ty = type_of_node(result, site.node)
        if ty.is_none() or !renderable_ty(result, ty.unwrap(), vars)
            or is_void_ty(result, ty.unwrap()) {
            continue
        }
        const rendered = render_ty(result, ty.unwrap(), Some(vars))
        hints.push(InlayHint {
            position = lidx.to_position(text, site.offset, self.encoding),
            label = $": {rendered.view}",
            // InlayHintKind.Type
            kind = 1,
        })
        rendered.deinit()
    }
    self.out.respond(msg.id().unwrap(), &hints)
}

fn range_bound(range: &Value, key: String) Position? {
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
    const text = doc.unwrap().text.view
    const offset = doc.unwrap().index.to_offset(text, pos.unwrap(), self.encoding)

    const site = call_site_at(text, offset)
    if site.is_none() {
        self.respond_null(msg)
        return
    }
    let cs = site.unwrap()
    const result = &self.ws.projects[pi].unit.result
    const overloads = result.functions.by_name.get_ref(cs.name.view)
    if overloads.is_none() or overloads.unwrap().len == 0 {
        cs.deinit()
        self.respond_null(msg)
        return
    }

    let signatures: List(SignatureInformation) = list(0)
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
        defer params.deinit()
        // The first overload that still has a parameter slot for the active index wins the
        // highlight; 0 otherwise.
        if !active_found and params.len > cs.active {
            active_sig = signatures.len
            active_found = true
        }
        signatures.push(SignatureInformation {
            label = label.unwrap(),
            parameters = params.map { ParameterInformation { label = it } },
        })
    }
    let help = SignatureHelp {
        signatures = move signatures,
        active_signature = active_sig,
        active_parameter = cs.active,
    }
    defer help.deinit()
    self.out.respond(msg.id().unwrap(), &help)
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
    const text = doc.unwrap().text.view

    let cfg = default_config()
    // The project name is owned here so the config's view of it outlives the format.
    let project = if doc.unwrap().path.view.len > 0 {
        apply_project_fmt(doc.unwrap().path.view, &cfg)
    } else {
        from_view("")
    }
    defer project.deinit()
    set_project(&cfg, project.view)

    const res = format_source(text, &cfg)
    if res.is_err() {
        self.respond_null(msg)
        return
    }
    let formatted = res.unwrap()
    defer formatted.deinit()

    let edits: List(TextEdit) = list(1)
    defer edits.deinit()
    if formatted.view != text {
        const whole = SourceSpan { file_id = 0, start = 0, length = text.len }
        edits.push(TextEdit {
            range = lsp_range(&doc.unwrap().index, text, whole, self.encoding),
            new_text = formatted.view,
        })
    }
    self.out.respond(msg.id().unwrap(), &edits)
}

// The `[fmt]` table of the manifest governing `path`, applied onto `cfg`. Unknown keys are silently
// ignored - `flang fmt` already warns about them on the command line. Returns the project's name,
// for `set_project`; empty without a manifest.
fn apply_project_fmt(path: String, cfg: &FmtConfig) OwnedString {
    const dir = project_dir_for(path)
    if dir.is_none() {
        return from_view("")
    }
    let d = dir.unwrap()
    const manifest = $"{d.view}/flang.toml"
    d.deinit()
    const got = read_text(manifest.view)
    manifest.deinit()
    if got.is_none() {
        return from_view("")
    }
    let toml = got.unwrap()
    defer toml.deinit()
    const parsed = parse_project(toml.view)
    if parsed.is_err() {
        return from_view("")
    }
    let proj = parsed.unwrap()
    defer proj.deinit()
    for &e in proj.fmt {
        const _ok = set_option(cfg, e.key.view, e.value.view)
    }
    return from_view(proj.name.view)
}

// ---- textDocument/prepareRename, textDocument/rename ----

// LSP's RequestFailed: the request was valid, the server refuses it. The client shows the message.
const REQUEST_FAILED: i64 = -32803

// The renameable symbol under a request's cursor: the project that resolved it, the symbol, and the
// cursor's word in the analyzed source.
type RenameSite = struct {
    pi: ProjectId
    sym: Symbol
    word: SourceSpan
    name: String
}

// Rename answers from the last analysis, so every buffer it touches must match the text analyzed; a
// refusal is the reason, for the client to show.
fn rename_site(self: &LspServer, msg: &RpcMessage) Result(RenameSite, String) {
    const cur = self.cursor_at(msg)
    if cur.is_none() {
        return Err("rename needs the file to be part of an analyzed project")
    }
    const pi = cur.unwrap().pi
    const fid = cur.unwrap().fid
    const unit = &self.ws.projects[pi].unit
    const text = unit.sources[fid as usize].view
    if self.is_stale(unit.file_paths[fid as usize].view, text) {
        return Err("save the file before renaming: the rename works on the last check")
    }
    const word = identifier_at(text, cur.unwrap().offset)
    if word.is_none() {
        return Err("no symbol under the cursor")
    }
    const wstart = word.unwrap().start
    const wname = word.unwrap().name
    if starts_with(wname, "#") {
        return Err("a template name cannot be renamed")
    }
    const sym = symbol_at(unit, fid, wstart, wname)
    if sym.is_none() {
        return Err("no renameable symbol under the cursor")
    }
    const decl_path = unit.file_paths[sym.unwrap().decl.file_id as usize].view
    if !self.workspace_origin(decl_path) {
        return Err(
            "the symbol is declared outside the workspace's projects (stdlib or a dependency)",
        )
    }
    if is_foreign_symbol(&unit.result, &sym.unwrap()) {
        return Err("a #foreign declaration keeps the C name it binds")
    }
    const span = SourceSpan { file_id = fid, start = wstart, length = wname.len }
    return Ok(RenameSite { pi = pi, sym = sym.unwrap(), word = span, name = wname })
}

// Whether an open buffer of `path` holds anything but `analyzed`.
fn is_stale(self: &LspServer, path: String, analyzed: String) bool {
    for entry in self.docs.docs.iter() {
        if entry.value.path.view == path {
            return entry.value.text.view != analyzed
        }
    }
    return false
}

// Whether some open project counts `path` among its own files.
fn workspace_origin(self: &LspServer, path: String) bool {
    for &p in self.ws.projects {
        const fid = file_id_of(&p.unit, path)
        if fid.is_none() {
            continue
        }
        const i = fid.unwrap() as usize
        if i < p.unit.project_origin.len and p.unit.project_origin[i] {
            return true
        }
    }
    return false
}

fn on_prepare_rename(self: &LspServer, msg: &RpcMessage) {
    if !msg.is_request() {
        return
    }
    const site = self.rename_site(msg)
    if site.is_err() {
        self.out.respond_error(msg.id().unwrap(), REQUEST_FAILED, site.unwrap_err())
        return
    }
    const s = site.unwrap()
    const text = self.ws.projects[s.pi].unit.sources[s.word.file_id as usize].view
    let lidx = line_index(text)
    defer lidx.deinit()
    const result = PrepareRenameResult {
        range = lsp_range(&lidx, text, s.word, self.encoding),
        placeholder = s.name,
    }
    self.out.respond(msg.id().unwrap(), &result)
}

// Every open project that loads the declaring file resolves the symbol on its own and contributes
// its edits; files shared between projects are merged by path and offset.
fn on_rename(self: &LspServer, msg: &RpcMessage) {
    if !msg.is_request() {
        return
    }
    const p = msg.params()
    const new_name = if p.is_some() { get_str(p.unwrap(), "newName") ?? "" } else { "" }
    if !is_identifier(new_name) {
        self.out.respond_error(
            msg.id().unwrap(),
            INVALID_PARAMS,
            "the new name is not an identifier",
        )
        return
    }
    const site = self.rename_site(msg)
    if site.is_err() {
        self.out.respond_error(msg.id().unwrap(), REQUEST_FAILED, site.unwrap_err())
        return
    }
    const s = site.unwrap()
    let files: List(FileEdits) = list(4)
    defer files.deinit()
    self.collect_rename(&s, &files)
    for &f in files {
        if self.is_stale(f.path, f.text) {
            self.out.respond_error(
                msg.id().unwrap(),
                REQUEST_FAILED,
                "save every file the rename touches first: the rename works on the last check",
            )
            return
        }
    }
    let changes: List(TextDocumentEdit) = list(files.len)
    for &f in files {
        changes.push(self.document_edit(f, s.name.len, new_name))
    }
    let edit = WorkspaceEdit { document_changes = move changes }
    defer edit.deinit()
    self.out.respond(msg.id().unwrap(), &edit)
}

// One file's rename sites: its path and analyzed text (views into a project unit) and the name's
// start offsets.
type FileEdits = struct {
    path: String
    text: String
    starts: List(usize)
}

pub fn deinit(self: move FileEdits) {
    self.starts.deinit()
}

fn collect_rename(self: &LspServer, s: &RenameSite, files: &List(FileEdits)) {
    const home = &self.ws.projects[s.pi].unit
    const decl_path = home.file_paths[s.sym.decl.file_id as usize].view
    for qi in 0..self.ws.projects.len {
        const unit = &self.ws.projects[qi].unit
        let sym: Symbol? = Some(s.sym)
        if qi != s.pi {
            sym = project_symbol(unit, decl_path, s.sym.decl.start, s.name)
        }
        if sym.is_none() {
            continue
        }
        let spans = symbol_edits(unit, &sym.unwrap(), s.name)
        for &span in spans {
            const fid = span.file_id as usize
            add_file_edit(files, unit.file_paths[fid].view, unit.sources[fid].view, span.start)
        }
        spans.deinit()
    }
}

// The symbol declared at `start` in `path`, as project `unit` resolves it; null when the project
// does not load the file.
fn project_symbol(unit: &AnalyzedProject, path: String, start: usize, name: String) Symbol? {
    const fid = file_id_of(unit, path)
    if fid.is_none() {
        return null
    }
    return symbol_at(unit, fid.unwrap(), start, name)
}

fn add_file_edit(files: &List(FileEdits), path: String, text: String, start: usize) {
    for &f in files {
        if f.path != path {
            continue
        }
        for st in f.starts {
            if st == start {
                return
            }
        }
        f.starts.push(start)
        return
    }
    let starts: List(usize) = list(4)
    starts.push(start)
    files.push(FileEdits { path = path, text = text, starts = move starts })
}

// The edits replacing the `len`-byte name at each of `f`'s offsets.
fn document_edit(self: &LspServer, f: &FileEdits, len: usize, new_name: String) TextDocumentEdit {
    let lidx = line_index(f.text)
    defer lidx.deinit()
    let edits: List(TextEdit) = list(f.starts.len)
    for st in f.starts {
        const span = SourceSpan { file_id = 0, start = st, length = len }
        edits.push(TextEdit {
            range = lsp_range(&lidx, f.text, span, self.encoding),
            new_text = new_name,
        })
    }
    return .{
        text_document = EditedDocument { uri = self.uri_for_path(f.path), version = Value.Null },
        edits = move edits,
    }
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
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-16\",\"utf-8\"]}}}}",
    )

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
    assert_true(
        contains(out.as_view(), "\"workspaceSymbolProvider\":true"),
        "workspace symbols advertised",
    )
}

test "initialize falls back to utf-16" {
    let input = string_builder(256)
    defer input.deinit()
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{}}}",
    )

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
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"workspaceFolders\":[{\"uri\":\"file:///c%3A/w\",\"name\":\"w\"}]}}",
    )
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
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\",\"version\":1,\"text\":\"const A: i32 = 1\"}}}",
    )
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\",\"version\":2},\"contentChanges\":[{\"text\":\"const B: i32 = 2\"}]}}",
    )

    let out = string_builder(2048)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    srv.run()

    const doc = srv.docs.get("file:///t.f")
    assert_true(doc.is_some(), "document open")
    assert_eq(doc.unwrap().text.view, "const B: i32 = 2", "full sync replaced the text")
    assert_eq(doc.unwrap().version, 2, "version tracked")
    assert_eq(doc.unwrap().path.view, "/t.f", "file uri resolves to a path")

    let input2 = string_builder(256)
    defer input2.deinit()
    frame_into(
        &input2,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\"}}}",
    )
    let mr2 = mem_reader(input2.as_view())
    srv.reader = mr2.reader()
    srv.run()
    assert_true(srv.docs.get("file:///t.f").is_none(), "closed document dropped")
}

test "a keystroke publishes syntax diagnostics and a fix clears them" {
    let input = string_builder(1024)
    defer input.deinit()
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\",\"version\":1,\"text\":\"fn broken( {\"}}}",
    )

    let out = string_builder(4096)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    srv.run()
    assert_true(
        contains(out.as_view(), "\"method\":\"textDocument/publishDiagnostics\""),
        "diagnostics published on open",
    )
    assert_true(contains(out.as_view(), "\"severity\":1"), "the parse error is an error")
    assert_true(contains(out.as_view(), "\"source\":\"flang\""), "labelled as ours")

    let input2 = string_builder(512)
    defer input2.deinit()
    frame_into(
        &input2,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\",\"version\":2},\"contentChanges\":[{\"text\":\"fn ok() { return }\"}]}}",
    )
    let out2 = string_builder(1024)
    defer out2.deinit()
    let mr2 = mem_reader(input2.as_view())
    srv.reader = mr2.reader()
    srv.out = rpc_writer(out2.writer(), json_options(KeyCase.Camel))
    srv.run()
    assert_true(contains(out2.as_view(), "\"diagnostics\":[]"), "the fix publishes an empty list")
}

test "documentSymbol answers with the outline" {
    let input = string_builder(1024)
    defer input.deinit()
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\",\"version\":1,\"text\":\"pub fn go() i32 { return 1 }\\npub type P = struct { x: i32 }\"}}}",
    )
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\"}}}",
    )

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
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file:///nope.f\"}}}",
    )

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
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\",\"version\":1,\"text\":\"fn a() {\\n    let x = 1\\n    return\\n}\"}}}",
    )
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"textDocument/foldingRange\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\"}}}",
    )

    let out = string_builder(4096)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    srv.run()

    assert_true(
        contains(out.as_view(), "\"id\":6,\"result\":[{\"startLine\":0,\"endLine\":2}]"),
        "the body folds, closing brace stays visible",
    )
}

test "workspace/symbol with no open projects answers an empty list" {
    let input = string_builder(512)
    defer input.deinit()
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"go\"}}",
    )

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
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"\"}}",
    )
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"po\"}}",
    )

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
    let proj = parse_project("[project]\nname = \"t\"\n").unwrap()
    let ctx = resolve_ctx(&proj, "")
    proj.deinit()
    srv.ws.projects.push(OpenProject {
        dir = from_view("/t"),
        name = from_view("t"),
        ctx = move ctx,
        unit = move unit,
        index = move index,
    })
    srv.run()

    assert_true(contains(out.as_view(), "\"id\":8,\"result\":["), "empty query answered")
    assert_true(
        contains(out.as_view(), "\"name\":\"x\",\"kind\":8,\"containerName\":\"Point\""),
        "member carries its container",
    )
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
const DEMO_SRC: String = "pub fn point(q: i32) i32 { return q }\npub type P = struct { x: i32 }\npub fn go(n: i32) i32 {\n    let a = point(3)\n    let s = P { x = 1 }\n    for v in 0..n {\n        let b = v\n    }\n    return a\n}\n// see Wide\npub fn pick(x: $T) $T { return x }\npub fn wait(k: i32) {\n    while k > 0 {\n        k = k - 1\n    }\n}\npub fn use_pick() i32 { return pick(7) }\npub fn wrap(y: $T) i32 { return point(8) }\npub fn use_wrap() i32 { return wrap(true) }\npub fn lone(z: $T) i32 { return point(4) }\npub fn read_x(pp: P) i32 { return pp.x }\npub fn solo(w: $T, point: i32) i32 { return point }\npub type E = enum { A B }\npub fn pick_e() E { return E.A }\npub type Q = struct {\n    // The y.\n    y: i32\n}\npub fn read_y(qq: Q) i32 { return qq.y }\npub type It = contract {\n    type Item\n    fn next(self: &Self) Item\n}\npub fn first(it: &$I) I.Item where I: It { return it.next() }\npub fn keep(it: &$I, b: I) I where I: It, I.Item: It { return b }\npub type Node = struct(T) { next: &Self }\npub fn apply(x: $T, f: $F) T where F: fn(T) T { return f(x) }\npub fn use_apply() i32 { return apply(3i32) { v => v } }\n"

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
    let proj = parse_project("[project]\nname = \"t\"\n").unwrap()
    let ctx = resolve_ctx(&proj, "")
    proj.deinit()
    srv.ws.projects.push(OpenProject {
        dir = from_view("/t"),
        name = from_view("t"),
        ctx = move ctx,
        unit = move unit,
        index = move index,
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
    const open = $"{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///t/m.f\",\"version\":1,\"text\":\"{src.view}\"}}}}}}"
    src.deinit()
    frame_into(&input, open.view)
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

test "opening and editing a file keep the last analysis's warnings" {
    let change = demo_src_json()
    defer change.deinit()
    const edit = $"{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///t/m.f\",\"version\":2}},\"contentChanges\":[{{\"text\":\"// pad\\n{change.view}\"}}]}}}}"
    defer edit.deinit()
    let input = demo_input(edit.view)
    defer input.deinit()
    let out = string_builder(4096)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    demo_project_into(&srv)
    let diags = &srv.ws.projects[0].unit.diagnostics
    diags.push(Diagnostic {
        severity = Severity.Warning,
        code = "W1003",
        message = from_view("unused function `point`"),
        hint = from_view(""),
        span = SourceSpan { file_id = 0, start = 7, length = 5 },
    })
    srv.run()
    assert_eq(
        count(out.as_view(), "\"code\":\"W1003\""),
        2 as usize,
        "kept on open and on the edit",
    )
}

test "hover on a local read renders name and type" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":8,\"character\":11}}}",
        &out,
    )
    assert_true(contains(out.as_view(), "```flang"), "flang code block")
    assert_true(contains(out.as_view(), "let a: i32"), "scope intro, name and type")
}

test "hover on a for-loop binder renders the element type" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":5,\"character\":8}}}",
        &out,
    )
    assert_true(contains(out.as_view(), "for v: i32"), "loop variable hover with its intro")
}

test "hover on a callee names the function" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":3,\"character\":13}}}",
        &out,
    )
    assert_true(contains(out.as_view(), "point"), "function named")
    assert_true(contains(out.as_view(), "i32"), "signature or type shown")
}

test "definition on a call lands on the declaration" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":3,\"character\":13}}}",
        &out,
    )
    assert_true(contains(out.as_view(), "\"id\":13,\"result\":[{"), "a location came back")
    assert_true(contains(out.as_view(), "\"uri\":\"file:///t/m.f\""), "same file")
    assert_true(contains(out.as_view(), "\"start\":{\"line\":0,"), "the declaration line")
}

// A two-module project where the first imports the second by FQN, for the import tier of
// definition. Kept apart from DEMO_SRC so the positions the other tests pin stay put.
fn demo_import_run(request: String, out: &StringBuilder, links: bool = false) {
    const src = "import t.extra\nimport t.missing\npub fn go() i32 { return extra() }\n"
    let input = string_builder(1024)
    if links {
        frame_into(
            &input,
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{\"textDocument\":{\"definition\":{\"linkSupport\":true}}}}}",
        )
    }
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/imp.f\",\"version\":1,\"text\":\"import t.extra\\nimport t.missing\\npub fn go() i32 { return extra() }\\n\"}}}",
    )
    frame_into(&input, request)
    defer input.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    let srcs: List(OwnedString) = list(2)
    srcs.push(from_view(src))
    srcs.push(from_view("pub fn extra() i32 { return 1 }\n"))
    let fqns: List(String) = list(2)
    fqns.push("/t/imp.f")
    fqns.push("t.extra")
    let unit = analyze_source_set(srcs, &fqns)
    fqns.deinit()
    const origin = &unit.project_origin
    origin.push(true)
    origin.push(false)
    let index = build_indexes(&unit)
    let proj = parse_project("[project]\nname = \"t\"\n").unwrap()
    let ctx = resolve_ctx(&proj, "")
    proj.deinit()
    srv.ws.projects.push(OpenProject {
        dir = from_view("/t"),
        name = from_view("t"),
        ctx = move ctx,
        unit = move unit,
        index = move index,
    })
    srv.run()
}

test "definition on an import lands on the imported file" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_import_run(
        "{\"jsonrpc\":\"2.0\",\"id\":40,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/imp.f\"},\"position\":{\"line\":0,\"character\":10}}}",
        &out,
    )
    assert_true(contains(out.as_view(), "\"id\":40,\"result\":[{"), "a location came back")
    assert_true(contains(out.as_view(), "t.extra"), "the imported module's file")
    assert_true(
        contains(out.as_view(), "\"start\":{\"line\":0,\"character\":0}"),
        "its first position",
    )
    assert_true(!contains(out.as_view(), "imp.f\"}"), "not the importing file itself")
}

test "definition on an import is a link over the whole dotted path when the client takes links" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_import_run(
        "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/imp.f\"},\"position\":{\"line\":0,\"character\":10}}}",
        &out,
        true,
    )
    assert_true(
        contains(
            out.as_view(),
            "\"id\":42,\"result\":[{\"originSelectionRange\":{\"start\":{\"line\":0,\"character\":7},\"end\":{\"line\":0,\"character\":14}}",
        ),
        "origin is `t.extra`, keyword excluded",
    )
    assert_true(contains(out.as_view(), "\"targetUri\":\"file://"), "a link target")
    assert_true(contains(out.as_view(), "t.extra\",\"targetRange\""), "the imported module's file")
}

test "definition on an unresolved import answers empty, not the name tiers" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_import_run(
        "{\"jsonrpc\":\"2.0\",\"id\":41,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/imp.f\"},\"position\":{\"line\":1,\"character\":10}}}",
        &out,
    )
    assert_true(contains(out.as_view(), "\"id\":41,\"result\":[]"), "empty result")
}

test "hover on a function parameter renders its type" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":0,\"character\":13}}}",
        &out,
    )
    assert_true(
        contains(out.as_view(), "```flang\\nparam q: i32\\n```"),
        "parameter with its intro, name and type",
    )
}

test "hover inside a generic body answers with its type parameter" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":11,\"character\":31}}}",
        &out,
    )
    assert_true(
        contains(out.as_view(), "param x: T"),
        "the body's own type parameter answers, not an instantiation's type",
    )
}

test "hover on a callee inside a generic body shows the declaration" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":25,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":18,\"character\":33}}}",
        &out,
    )
    assert_true(
        contains(out.as_view(), "pub fn point(q: i32) i32"),
        "callee hover matches the non-generic behaviour",
    )
}

test "hover on a generic callee shows its declaration" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":26,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":17,\"character\":32}}}",
        &out,
    )
    assert_true(
        contains(out.as_view(), "pub fn pick(x: $T) $T"),
        "generic declaration slice, body cut at the brace",
    )
}

test "hover on a callee inside an uninstantiated generic answers by name" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":27,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":20,\"character\":33}}}",
        &out,
    )
    assert_true(
        contains(out.as_view(), "pub fn point(q: i32) i32"),
        "no overlay exists, the registry answers like goto does",
    )
}

test "hover on a member field renders the field type" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":28,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":21,\"character\":37}}}",
        &out,
    )
    assert_true(
        contains(out.as_view(), "```flang\\nfield x: i32\\n```"),
        "field intro, name and type",
    )
}

test "definition on a member field lands on the field declaration" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":29,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":21,\"character\":37}}}",
        &out,
    )
    assert_true(contains(out.as_view(), "\"id\":29,\"result\":[{"), "a location came back")
    assert_true(
        contains(out.as_view(), "\"line\":1,\"character\":22"),
        "the field inside the struct, not some same-named global",
    )
}

test "a param shadowing a function name hovers as the param" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":30,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":22,\"character\":45}}}",
        &out,
    )
    assert_true(contains(out.as_view(), "point: i32"), "the binder's annotation answers")
    assert_true(
        !contains(out.as_view(), "pub fn point"),
        "the same-named function does not hijack the hover",
    )
}

test "the qualifier of Enum.Variant resolves to the enum, the member to the variant" {
    let out = string_builder(4096)
    defer out.deinit()
    // definition on `E` in `E.A`
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":33,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":24,\"character\":27}}}",
        &out,
    )
    assert_true(
        contains(out.as_view(), "\"line\":23,\"character\":0"),
        "qualifier lands on the enum declaration",
    )

    let out2 = string_builder(4096)
    defer out2.deinit()
    // definition on `A` in `E.A`
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":34,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":24,\"character\":29}}}",
        &out2,
    )
    assert_true(
        contains(out2.as_view(), "\"line\":23,\"character\":20"),
        "member lands on the variant inside the enum body",
    )

    let out3 = string_builder(4096)
    defer out3.deinit()
    // hover on `E` in `E.A`
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":35,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":24,\"character\":27}}}",
        &out3,
    )
    assert_true(contains(out3.as_view(), "pub type E = enum"), "qualifier hovers as the enum")
}

test "definition on a projection lands on the associated type, its root on the type parameter" {
    let out = string_builder(4096)
    defer out.deinit()
    // definition on `Item` in `I.Item`
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":36,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":34,\"character\":25}}}",
        &out,
    )
    assert_true(
        contains(out.as_view(), "\"start\":{\"line\":31,\"character\":4}"),
        "`Item` lands on the contract's `type Item`",
    )

    let out2 = string_builder(4096)
    defer out2.deinit()
    // definition on `I` in `I.Item`
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":37,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":34,\"character\":22}}}",
        &out2,
    )
    assert_true(
        contains(out2.as_view(), "\"start\":{\"line\":34,\"character\":18}"),
        "`I` lands on the `$I` that introduces it",
    )

    let out3 = string_builder(4096)
    defer out3.deinit()
    // hover on `Item` in `I.Item`
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":38,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":34,\"character\":25}}}",
        &out3,
    )
    assert_true(contains(out3.as_view(), "type Item"), "hovers as the associated type")

    let out4 = string_builder(4096)
    defer out4.deinit()
    // references on `Item` in `I.Item`: the declaration and the use
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":39,\"method\":\"textDocument/references\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":34,\"character\":25},\"context\":{\"includeDeclaration\":true}}}",
        &out4,
    )
    assert_true(
        contains(out4.as_view(), "\"start\":{\"line\":31,\"character\":4}"),
        "the declaration",
    )
    assert_true(contains(out4.as_view(), "\"start\":{\"line\":34,\"character\":22}"), "the use")
}

// Hits `pos` (line, character) with a definition request and checks the answer starts at `want`.
fn definition_lands(id: i32, line: i32, ch: i32, want: String) bool {
    let out = string_builder(4096)
    defer out.deinit()
    const req = $"{{\"jsonrpc\":\"2.0\",\"id\":{id},\"method\":\"textDocument/definition\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///t/m.f\"}},\"position\":{{\"line\":{line},\"character\":{ch}}}}}}}"
    demo_run(req.view, &out)
    req.deinit()
    return contains(out.as_view(), want)
}

test "definition on a type parameter, a where subject and a bare associated type" {
    assert_true(
        definition_lands(50, 35, 24, "\"start\":{\"line\":35,\"character\":17}"),
        "a bare `I` lands on its `$I`",
    )
    assert_true(
        definition_lands(51, 35, 44, "\"start\":{\"line\":31,\"character\":4}"),
        "`Item` in the `where I.Item:` subject lands on the contract's `type Item`",
    )
    assert_true(
        definition_lands(52, 35, 42, "\"start\":{\"line\":35,\"character\":17}"),
        "the subject's root lands on its `$I`",
    )
    assert_true(
        definition_lands(53, 32, 25, "\"start\":{\"line\":31,\"character\":4}"),
        "a bare `Item` inside its contract lands on its declaration",
    )
}

// Hits `pos` (line, character) with a hover request and checks the answer holds `want`.
fn hover_shows(id: i32, line: i32, ch: i32, want: String) bool {
    let out = string_builder(4096)
    defer out.deinit()
    const req = $"{{\"jsonrpc\":\"2.0\",\"id\":{id},\"method\":\"textDocument/hover\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///t/m.f\"}},\"position\":{{\"line\":{line},\"character\":{ch}}}}}}}"
    demo_run(req.view, &out)
    req.deinit()
    return contains(out.as_view(), want)
}

test "hover on a type parameter reads typevar, on Self the type it names" {
    assert_true(hover_shows(60, 35, 24, "typevar I"), "a bare `I`")
    assert_true(hover_shows(61, 32, 19, "pub type It = contract"), "`Self` in a contract")
    assert_true(hover_shows(62, 32, 25, "type Item"), "a bare associated type")
    assert_true(hover_shows(63, 36, 35, "pub type Node = struct(T)"), "`Self` in a struct")
    assert_true(
        hover_shows(64, 37, 55, "param f: F where F: fn(T) T"),
        "a generic body's parameter shows its type parameter and its bound, not an instantiation's",
    )
}

test "hover on a callee shows the function's docstring" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":40,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":17,\"character\":33}}}",
        &out,
    )
    assert_true(
        contains(out.as_view(), "pub fn pick(x: $T) $T\\n```\\n\\nsee Wide"),
        "the comment run above the declaration follows the code block",
    )
}

test "hover on a member field shows the field's docstring" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":41,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":29,\"character\":37}}}",
        &out,
    )
    assert_true(
        contains(out.as_view(), "field y: i32\\n```\\n\\nThe y."),
        "indented field docstring",
    )
}

test "hover on keywords and annotations answers null" {
    let out = string_builder(4096)
    defer out.deinit()
    // `while` keyword
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":23,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":13,\"character\":5}}}",
        &out,
    )
    assert_true(contains(out.as_view(), "\"id\":23,\"result\":null"), "no void whole-loop hover")

    let out2 = string_builder(4096)
    defer out2.deinit()
    // the `i32` inside go's parameter annotation
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":24,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":2,\"character\":14}}}",
        &out2,
    )
    assert_true(
        contains(out2.as_view(), "\"id\":24,\"result\":null"),
        "no whole-statement hover from an annotation",
    )
}

test "definition resolves a non-indexed type through the registry" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":10,\"character\":8}}}",
        &out,
    )
    assert_true(contains(out.as_view(), "\"id\":21,\"result\":[{"), "a location came back")
    assert_true(
        contains(out.as_view(), "\"uri\":\"file:///t/dep.f\""),
        "the dependency module's file",
    )
}

test "definition on a type name falls back to the symbol index" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":4,\"character\":12}}}",
        &out,
    )
    assert_true(contains(out.as_view(), "\"id\":14,\"result\":[{"), "a location came back")
    assert_true(contains(out.as_view(), "\"line\":1,"), "the struct declaration line")
}

test "typeDefinition on a struct-typed local lands on the struct" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"textDocument/typeDefinition\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":4,\"character\":8}}}",
        &out,
    )
    assert_true(contains(out.as_view(), "\"id\":15,\"result\":[{"), "a location came back")
    assert_true(contains(out.as_view(), "\"line\":1,"), "the struct declaration line")
}

test "references on a parameter finds declaration and reads" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"textDocument/references\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":0,\"character\":34},\"context\":{\"includeDeclaration\":true}}}",
        &out,
    )
    assert_true(contains(out.as_view(), "\"id\":16,\"result\":[{"), "locations came back")
    assert_true(contains(out.as_view(), "\"character\":34"), "the read site listed")
    assert_true(contains(out.as_view(), "\"character\":13"), "the declaration listed")
}

test "inlayHint lists annotation-less binders with their types" {
    let out = string_builder(8192)
    defer out.deinit()
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":17,\"method\":\"textDocument/inlayHint\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"}}}",
        &out,
    )
    assert_true(contains(out.as_view(), "\"label\":\": i32\""), "int binders hinted")
    assert_true(contains(out.as_view(), "\"label\":\": P\""), "struct binder hinted")
    assert_true(contains(out.as_view(), "\"kind\":1"), "typed as type hints")
}

test "inlayHint answers empty when the edited buffer shares no binders" {
    let out = string_builder(8192)
    defer out.deinit()
    let input = demo_input(
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\",\"version\":2},\"contentChanges\":[{\"text\":\"pub fn nothing() { }\"}]}}",
    )
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"id\":31,\"method\":\"textDocument/inlayHint\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"}}}",
    )
    defer input.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    demo_project_into(&srv)
    srv.run()
    assert_true(
        contains(out.as_view(), "\"id\":31,\"result\":[]"),
        "nothing pairs, nothing renders",
    )
}

test "inlayHint follows unsaved edits to live positions" {
    let out = string_builder(16384)
    defer out.deinit()
    // The same source shifted down one line: every binder pairs, every hint moves with it.
    const src = demo_src_json()
    const change = $"{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///t/m.f\",\"version\":2}},\"contentChanges\":[{{\"text\":\"// pad\\n{src.view}\"}}]}}}}"
    src.deinit()
    let input = demo_input(change.view)
    change.deinit()
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"id\":32,\"method\":\"textDocument/inlayHint\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"}}}",
    )
    defer input.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    demo_project_into(&srv)
    srv.run()
    assert_true(
        contains(out.as_view(), "\"position\":{\"line\":4,\"character\":9},\"label\":\": i32\""),
        "the first hint renders one line below its analyzed position",
    )
    assert_true(contains(out.as_view(), "\"label\":\": P\""), "later binders keep pairing")
}

test "signatureHelp inside a call shows the declaration and active parameter" {
    let out = string_builder(4096)
    defer out.deinit()
    demo_run(
        "{\"jsonrpc\":\"2.0\",\"id\":18,\"method\":\"textDocument/signatureHelp\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/m.f\"},\"position\":{\"line\":3,\"character\":18}}}",
        &out,
    )
    assert_true(
        contains(out.as_view(), "\"label\":\"pub fn point(q: i32) i32\""),
        "declaration slice as the signature label",
    )
    assert_true(
        contains(out.as_view(), "\"parameters\":[{\"label\":\"q: i32\"}]"),
        "parameter label sliced out",
    )
    assert_true(contains(out.as_view(), "\"activeParameter\":0"), "first argument active")
}

test "hover outside any analyzed project answers null" {
    let input = string_builder(512)
    defer input.deinit()
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"id\":19,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///nowhere.f\"},\"position\":{\"line\":0,\"character\":0}}}",
    )
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
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\",\"version\":1,\"text\":\"fn go() {\\n        return\\n}\\n\"}}}",
    )
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"id\":40,\"method\":\"textDocument/formatting\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\"},\"options\":{\"tabSize\":4}}}",
    )

    let out = string_builder(4096)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    srv.run()

    assert_true(contains(out.as_view(), "\"id\":40,\"result\":[{"), "an edit came back")
    assert_true(
        contains(out.as_view(), "\"start\":{\"line\":0,\"character\":0}"),
        "edit starts at the top",
    )
    assert_true(
        contains(out.as_view(), "\"newText\":\"fn go() {\\n    return\\n}\\n\""),
        "over-indent reduced to four spaces",
    )
}

test "formatting a clean document answers no edits" {
    let input = string_builder(1024)
    defer input.deinit()
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\",\"version\":1,\"text\":\"fn go() {\\n    return\\n}\\n\"}}}",
    )
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"id\":41,\"method\":\"textDocument/formatting\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\"}}}",
    )

    let out = string_builder(4096)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    srv.run()
    assert_true(contains(out.as_view(), "\"id\":41,\"result\":[]"), "nothing to change")
}

fn lens_run(commands: String, out: &StringBuilder) {
    let input = string_builder(1024)
    defer input.deinit()
    const init = $"{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{{\"capabilities\":{{\"experimental\":{{\"commands\":{{\"commands\":[{commands}]}}}}}}}}}}"
    frame_into(&input, init.view)
    init.deinit()
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/k.f\",\"version\":1,\"text\":\"fn f() { }\\ntest \\\"adds up\\\" { }\\n\"}}}",
    )
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/codeLens\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/k.f\"}}}",
    )
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    demo_project_into(&srv)
    srv.run()
}

test "codeLens puts a run command on each test block for a client that has it" {
    let out = string_builder(4096)
    defer out.deinit()
    lens_run("\"flang.runTest\"", &out)
    assert_true(contains(out.as_view(), "\"codeLensProvider\""), "lenses advertised")
    assert_true(contains(out.as_view(), "\"command\":\"flang.runTest\""), "the client's command")
    assert_true(
        contains(out.as_view(), "{\"dir\":\"/t\",\"file\":\"k.f\",\"name\":\"adds up\"}"),
        "project dir, relative file and label",
    )
    assert_true(contains(out.as_view(), "\"start\":{\"line\":1,"), "on the test's line")
}

test "codeLens is not advertised to a client without the run command" {
    let out = string_builder(4096)
    defer out.deinit()
    lens_run("", &out)
    assert_true(!contains(out.as_view(), "\"codeLensProvider\""), "no lenses advertised")
}

test "unknown request errors, unknown notification is ignored" {
    let input = string_builder(512)
    defer input.deinit()
    frame_into(
        &input,
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"textDocument/semanticTokens/full\",\"params\":{}}",
    )
    frame_into(&input, "{\"jsonrpc\":\"2.0\",\"method\":\"$/setTrace\",\"params\":{}}")

    let out = string_builder(512)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    srv.run()

    assert_true(
        contains(out.as_view(), "\"id\":9,\"error\":{\"code\":-32601"),
        "request answered with MethodNotFound",
    )
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

// A project for the rename tests: /r/m.f declares a struct, an enum, a context field, functions and
// locals that reference each other; /r/dep.f stands in for a dependency (not project-origin), and
// `core.runtime` supplies the `Context` the context field joins.
const RENAME_SRC: String = "pub type P = struct { x: i32 }\npub type E = enum { A B(i32) }\ncontext depth: i32 = 0\npub fn mk(v: i32) P { return P { x = v } }\npub fn get(p: &P) i32 { return p.x }\npub fn pick(e: E) i32 {\n    return e match {\n        A => context.depth\n        E.B(n) => n\n    }\n}\npub fn run() i32 {\n    let total = get(&mk(1)) + pick(E.B(2)) + pick(E.A)\n    context(depth = 2) { total = total + 1 }\n    return total\n}\npub fn call_dep() i32 { return helper() }\npub type Dir = enum {\n    // Heading up.\n    Up(i32)\n    Down\n}\npub fn go_up() Dir { return Dir.Up(1) }\n#if platform.os == \"nowhere\" {\n    pub fn never() { }\n} else {\n    pub fn always() { }\n}\npub fn branchy() i32 {\n    #if runtime.testing {\n        let t = 1\n        return t\n    }\n    return 0\n}\n// Makes a twin.\n#define(twin, N: Ident) {\n    pub fn #(N)_twice() i32 { return 2 }\n}\n#twin(foo)\n#twin(Dir)\n"

// Opens /r/m.f, then sends each of `requests`.
fn rename_run(requests: String[], out: &StringBuilder) {
    rename_run_with(requests, out, false)
}

// An in-memory project named `name` over `sources`, `fqns[i]` naming source i and doubling as its
// path, `origin[i]` whether it is the project's own.
fn open_test_project(
    srv: &LspServer,
    name: String,
    sources: String[],
    fqns: String[],
    origin: bool[],
) &AnalyzedProject {
    let srcs: List(OwnedString) = list(sources.len)
    let names: List(String) = list(fqns.len)
    for i in 0..sources.len {
        srcs.push(from_view(sources[i]))
        names.push(fqns[i])
    }
    let unit = analyze_source_set(srcs, &names)
    names.deinit()
    let flags = &unit.project_origin
    for o in origin {
        flags.push(o)
    }
    let index = build_indexes(&unit)
    let manifest = $"[project]\nname = \"{name}\"\n"
    let proj = parse_project(manifest.view).unwrap()
    manifest.deinit()
    let ctx = resolve_ctx(&proj, "")
    proj.deinit()
    srv.ws.projects.push(OpenProject {
        dir = $"/{name}",
        name = from_view(name),
        ctx = move ctx,
        unit = move unit,
        index = move index,
    })
    return &srv.ws.projects[srv.ws.projects.len - 1].unit
}

// `rename_run`, plus with `second` a project /s that loads /r/m.f as a dependency and calls `mk`.
fn rename_run_with(requests: String[], out: &StringBuilder, second: bool) {
    let input = string_builder(4096)
    defer input.deinit()
    let body = string_builder(RENAME_SRC.len + 32)
    for i in 0..RENAME_SRC.len {
        RENAME_SRC[i] match {
            '\n' => body.append("\\n")
            '"' => body.append("\\\"")
            else => body.append(RENAME_SRC[i..(i + 1)])
        }
    }
    const open = $"{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///r/m.f\",\"version\":1,\"text\":\"{body.as_view()}\"}}}}}}"
    body.deinit()
    frame_into(&input, open.view)
    open.deinit()
    for r in requests {
        frame_into(&input, r)
    }

    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    const context_src = "pub type Context = struct {}\n"
    const comptime_src = "pub type Platform = struct {\n    // The target OS.\n    os: String\n    arch: String\n}\npub type Runtime = struct {\n    testing: bool\n    release: bool\n}\n"
    open_test_project(
        &srv,
        "r",
        [RENAME_SRC, "pub fn helper() i32 { return 1 }\n", context_src, comptime_src],
        ["/r/m.f", "/r/dep.f", "core.runtime", "core.comptime"],
        [true, false, false, false],
    )
    if second {
        // The dependency's FQN is what the import names; its path is the file /r/m.f.
        const unit = open_test_project(
            &srv,
            "s",
            [RENAME_SRC, "import r.m\npub fn use_mk() i32 { return get(&mk(5)) }\n", context_src],
            ["r.m", "/s/u.f", "core.runtime"],
            [false, true, false],
        )
        replace(&unit.file_paths[0], from_view("/r/m.f")).deinit()
    }
    srv.run()
}

// Renames the symbol at (line, ch) to `fresh` and answers how many edits came back.
fn rename_count(id: i32, line: i32, ch: i32, fresh: String) usize {
    let out = string_builder(8192)
    defer out.deinit()
    const req = $"{{\"jsonrpc\":\"2.0\",\"id\":{id},\"method\":\"textDocument/rename\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///r/m.f\"}},\"position\":{{\"line\":{line},\"character\":{ch}}},\"newName\":\"{fresh}\"}}}}"
    rename_run([req.view], &out)
    req.deinit()
    const want = $"\"newText\":\"{fresh}\""
    defer want.deinit()
    return count(out.as_view(), want.view)
}

test "rename rewrites a field at its declaration, initializer and read" {
    assert_eq(rename_count(70, 0, 22, "y"), 3 as usize, "from the declaration")
    assert_eq(rename_count(71, 4, 33, "y"), 3 as usize, "from a read")
    assert_eq(rename_count(72, 3, 33, "y"), 3 as usize, "from a literal's initializer")
}

test "rename rewrites a struct at every type position" {
    assert_eq(rename_count(73, 0, 9, "Q"), 4 as usize, "declaration, return, literal, param")
    assert_eq(rename_count(74, 4, 15, "Q"), 4 as usize, "from a reference")
}

test "rename rewrites an enum, its qualifiers and its variants" {
    assert_eq(rename_count(75, 1, 9, "F"), 5 as usize, "declaration, param, three qualifiers")
    assert_eq(rename_count(76, 8, 8, "F"), 5 as usize, "from a pattern qualifier")
    assert_eq(
        rename_count(77, 1, 22, "C"),
        3 as usize,
        "variant: declaration, pattern, construction",
    )
    assert_eq(rename_count(78, 12, 52, "Z"), 3 as usize, "nullary variant from a qualified use")
    assert_eq(rename_count(109, 17, 9, "Way"), 4 as usize, "a generator argument renames along")
}

test "rename rewrites a context field, a function and a local" {
    assert_eq(rename_count(79, 2, 8, "level"), 3 as usize, "context: declaration, read, rebind")
    assert_eq(rename_count(80, 7, 21, "level"), 3 as usize, "context field from its read")
    assert_eq(rename_count(81, 3, 7, "make"), 2 as usize, "function: declaration and call")
    assert_eq(rename_count(82, 12, 8, "sum"), 4 as usize, "local: binder and three reads")
}

test "rename answers a WorkspaceEdit of document changes" {
    let out = string_builder(8192)
    defer out.deinit()
    rename_run(
        [
            "{\"jsonrpc\":\"2.0\",\"id\":83,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file:///r/m.f\"},\"position\":{\"line\":3,\"character\":7},\"newName\":\"make\"}}",
        ],
        &out,
    )
    assert_true(
        contains(
            out.as_view(),
            "\"documentChanges\":[{\"textDocument\":{\"uri\":\"file:///r/m.f\",\"version\":null}",
        ),
        "one change per file, versioned null",
    )
    assert_true(
        contains(
            out.as_view(),
            "{\"range\":{\"start\":{\"line\":3,\"character\":7},\"end\":{\"line\":3,\"character\":9}},\"newText\":\"make\"}",
        ),
        "the declaration's name replaced",
    )
}

test "prepareRename answers the word and its placeholder" {
    let out = string_builder(4096)
    defer out.deinit()
    rename_run(
        [
            "{\"jsonrpc\":\"2.0\",\"id\":84,\"method\":\"textDocument/prepareRename\",\"params\":{\"textDocument\":{\"uri\":\"file:///r/m.f\"},\"position\":{\"line\":12,\"character\":10}}}",
        ],
        &out,
    )
    assert_true(
        contains(
            out.as_view(),
            "\"id\":84,\"result\":{\"range\":{\"start\":{\"line\":12,\"character\":8},\"end\":{\"line\":12,\"character\":13}},\"placeholder\":\"total\"}",
        ),
        "the whole word, its spelling as the placeholder",
    )
}

// Whether a `method` request at (line, ch) draws the error `code`.
fn rename_refused(id: i32, method: String, line: i32, ch: i32, fresh: String, code: String) bool {
    let out = string_builder(4096)
    defer out.deinit()
    const req = $"{{\"jsonrpc\":\"2.0\",\"id\":{id},\"method\":\"textDocument/{method}\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///r/m.f\"}},\"position\":{{\"line\":{line},\"character\":{ch}}},\"newName\":\"{fresh}\"}}}}"
    rename_run([req.view], &out)
    req.deinit()
    const want = $"\"id\":{id},\"error\":{{\"code\":{code}"
    defer want.deinit()
    return contains(out.as_view(), want.view)
}

test "rename refuses dependencies, keywords, bad names and empty space" {
    assert_true(
        rename_refused(85, "prepareRename", 16, 32, "", "-32803"),
        "a dependency's function",
    )
    assert_true(rename_refused(86, "prepareRename", 5, 1, "", "-32803"), "a keyword")
    assert_true(rename_refused(87, "prepareRename", 6, 2, "", "-32803"), "whitespace")
    assert_true(rename_refused(88, "rename", 12, 8, "match", "-32602"), "a keyword as the new name")
    assert_true(rename_refused(89, "rename", 12, 8, "a b", "-32602"), "two words as the new name")
}

test "rename refuses while the buffer differs from the analyzed text" {
    let out = string_builder(4096)
    defer out.deinit()
    rename_run(
        [
            "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///r/m.f\",\"version\":2},\"contentChanges\":[{\"text\":\"// edited\\n\"}]}}",
            "{\"jsonrpc\":\"2.0\",\"id\":90,\"method\":\"textDocument/prepareRename\",\"params\":{\"textDocument\":{\"uri\":\"file:///r/m.f\"},\"position\":{\"line\":12,\"character\":8}}}",
        ],
        &out,
    )
    assert_true(
        contains(out.as_view(), "\"id\":90,\"error\":{\"code\":-32803"),
        "unsaved edits refuse",
    )
}

test "rename reaches every open project that loads the declaring file" {
    let out = string_builder(8192)
    defer out.deinit()
    rename_run_with(
        [
            "{\"jsonrpc\":\"2.0\",\"id\":108,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file:///r/m.f\"},\"position\":{\"line\":3,\"character\":7},\"newName\":\"make\"}}",
        ],
        &out,
        true,
    )
    assert_eq(count(out.as_view(), "\"newText\":\"make\""), 3 as usize, "shared file merged once")
    assert_true(
        contains(out.as_view(), "\"uri\":\"file:///s/u.f\""),
        "the dependent project's caller",
    )
}

// Hovers (line, ch) in the rename project and checks the answer holds `want`.
fn hover_holds(id: i32, line: i32, ch: i32, want: String) bool {
    let out = string_builder(8192)
    defer out.deinit()
    const req = $"{{\"jsonrpc\":\"2.0\",\"id\":{id},\"method\":\"textDocument/hover\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///r/m.f\"}},\"position\":{{\"line\":{line},\"character\":{ch}}}}}}}"
    rename_run([req.view], &out)
    req.deinit()
    return contains(out.as_view(), want)
}

test "hover on a variant shows it qualified, with its payload and docstring" {
    assert_true(hover_holds(91, 22, 32, "Dir.Up(i32)\\n```\\n\\nHeading up."), "payload variant")
    assert_true(hover_holds(92, 12, 52, "```flang\\nE.A\\n```"), "nullary variant")
    assert_true(hover_holds(93, 12, 35, "pub type E = enum"), "the qualifier is the enum")
}

test "hover on a type name, a field initializer and a context field" {
    assert_true(hover_holds(94, 4, 15, "pub type P = struct"), "a struct, not a type variable")
    assert_true(hover_holds(95, 3, 33, "field x: i32"), "an initializer names its field")
    assert_true(hover_holds(96, 7, 21, "context depth: i32 = 0"), "a context field read")
    assert_true(hover_holds(97, 13, 12, "context depth: i32 = 0"), "a rebind argument")
    assert_true(
        hover_holds(
            105,
            7,
            14,
            "```flang\\ncontext: Context\\n\\ntype Context = struct {\\n    depth: i32 // ",
        ),
        "the keyword reading lists the assembled fields",
    )
    assert_true(hover_holds(106, 13, 5, "```flang\\ncontext: Context\\n"), "the keyword rebinding")
    assert_true(hover_holds(107, 2, 3, "\"id\":107,\"result\":null"), "the keyword declaring")
}

test "a #if head hovers the compile-time context like a runtime condition" {
    assert_true(hover_holds(98, 23, 1, "\"id\":98,\"result\":null"), "the keyword shows nothing")
    assert_true(hover_holds(99, 23, 5, "```flang\\nconst platform: Platform\\n```"), "the root")
    assert_true(
        hover_holds(100, 23, 14, "```flang\\nfield os: String\\n```\\n\\nThe target OS."),
        "a member, with its field's docstring",
    )
    assert_true(hover_holds(101, 29, 16, "field testing: bool"), "a statement-level directive")
    assert_true(hover_holds(110, 23, 20, "\"id\":110,\"result\":null"), "a literal shows nothing")
}

test "definition on the compile-time context lands on core.comptime" {
    let out = string_builder(4096)
    defer out.deinit()
    rename_run(
        [
            "{\"jsonrpc\":\"2.0\",\"id\":111,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///r/m.f\"},\"position\":{\"line\":23,\"character\":14}}}",
        ],
        &out,
    )
    assert_true(
        contains(out.as_view(), "core.comptime\",\"range\":{\"start\":{\"line\":2,"),
        "the field",
    )
}

test "hover on a generator invocation shows its define and expansion" {
    assert_true(hover_holds(102, 39, 2, "#define(twin, N: Ident)"), "the define's header")
    assert_true(hover_holds(103, 39, 2, "Makes a twin."), "its docstring")
    assert_true(hover_holds(104, 39, 2, "This expansion declares `foo_twice`."), "what it declared")
}
