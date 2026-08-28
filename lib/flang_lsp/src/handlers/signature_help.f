// textDocument/signatureHelp: the call the cursor is inside and which argument it is on, recovered
// from the LIVE buffer by a backward token-ish scan - the analysis is stale mid-keystroke, exactly
// when signature help fires, so the text is the only truth. The server resolves the callee name
// against the function registry's overload set and renders each declaration's source slice.
//
// ponytail: the scan does not skip string literals, so a `(` or `,` inside a string argument can
// shift the count; tokenize the prefix if it ever bites.

import std.allocator
import std.list
import std.option
import std.string
import std.test
import flang_lsp.query

// The callee identifier and zero-based argument index at the cursor. Null when the cursor is not
// inside a call's parentheses.
pub type CallSite = struct {
    name: OwnedString
    active: usize
}

pub fn deinit(self: &CallSite) {
    self.name.deinit()
}

// Byte-wise scanning is UTF-8-correct throughout this file: identifiers are ASCII-only (lexer.f
// `is_ident_continuation`, and `query.is_ident_char` matching it), and the delimiter bytes compared
// against (`(`, `,`, brackets) never occur inside a multi-byte sequence.

// Scan backwards from `offset` for the unmatched `(` and count top-level commas on the way.
pub fn call_site_at(text: String, offset: usize, allocator: &Allocator? = null) CallSite? {
    let depth: i32 = 0
    let commas: usize = 0
    let i = if offset > text.len { text.len } else { offset }
    while i > 0 {
        i = i - 1
        const c = text[i]
        if c == ')' or c == ']' or c == '}' {
            depth = depth + 1
            continue
        }
        if c == '[' or c == '{' {
            if depth > 0 {
                depth = depth - 1
            }
            continue
        }
        if c == ',' and depth == 0 {
            commas = commas + 1
            continue
        }
        if c == '(' {
            if depth > 0 {
                depth = depth - 1
                continue
            }
            // The unmatched opener: the callee identifier ends right before it.
            if i == 0 or !is_ident_char(text[i - 1]) {
                return null
            }
            let start = i - 1
            while start > 0 and is_ident_char(text[start - 1]) {
                start = start - 1
            }
            return Some(CallSite {
                name = from_view(text[start..i], allocator),
                active = commas,
            })
        }
    }
    return null
}

// Split a rendered signature label into its parameter label ranges: the substrings between the
// first `(` and its matching `)`, cut at top-level commas, whitespace-trimmed. Each is a substring
// of `label`, which is what LSP needs to highlight the active parameter.
pub fn param_labels(label: String, allocator: &Allocator? = null) List(String) {
    let out: List(String) = list(4, allocator)
    const open = find(label, '(')
    if open.is_none() {
        return out
    }
    let depth: i32 = 0
    let start = open.unwrap() + 1
    let i = start
    while i < label.len {
        const c = label[i]
        if c == '(' or c == '[' or c == '{' {
            depth = depth + 1
        } else if c == ')' or c == ']' or c == '}' {
            if depth == 0 and c == ')' {
                push_trimmed(&out, label, start, i)
                return out
            }
            depth = depth - 1
        } else if c == ',' and depth == 0 {
            push_trimmed(&out, label, start, i)
            start = i + 1
        }
        i = i + 1
    }
    return out
}

fn push_trimmed(out: &List(String), label: String, start: usize, end: usize) {
    let s = start
    while s < end and (label[s] == ' ' or label[s] == '\n' or label[s] == '\t') {
        s = s + 1
    }
    let e = end
    while e > s and (label[e - 1] == ' ' or label[e - 1] == '\n' or label[e - 1] == '\t') {
        e = e - 1
    }
    if e > s {
        out.push(label[s..e])
    }
}

// Tests

test "call_site_at finds the callee and counts top-level commas" {
    const src = "let r = point(a, g(b, c), "
    const site = call_site_at(src, src.len)
    assert_true(site.is_some(), "cursor is inside the call")
    let s = site.unwrap()
    assert_eq(s.name.as_view(), "point", "outer callee, not the nested one")
    assert_eq(s.active, 2 as usize, "nested call commas do not count")
    s.deinit()
}

test "call_site_at outside any call answers null" {
    const src = "let r = done()"
    assert_true(call_site_at(src, src.len).is_none(), "balanced text, no open call")
    assert_true(call_site_at("x + y", 3).is_none(), "no parentheses at all")
}

test "call_site_at handles ufcs receivers" {
    const src = "xs.push("
    const site = call_site_at(src, src.len)
    let s = site.unwrap()
    assert_eq(s.name.as_view(), "push", "method name only")
    assert_eq(s.active, 0 as usize, "first argument")
    s.deinit()
}

test "param_labels slices the parameter list" {
    const label = "pub fn go(a: i32, b: List(i32), c: &Dict(String, i32)) i32"
    let ps = param_labels(label)
    defer ps.deinit()
    assert_eq(ps.len, 3 as usize, "three parameters")
    assert_eq(ps[0], "a: i32", "first")
    assert_eq(ps[1], "b: List(i32)", "generic comma does not split")
    assert_eq(ps[2], "c: &Dict(String, i32)", "nested generic intact")
}

test "param_labels of a nullary signature is empty" {
    let ps = param_labels("fn go() i32")
    defer ps.deinit()
    assert_eq(ps.len, 0 as usize, "no parameters")
}
