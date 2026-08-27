// JSON-RPC 2.0 over Content-Length framing.
//
//   framing    read_frame / write_frame - `Content-Length: N\r\n\r\n{json}` over Reader/Writer
//   envelope   RpcMessage (parse side) and write_request / write_response /
//              write_error / write_notification (serialize side)
//   format     std.encoding.json
//
// Transport-agnostic: everything is written against the Reader/Writer vtable interfaces, so a
// transcript is testable in-process with MemReader and a StringBuilder-backed writer. This is the
// wire layer of the LSP; it knows JSON-RPC, not LSP.
//
// A parsed RpcMessage owns its whole JSON document and hands out borrowed references into it. The
// `id` is kept as parsed JSON and echoed back through write_response/write_error, never
// interpreted.

import std.allocator
import std.conv
import std.dict
import std.encoding.codec
import std.encoding.json
import std.enum
import std.io.reader
import std.io.writer
import std.mem
import std.option
import std.result
import std.string
import std.string_builder
import std.string_reader
import std.test

// JSON-RPC error codes (the spec's reserved range).
pub const PARSE_ERROR: i64 = -32700
pub const INVALID_REQUEST: i64 = -32600
pub const METHOD_NOT_FOUND: i64 = -32601
pub const INVALID_PARAMS: i64 = -32602
pub const INTERNAL_ERROR: i64 = -32603

pub type RpcError = enum {
    Eof // clean end of stream before any header byte
    BadHeader // malformed header block, or unparseable Content-Length
    MissingLength // header block ended without a Content-Length
    BodyTruncated // stream ended before Content-Length bytes of body arrived
    BadJson // body is not valid JSON
    BadEnvelope // valid JSON, but not a JSON-RPC 2.0 message object
}

#enum_utils(RpcError)

// =============================================================================
// Framing
// =============================================================================

fn read_one(r: Reader) u8? {
    let b: u8 = 0
    const dst = slice_from_raw_parts(&b as &u8, 1)
    if r.read(dst) == 0 {
        return null
    }
    return Some(b)
}

// Read one framed payload: headers, blank line, then exactly Content-Length bytes of body. Unknown
// headers (Content-Type) are skipped. Returns the raw body bytes; Eof only when the stream ends
// cleanly before the first byte.
pub fn read_frame(r: Reader, allocator: &Allocator? = null) Result(OwnedString, RpcError) {
    let content_len: usize? = null
    let line = string_builder(64, allocator)
    defer line.deinit()
    let first_byte = true

    loop {
        line.clear()
        loop {
            const b = read_one(r)
            if b.is_none() {
                if first_byte {
                    return Err(RpcError.Eof)
                }
                return Err(RpcError.BadHeader)
            }
            first_byte = false
            if b.unwrap() == '\n' {
                break
            }
            if b.unwrap() != '\r' {
                line.append_byte(b.unwrap())
            }
        }

        if line.as_view().len == 0 {
            break
        }

        const rest = strip_prefix(line.as_view(), "Content-Length:")
        if rest.is_some() {
            const digits = trim(rest.unwrap())
            const parsed = parse_u64(digits.as_raw_bytes())
            if parsed.is_err() {
                return Err(RpcError.BadHeader)
            }
            const pair = parsed.unwrap()
            if pair.1 != digits.len {
                return Err(RpcError.BadHeader)
            }
            content_len = Some(pair.0 as usize)
        }
    }

    if content_len.is_none() {
        return Err(RpcError.MissingLength)
    }

    const want = content_len.unwrap()
    let sb = string_builder(want, allocator)
    let buf = [0u8; 4096]
    let got: usize = 0
    while got < want {
        let chunk = want - got
        if chunk > 4096 {
            chunk = 4096
        }
        const n = r.read(buf[0..chunk])
        if n == 0 {
            sb.deinit()
            return Err(RpcError.BodyTruncated)
        }
        sb.append_bytes(buf[0..n])
        got = got + n
    }
    return Ok(sb.to_string())
}

// Write one framed payload.
pub fn write_frame(w: Writer, payload: String) {
    write_str(w, "Content-Length: ")
    write_uint(w, payload.len)
    write_str(w, "\r\n\r\n")
    write_str(w, payload)
}

// =============================================================================
// Envelope - parse side
// =============================================================================

// One parsed JSON-RPC message. Owns the whole document; accessors return borrowed views/references
// into it, valid until deinit.
pub type RpcMessage = struct {
    doc: JsonValue
}

pub fn deinit(self: &RpcMessage) {
    self.doc.deinit()
}

fn field_ref(self: &RpcMessage, name: String) &JsonValue? {
    return self.doc.as_object() match {
        Some(o) => o.json_get_ref(name)
        None => null
    }
}

pub fn id(self: &RpcMessage) &JsonValue? {
    return self.field_ref("id")
}

pub fn method(self: &RpcMessage) String? {
    return self.field_ref("method") match {
        Some(v) => v.as_string()
        None => null
    }
}

pub fn params(self: &RpcMessage) &JsonValue? {
    return self.field_ref("params")
}

pub fn result(self: &RpcMessage) &JsonValue? {
    return self.field_ref("result")
}

pub fn error(self: &RpcMessage) &JsonValue? {
    return self.field_ref("error")
}

// A request carries a method and a non-null id.
pub fn is_request(self: &RpcMessage) bool {
    if self.method().is_none() {
        return false
    }
    return self.field_ref("id") match {
        Some(v) => !v.is_null()
        None => false
    }
}

// A notification carries a method and no id.
pub fn is_notification(self: &RpcMessage) bool {
    return self.method().is_some() and !self.is_request()
}

// A response carries no method (result or error instead).
pub fn is_response(self: &RpcMessage) bool {
    return self.method().is_none()
}

// Parse one message body. Requires a JSON object with "jsonrpc": "2.0".
pub fn parse_message(payload: String, allocator: &Allocator? = null) Result(RpcMessage, RpcError) {
    const parsed = parse(payload, allocator)
    if parsed.is_err() {
        return Err(RpcError.BadJson)
    }
    let doc = parsed.unwrap()

    const versioned = doc.as_object() match {
        Some(o) => o.json_get_ref("jsonrpc") match {
            Some(v) => v.as_string() match {
                Some(s) => s == "2.0"
                None => false
            }
            None => false
        }
        None => false
    }
    if !versioned {
        doc.deinit()
        return Err(RpcError.BadEnvelope)
    }

    return Ok(RpcMessage { doc = doc })
}

// Read one frame and parse it: the receive path of a message loop.
pub fn read_message(r: Reader, allocator: &Allocator? = null) Result(RpcMessage, RpcError) {
    const framed = read_frame(r, allocator)
    if framed.is_err() {
        return Err(framed.unwrap_err())
    }
    let payload = framed.unwrap()
    defer payload.deinit()
    return parse_message(payload.as_view(), allocator)
}

// =============================================================================
// Envelope - serialize side
// =============================================================================

pub fn write_request(w: Writer, id: i64, method: String, params: &JsonValue? = null) {
    let sb = string_builder(128)
    defer sb.deinit()
    let jenc = json_encoder(sb.writer())
    let e = jenc.encoder()
    e.begin_map(0)
    e.key("jsonrpc")
    e.encode_str("2.0")
    e.key("id")
    e.encode_int(id, 8)
    e.key("method")
    e.encode_str(method)
    if params.is_some() {
        e.key("params")
        params.unwrap().serialize(&e)
    }
    e.end_map()
    write_frame(w, sb.as_view())
}

pub fn write_notification(w: Writer, method: String, params: &JsonValue? = null) {
    let sb = string_builder(128)
    defer sb.deinit()
    let jenc = json_encoder(sb.writer())
    let e = jenc.encoder()
    e.begin_map(0)
    e.key("jsonrpc")
    e.encode_str("2.0")
    e.key("method")
    e.encode_str(method)
    if params.is_some() {
        e.key("params")
        params.unwrap().serialize(&e)
    }
    e.end_map()
    write_frame(w, sb.as_view())
}

pub fn write_response(w: Writer, id: &JsonValue, result: &JsonValue) {
    let sb = string_builder(128)
    defer sb.deinit()
    let jenc = json_encoder(sb.writer())
    let e = jenc.encoder()
    e.begin_map(0)
    e.key("jsonrpc")
    e.encode_str("2.0")
    e.key("id")
    id.serialize(&e)
    e.key("result")
    result.serialize(&e)
    e.end_map()
    write_frame(w, sb.as_view())
}

pub fn write_error(w: Writer, id: &JsonValue, code: i64, message: String) {
    let sb = string_builder(128)
    defer sb.deinit()
    let jenc = json_encoder(sb.writer())
    let e = jenc.encoder()
    e.begin_map(0)
    e.key("jsonrpc")
    e.encode_str("2.0")
    e.key("id")
    id.serialize(&e)
    e.key("error")
    e.begin_map(0)
    e.key("code")
    e.encode_int(code, 8)
    e.key("message")
    e.encode_str(message)
    e.end_map()
    e.end_map()
    write_frame(w, sb.as_view())
}

// =============================================================================
// Tests
// =============================================================================

test "frame round-trip" {
    let sb = string_builder(64)
    defer sb.deinit()
    write_frame(sb.writer(), "{\"x\":1}")
    assert_eq(sb.as_view(), "Content-Length: 7\r\n\r\n{\"x\":1}", "exact frame bytes")

    let mr = mem_reader(sb.as_view())
    const got = read_frame(mr.reader())
    assert_true(got.is_ok(), "frame reads back")
    let payload = got.unwrap()
    defer payload.deinit()
    assert_eq(payload.as_view(), "{\"x\":1}", "payload survives the round trip")
}

test "read_frame skips unknown headers" {
    let mr = mem_reader("Content-Type: application/vscode-jsonrpc; charset=utf-8\r\nContent-Length: 2\r\n\r\n{}")
    const got = read_frame(mr.reader())
    assert_true(got.is_ok(), "extra headers are skipped")
    let payload = got.unwrap()
    defer payload.deinit()
    assert_eq(payload.as_view(), "{}", "body follows the blank line")
}

test "read_frame reads consecutive frames" {
    let mr = mem_reader("Content-Length: 2\r\n\r\n{}Content-Length: 4\r\n\r\nnull")
    const first = read_frame(mr.reader())
    let a = first.unwrap()
    defer a.deinit()
    assert_eq(a.as_view(), "{}", "first frame")
    const second = read_frame(mr.reader())
    let b = second.unwrap()
    defer b.deinit()
    assert_eq(b.as_view(), "null", "second frame starts at the next byte")
}

test "clean end of stream is Eof" {
    let mr = mem_reader("")
    const got = read_frame(mr.reader())
    assert_true(got.is_err(), "no frame in an empty stream")
    assert_eq(got.unwrap_err().to_string(), "Eof", "clean EOF is distinguishable")
}

test "truncated body is BodyTruncated" {
    let mr = mem_reader("Content-Length: 10\r\n\r\n{}")
    const got = read_frame(mr.reader())
    assert_true(got.is_err(), "short body fails")
    assert_eq(got.unwrap_err().to_string(), "BodyTruncated", "mid-body EOF is BodyTruncated")
}

test "missing Content-Length is MissingLength" {
    let mr = mem_reader("Content-Type: text\r\n\r\n{}")
    const got = read_frame(mr.reader())
    assert_true(got.is_err(), "headers without a length fail")
    assert_eq(got.unwrap_err().to_string(), "MissingLength", "reported as MissingLength")
}

test "parse request" {
    const got = parse_message("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}")
    assert_true(got.is_ok(), "request parses")
    let msg = got.unwrap()
    defer msg.deinit()
    assert_true(msg.is_request(), "id + method is a request")
    assert_true(!msg.is_notification(), "not a notification")
    assert_eq(msg.method().unwrap(), "initialize", "method text")
    assert_true(msg.params().is_some(), "params present")
    assert_true(msg.id().unwrap().is_number(), "id is a number")
}

test "parse notification" {
    const got = parse_message("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}")
    let msg = got.unwrap()
    defer msg.deinit()
    assert_true(msg.is_notification(), "method without id is a notification")
    assert_true(!msg.is_request(), "not a request")
    assert_true(msg.params().is_none(), "params absent")
}

test "parse response" {
    const got = parse_message("{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":null}")
    let msg = got.unwrap()
    defer msg.deinit()
    assert_true(msg.is_response(), "no method is a response")
    assert_true(msg.result().is_some(), "result present, even when null")
}

test "bad json is BadJson" {
    const got = parse_message("{oops")
    assert_true(got.is_err(), "garbage fails")
    assert_eq(got.unwrap_err().to_string(), "BadJson", "reported as BadJson")
}

test "non-object and missing version are BadEnvelope" {
    const arr = parse_message("[1,2]")
    assert_eq(arr.unwrap_err().to_string(), "BadEnvelope", "array is not an envelope")
    const missing = parse_message("{\"id\":1,\"method\":\"x\"}")
    assert_eq(missing.unwrap_err().to_string(), "BadEnvelope", "jsonrpc field is required")
}

test "write_notification exact bytes" {
    let sb = string_builder(64)
    defer sb.deinit()
    write_notification(sb.writer(), "initialized")
    assert_eq(sb.as_view(),
        "Content-Length: 40\r\n\r\n{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}",
        "transcript-exact output")
}

test "write_response echoes integer id without fraction" {
    const got = parse_message("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"shutdown\"}")
    let msg = got.unwrap()
    defer msg.deinit()

    let sb = string_builder(64)
    defer sb.deinit()
    const nul = json_null()
    write_response(sb.writer(), msg.id().unwrap(), &nul)
    assert_true(contains(sb.as_view(), "\"id\":7,"), "id 7 comes back as 7")
    assert_true(contains(sb.as_view(), "\"result\":null"), "null result is explicit")
}

test "write_response echoes string id verbatim" {
    const got = parse_message("{\"jsonrpc\":\"2.0\",\"id\":\"a-1\",\"method\":\"shutdown\"}")
    let msg = got.unwrap()
    defer msg.deinit()

    let sb = string_builder(64)
    defer sb.deinit()
    const nul = json_null()
    write_response(sb.writer(), msg.id().unwrap(), &nul)
    assert_true(contains(sb.as_view(), "\"id\":\"a-1\""), "string id round-trips")
}

test "write_error shape" {
    let sb = string_builder(64)
    defer sb.deinit()
    const nul = json_null()
    write_error(sb.writer(), &nul, METHOD_NOT_FOUND, "no such method")
    assert_true(contains(sb.as_view(),
            "\"error\":{\"code\":-32601,\"message\":\"no such method\"}"),
        "error object carries code and message")
    assert_true(contains(sb.as_view(), "\"id\":null"), "unknown id is null")
}

test "write_request with params" {
    let sb = string_builder(64)
    defer sb.deinit()
    let params = json_object()
    defer params.deinit()
    params.as_object().unwrap().json_set("n", json_number(2.0))
    write_request(sb.writer(), 1, "window/workDoneProgress/create", Some(&params))
    assert_true(contains(sb.as_view(), "\"id\":1,\"method\":\"window/workDoneProgress/create\""),
        "request carries id and method")
    assert_true(contains(sb.as_view(), "\"params\":{\"n\":2}"), "params serialized in place")
}

test "read_message end to end" {
    let sb = string_builder(64)
    defer sb.deinit()
    write_notification(sb.writer(), "exit")
    let mr = mem_reader(sb.as_view())
    const got = read_message(mr.reader())
    assert_true(got.is_ok(), "framed message parses")
    let msg = got.unwrap()
    defer msg.deinit()
    assert_eq(msg.method().unwrap(), "exit", "method survives framing")
}
