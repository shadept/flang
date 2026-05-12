// Parser — turns a Token stream into a CstNode tree.
//
// Recursive descent. Error recovery produces NodeKind.Error subtrees that
// preserve their child tokens so the formatter can still round-trip broken
// source.

import std.allocator
import std.list
import std.option
import flang_parser.token
import flang_parser.lexer
import flang_parser.cst

pub type Parser = struct {
    tokens: List(Token)
    position: usize
    // Backs every CST node's child list. Resolved at construction so
    // internal call sites just forward `self.allocator` without
    // re-resolving.
    allocator: &Allocator
}

// Construct a Parser over the given token list. The list is borrowed
// — every CST node will reference the original tokens, so `tokens`
// must outlive the produced tree. `allocator` backs every CST child
// list; pass `null` to default to the global allocator (resolved once
// here via `or_global()`).
pub fn parser(tokens: List(Token), allocator: &Allocator? = null) Parser {
    return .{ tokens = tokens, position = 0, allocator = allocator.or_global() }
}

// Parse the entire token stream as a top-level module: imports,
// declarations, tests. Always returns a `Module` CST node, even on
// malformed input — bad subtrees are wrapped in `NodeKind.Error` so
// the formatter and CST consumers can still round-trip the source.
// Consumes every token up to and including `Eof`.
pub fn parse_module(self: &Parser) CstNode {
    let children: List(CstChild) = list(self.tokens.len, self.allocator)
    let start = 0usize
    let end = 0usize

    if self.tokens.len > 0 {
        start = self.tokens[0].offset
    }

    loop {
        if self.position >= self.tokens.len { break }
        const tok = self.tokens[self.position]
        const tok_end = tok.offset + tok.text.len
        if tok_end > end { end = tok_end }
        children.push(CstChild.TokenChild(tok))
        self.position = self.position + 1
    }

    return .{
        kind = NodeKind.Module,
        start = start,
        end = end,
        children = children,
    }
}
