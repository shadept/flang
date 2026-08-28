// textDocument/foldingRange: folds from delimiter nesting over the token stream - every `{}`, `()`,
// `[]` pair spanning enough lines to hide at least one. Token-based rather than AST-based so
// folding survives parse errors and covers every nesting level without an AST walk.

import std.allocator
import std.list
import std.option
import std.test
import flang_parser.lexer
import flang_parser.token

// A foldable region, in 0-based lines. `end_line` is the last hidden line; the closing delimiter's
// line stays visible.
pub type FoldRange = struct {
    start_line: usize
    end_line: usize
}

pub fn folding_ranges(text: String, allocator: &Allocator? = null) List(FoldRange) {
    let out: List(FoldRange) = list(0, allocator)
    let lx = lexer(text, allocator)
    let tokens = lx.tokenize()
    defer tokens.deinit()

    let open_kinds: List(u8) = list(16, allocator)
    defer open_kinds.deinit()
    let open_lines: List(usize) = list(16, allocator)
    defer open_lines.deinit()

    for &t in tokens {
        const opens: u8 = t.kind match {
            OpenBrace => 0u8
            OpenParenthesis => 1u8
            OpenBracket => 2u8
            else => 255u8
        }
        if opens != 255u8 {
            open_kinds.push(opens)
            open_lines.push(t.line)
            continue
        }
        const closes: u8 = t.kind match {
            CloseBrace => 0u8
            CloseParenthesis => 1u8
            CloseBracket => 2u8
            else => 255u8
        }
        if closes == 255u8 or open_kinds.len == 0 {
            continue
        }
        // A close that does not match the innermost open is broken code; leave the stack alone.
        if open_kinds[open_kinds.len - 1] != closes {
            continue
        }
        const _k = open_kinds.pop()
        const start = open_lines.pop().unwrap()
        if t.line > start + 1 {
            out.push(FoldRange { start_line = start, end_line = t.line - 1 })
        }
    }
    return out
}

// Tests

test "folding ranges fold multi-line delimiter pairs" {
    const src = "fn a(\n    x: i32,\n    y: i32,\n) {\n    if x > 0 {\n        return\n    }\n}\n"
    let folds = folding_ranges(src)
    defer folds.deinit()
    assert_eq(folds.len, 3 as usize, "params, if body, fn body")
    assert_eq(folds[0].start_line, 0 as usize, "param list opens on line 0")
    assert_eq(folds[0].end_line, 2 as usize, "closing paren line stays visible")
    assert_eq(folds[1].start_line, 4 as usize, "if body")
    assert_eq(folds[2].start_line, 3 as usize, "fn body closes last")
    assert_eq(folds[2].end_line, 6 as usize, "up to the line before the brace")
}

test "two-line blocks produce no fold" {
    let folds = folding_ranges("fn a() {\n}\n")
    defer folds.deinit()
    assert_eq(folds.len, 0 as usize, "nothing to hide")
}
