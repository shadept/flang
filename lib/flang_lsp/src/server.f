// The LSP server core: a single-threaded message loop over a Reader/Writer pair speaking
// std.rpc.jsonrpc, plus the lifecycle and document-sync handlers. Transport-agnostic - the
// bootstrap `lsp` subcommand hands it stdin/stdout, tests hand it a MemReader and a StringBuilder.
//
// Handlers never run analysis; they answer from current state or answer empty. Unknown requests get
// MethodNotFound, unknown notifications are dropped, both per JSON-RPC. `exit` ends the loop with
// code 0 when a `shutdown` request preceded it, 1 otherwise (LSP 3.17 exit semantics).

import std.encoding.json
import std.io.reader
import std.io.writer
import std.list
import std.option
import std.result
import std.rpc.jsonrpc
import std.string
import std.string_builder
import std.string_reader
import std.test
import flang_lsp.documents
import flang_lsp.line_index

pub type LspServer = struct {
    reader: Reader
    writer: Writer
    docs: DocumentStore
    encoding: PositionEncoding
    shutdown_requested: bool
    exit_code: i32?
}

pub fn lsp_server(r: Reader, w: Writer) LspServer {
    return .{
        reader = r,
        writer = w,
        docs = document_store(),
        encoding = PositionEncoding.Utf16,
        shutdown_requested = false,
        exit_code = null,
    }
}

pub fn deinit(self: &LspServer) {
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
        "initialized" => {}
        "shutdown" => self.on_shutdown(msg)
        "exit" => self.on_exit()
        "textDocument/didOpen" => self.on_did_open(msg)
        "textDocument/didChange" => self.on_did_change(msg)
        "textDocument/didClose" => self.on_did_close(msg)
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

fn initialize_result(self: &LspServer) JsonValue {
    let sync = json_object()
    sync.as_object().unwrap().json_set("openClose", json_bool(true))
    sync.as_object().unwrap().json_set("change", json_number(1.0)) // TextDocumentSyncKind.Full

    let caps = json_object()
    const enc_name = if is_utf8_encoding(self.encoding) { "utf-8" } else { "utf-16" }
    caps.as_object().unwrap().json_set("positionEncoding", json_string(enc_name))
    caps.as_object().unwrap().json_set("textDocumentSync", sync)

    let info = json_object()
    info.as_object().unwrap().json_set("name", json_string("flang-lsp"))
    info.as_object().unwrap().json_set("version", json_string("0.1.0"))

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
}

fn on_did_close(self: &LspServer, msg: &RpcMessage) {
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
    self.docs.close(uri.unwrap())
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
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\",\"version\":1,\"text\":\"a\\nb\"}}}")
    frame_into(&input,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\",\"version\":2},\"contentChanges\":[{\"text\":\"xyz\"}]}}")

    let out = string_builder(256)
    defer out.deinit()
    let mr = mem_reader(input.as_view())
    let srv = lsp_server(mr.reader(), out.writer())
    defer srv.deinit()
    srv.run()

    const doc = srv.docs.get("file:///t.f")
    assert_true(doc.is_some(), "document open")
    assert_eq(doc.unwrap().text.as_view(), "xyz", "full sync replaced the text")
    assert_eq(doc.unwrap().version, 2, "version tracked")

    let input2 = string_builder(256)
    defer input2.deinit()
    frame_into(&input2,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.f\"}}}")
    let mr2 = mem_reader(input2.as_view())
    srv.reader = mr2.reader()
    srv.run()
    assert_true(srv.docs.get("file:///t.f").is_none(), "closed document dropped")
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
