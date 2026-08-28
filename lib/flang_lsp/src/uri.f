// file:// URI <-> filesystem path conversion, the LSP's only URI need.
//
// Paths are kept in the resolver's convention: forward slashes, and a lowercased drive letter on
// Windows-style paths so every path derived from a client URI compares equal regardless of how the
// client cased the drive. `path_to_uri` percent-encodes everything outside the URI unreserved set
// (plus `/` and `:`); `uri_to_path` decodes any percent escape.
//
// ponytail: no UNC (`file://server/share`) support; add when a workspace actually lives on a share.

import std.list
import std.option
import std.string
import std.string_builder
import std.test

// The path a `file://` URI names, or null for any other scheme. `file:///c%3A/x` and `file:///C:/x`
// both map to `c:/x`.
pub fn uri_to_path(uri: String) OwnedString? {
    const rest = strip_prefix(uri, "file://")
    if rest.is_none() {
        return null
    }
    let decoded = percent_decode(rest.unwrap())
    defer decoded.deinit()
    let p = decoded.as_view()

    // `file:///c:/x` decodes to `/c:/x`; drop the slash in front of a drive letter.
    if p.len > 2 and p[0] == '/' and p[2] == ':' {
        p = p[1..p.len]
    }

    return Some(normalize_fs_path(p))
}

// A path in this module's convention: forward slashes and a lowercased drive letter. Every path the
// server compares - URI-derived, glob-derived, or configured - must pass through here first; module
// dedup during analysis is by path string, so one file reached under two spellings would load
// twice.
pub fn normalize_fs_path(p: String) OwnedString {
    let sb = string_builder(p.len)
    defer sb.deinit()
    for i in 0..p.len {
        let c = p[i]
        if c == '\\' {
            c = '/'
        }
        if i == 0 and p.len > 1 and p[1] == ':' and c >= 'A' and c <= 'Z' {
            c = c + 32 // lowercase the drive letter
        }
        sb.append_byte(c)
    }
    return sb.to_string()
}

// A `file:///`-scheme URI for a forward-slash path. Absolute Windows paths (`c:/x`) gain the
// leading slash the scheme requires.
pub fn path_to_uri(path: String) OwnedString {
    let sb = string_builder(path.len + 12)
    defer sb.deinit()
    sb.append("file://")
    if !(path.len > 0 and path[0] == '/') {
        sb.append('/')
    }
    for i in 0..path.len {
        const c = path[i]
        if is_uri_safe(c) {
            sb.append_byte(c)
        } else {
            sb.append('%')
            sb.append_byte(hex_digit(c >>> 4))
            sb.append_byte(hex_digit(c & 0x0F))
        }
    }
    return sb.to_string()
}

fn is_uri_safe(c: u8) bool {
    if c >= 'a' and c <= 'z' {
        return true
    }
    if c >= 'A' and c <= 'Z' {
        return true
    }
    if c >= '0' and c <= '9' {
        return true
    }
    return c == '/' or c == ':' or c == '-' or c == '.' or c == '_' or c == '~'
}

fn hex_digit(v: u8) u8 {
    return if v < 10 { '0' + v } else { 'a' + (v - 10) }
}

fn percent_decode(s: String) OwnedString {
    let sb = string_builder(s.len)
    defer sb.deinit()
    let i: usize = 0
    while i < s.len {
        const c = s[i]
        if c == '%' and i + 2 < s.len {
            const hi = hex_value(s[i + 1])
            const lo = hex_value(s[i + 2])
            if hi.is_some() and lo.is_some() {
                sb.append_byte(hi.unwrap() * 16 + lo.unwrap())
                i = i + 3
                continue
            }
        }
        sb.append_byte(c)
        i = i + 1
    }
    return sb.to_string()
}

fn hex_value(c: u8) u8? {
    if c >= '0' and c <= '9' {
        return Some(c - '0')
    }
    if c >= 'a' and c <= 'f' {
        return Some(c - 'a' + 10)
    }
    if c >= 'A' and c <= 'F' {
        return Some(c - 'A' + 10)
    }
    return null
}

// Tests

test "windows uri decodes to a lowercase-drive forward-slash path" {
    let p = uri_to_path("file:///c%3A/Users/x%20y/a.f")
    assert_true(p.is_some(), "file scheme accepted")
    let owned = p.unwrap()
    defer owned.deinit()
    assert_eq(owned.as_view(), "c:/Users/x y/a.f", "decoded, unslashed, lowercased drive")

    let up = uri_to_path("file:///C:/a.f")
    let owned2 = up.unwrap()
    defer owned2.deinit()
    assert_eq(owned2.as_view(), "c:/a.f", "uppercase drive normalises down")
}

test "posix uri keeps its leading slash" {
    let p = uri_to_path("file:///home/u/a.f")
    let owned = p.unwrap()
    defer owned.deinit()
    assert_eq(owned.as_view(), "/home/u/a.f", "rooted path preserved")
}

test "non-file schemes are rejected" {
    assert_true(uri_to_path("untitled:Untitled-1").is_none(), "untitled")
    assert_true(uri_to_path("flang-generated:///x.f").is_none(), "custom scheme")
}

test "path round-trips through a uri" {
    let u = path_to_uri("c:/Users/x y/a.f")
    defer u.deinit()
    assert_eq(u.as_view(), "file:///c:/Users/x%20y/a.f", "space encoded, drive kept")

    let back = uri_to_path(u.as_view())
    let owned = back.unwrap()
    defer owned.deinit()
    assert_eq(owned.as_view(), "c:/Users/x y/a.f", "and back")

    let posix = path_to_uri("/home/u/a.f")
    defer posix.deinit()
    assert_eq(posix.as_view(), "file:///home/u/a.f", "rooted path gets no extra slash")
}
