// Parser — turns a Token stream into a CstNode tree.
//
// Recursive descent. Error recovery produces NodeKind.Error subtrees that
// preserve their child tokens so the formatter can still round-trip broken
// source.

import std.list
import flang_parser.token
import flang_parser.lexer
import flang_parser.cst

pub type Parser = struct {
    tokens: List(Token)
    position: usize
}

pub fn parser(tokens: List(Token)) Parser {
    return .{ tokens = tokens, position = 0 }
}

pub fn parse_module(self: &Parser) CstNode {
    let children: List(CstChild) = list(self.tokens.len)
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
