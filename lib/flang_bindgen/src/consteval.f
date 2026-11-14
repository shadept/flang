// Integer constant expressions: enum values, array bounds, and the expansion of an object-like
// macro. Arithmetic follows C's usual conversions closely enough to give a constant its C type; a
// value that does not fold (a pointer, a struct, a call) is not a constant.

import std.collections.dict
import std.collections.list
import std.option
import std.string
import std.test

import flang_bindgen.lexer
import flang_bindgen.model

/// Fold `toks` to an integer constant, or null when it is not one.
pub fn eval_int(m: &CModel, host: Host, toks: CTok[]) CInt? {
    if toks.len == 0 {
        return null
    }
    let e = Eval { m = m, host = host, toks = toks, pos = 0, ok = true }
    const v = e.ternary()
    if !e.ok or e.pos != toks.len {
        return null
    }
    return Some(v)
}

// The words of an integer type, gathered one at a time: `unsigned long long`, `short`, `__int64`.
pub type IntWords = struct {
    unsigned: bool
    signed: bool
    longs: u32
    base: Prim?
    any: bool
}

pub fn int_words() IntWords {
    return IntWords { unsigned = false, signed = false, longs = 0, base = null, any = false }
}

/// Take `w` when it is an integer type word; false leaves `self` unchanged.
pub fn take(self: &IntWords, w: String) bool {
    const known = w match {
        "unsigned" => {
            self.unsigned = true
            true
        }
        "signed" | "__signed__" | "__signed" => {
            self.signed = true
            true
        }
        "long" => {
            self.longs = self.longs + 1
            true
        }
        "__int64" => {
            self.longs = 2
            true
        }
        "short" | "__int16" => {
            self.base = Some(Prim.Short)
            true
        }
        "char" | "__int8" => {
            self.base = Some(Prim.Char)
            true
        }
        "_Bool" | "bool" => {
            self.base = Some(Prim.Bool)
            true
        }
        "int" | "__int32" => true
        _ => false
    }
    if known {
        self.any = true
    }
    return known
}

pub fn prim(self: &IntWords) Prim {
    return make_int_prim(self.base, self.unsigned, self.signed, self.longs)
}

pub fn prim_size(host: Host, p: Prim) u64? {
    return p match {
        Bool | Char | SChar | UChar => Some(1u64)
        Short | UShort => Some(2u64)
        Int | UInt | Float => Some(4u64)
        Long | ULong => Some((host.long_bits / 8) as u64)
        LongLong | ULongLong | Double => Some(8u64)
        LongDouble => null
    }
}

pub fn is_unsigned(p: Prim) bool {
    return p match {
        Bool | UChar | UShort | UInt | ULong | ULongLong => true
        _ => false
    }
}

type Eval = struct {
    m: &CModel
    host: Host
    toks: CTok[]
    pos: usize
    ok: bool
}

fn peek(self: &Eval) CTok? {
    if self.pos >= self.toks.len {
        return null
    }
    return Some(self.toks[self.pos])
}

fn at_punct(self: &Eval, p: String) bool {
    return self.pos < self.toks.len and self.toks[self.pos].is_punct(p)
}

fn bad(self: &Eval) CInt {
    self.ok = false
    return CInt { value = 0, prim = Prim.Int }
}

fn ternary(self: &Eval) CInt {
    const c = self.binary(0)
    if !self.at_punct("?") {
        return c
    }
    self.pos = self.pos + 1
    const a = self.ternary()
    if !self.at_punct(":") {
        return self.bad()
    }
    self.pos = self.pos + 1
    const b = self.ternary()
    return if c.value != 0 { a } else { b }
}

// Precedence climbing over C's binary operators; `min` is the weakest level still accepted.
fn binary(self: &Eval, min: u32) CInt {
    let lhs = self.unary()
    while self.ok {
        const t = self.peek()
        if t.is_none() or t.unwrap().kind != CTokKind.Punct {
            break
        }
        const op = t.unwrap().text
        const prec = binary_prec(op)
        if prec == 0 or prec < min {
            break
        }
        self.pos = self.pos + 1
        const rhs = self.binary(prec + 1)
        lhs = self.apply(op, lhs, rhs)
    }
    return lhs
}

fn binary_prec(op: String) u32 {
    return op match {
        "||" => 1
        "&&" => 2
        "|" => 3
        "^" => 4
        "&" => 5
        "==" | "!=" => 6
        "<" | "<=" | ">" | ">=" => 7
        "<<" | ">>" => 8
        "+" | "-" => 9
        "*" | "/" | "%" => 10
        _ => 0
    }
}

fn apply(self: &Eval, op: String, a: CInt, b: CInt) CInt {
    const shift = op == "<<" or op == ">>"
    const logical = op == "&&" or op == "||"
    const compare = op match {
        "==" | "!=" | "<" | "<=" | ">" | ">=" => true
        _ => false
    }
    const p = if shift { promote(a.prim) } else { common(self.host, a.prim, b.prim) }
    const u = is_unsigned(p)
    const x = a.value
    const y = b.value
    const v: i64 = op match {
        "*" => x * y
        "/" => {
            if y == 0 {
                return self.bad()
            }
            if u {
                ((x as u64) / (y as u64)) as i64
            } else {
                x / y
            }
        }
        "%" => {
            if y == 0 {
                return self.bad()
            }
            if u {
                ((x as u64) % (y as u64)) as i64
            } else {
                x % y
            }
        }
        "+" => x + y
        "-" => x - y
        "<<" => x << y
        ">>" => if u { ((x as u64) >> (y as u64)) as i64 } else { x >> y }
        "<" => bool_int(if u { (x as u64) < (y as u64) } else { x < y })
        "<=" => bool_int(if u { (x as u64) <= (y as u64) } else { x <= y })
        ">" => bool_int(if u { (x as u64) > (y as u64) } else { x > y })
        ">=" => bool_int(if u { (x as u64) >= (y as u64) } else { x >= y })
        "==" => bool_int(x == y)
        "!=" => bool_int(x != y)
        "&" => x & y
        "^" => x ^ y
        "|" => x | y
        "&&" => bool_int(x != 0 and y != 0)
        "||" => bool_int(x != 0 or y != 0)
        _ => return self.bad()
    }
    if compare or logical {
        return CInt { value = v, prim = Prim.Int }
    }
    return wrap(self.host, v, p)
}

fn bool_int(b: bool) i64 {
    return if b { 1 } else { 0 }
}

fn unary(self: &Eval) CInt {
    const t = self.peek()
    if t.is_none() {
        return self.bad()
    }
    const tok = t.unwrap()
    if tok.kind == CTokKind.Punct {
        tok.text match {
            "-" => {
                self.pos = self.pos + 1
                const v = self.unary()
                const p = promote(v.prim)
                return wrap(self.host, 0 - v.value, p)
            }
            "+" => {
                self.pos = self.pos + 1
                const v = self.unary()
                return CInt { value = v.value, prim = promote(v.prim) }
            }
            "~" => {
                self.pos = self.pos + 1
                const v = self.unary()
                const p = promote(v.prim)
                return wrap(self.host, ~v.value, p)
            }
            "!" => {
                self.pos = self.pos + 1
                const v = self.unary()
                return CInt { value = bool_int(v.value == 0), prim = Prim.Int }
            }
            "(" => return self.paren()
            _ => return self.bad()
        }
    }
    return self.primary()
}

// `(expr)` or a cast `(type) expr`.
fn paren(self: &Eval) CInt {
    self.pos = self.pos + 1
    const cast = self.cast_type()
    if cast.is_some() {
        if !self.at_punct(")") {
            return self.bad()
        }
        self.pos = self.pos + 1
        const v = self.unary()
        return wrap(self.host, v.value, cast.unwrap())
    }
    const v = self.ternary()
    if !self.at_punct(")") {
        return self.bad()
    }
    self.pos = self.pos + 1
    return v
}

// The integer type a cast names, when the tokens at `pos` spell one. Leaves `pos` alone otherwise.
fn cast_type(self: &Eval) Prim? {
    const start = self.pos
    let iw = int_words()
    while self.pos < self.toks.len and self.toks[self.pos].kind == CTokKind.Ident {
        const w = self.toks[self.pos].text
        if iw.take(w) or w == "const" or w == "volatile" {
            self.pos = self.pos + 1
            continue
        }
        if !iw.any {
            const named = self.typedef_prim(w)
            if named.is_some() {
                self.pos = self.pos + 1
                return named
            }
        }
        break
    }
    if !iw.any or self.at_punct("*") {
        self.pos = start
        return null
    }
    return Some(iw.prim())
}

fn typedef_prim(self: &Eval, name: String) Prim? {
    const i = self.m.typedef_ids.get(name)
    if i.is_none() {
        return null
    }
    return resolve_prim(self.m, self.m.typedefs[i.unwrap() as usize].ty)
}

/// The integer or floating primitive a type is, through typedefs and enums.
pub fn resolve_prim(m: &CModel, t: TyId) Prim? {
    return m.ty(t) match {
        TPrim(p) => Some(p)
        TEnum(_) => Some(Prim.Int)
        TNamed(n) => m.typedef_ids.get(n) match {
            Some(i) => resolve_prim(m, m.typedefs[i as usize].ty)
            None => null
        }
        _ => null
    }
}

pub fn make_int_prim(base: Prim?, unsigned: bool, signed: bool, longs: u32) Prim {
    if base.is_some() {
        const b = base.unwrap()
        return b match {
            Char => if unsigned { Prim.UChar } else if signed { Prim.SChar } else { Prim.Char }
            Short => if unsigned { Prim.UShort } else { Prim.Short }
            _ => b
        }
    }
    if longs >= 2 {
        return if unsigned { Prim.ULongLong } else { Prim.LongLong }
    }
    if longs == 1 {
        return if unsigned { Prim.ULong } else { Prim.Long }
    }
    return if unsigned { Prim.UInt } else { Prim.Int }
}

fn primary(self: &Eval) CInt {
    const tok = self.toks[self.pos]
    self.pos = self.pos + 1
    return tok.kind match {
        Number => parse_int_literal(self.host, tok.text) match {
            Some(v) => v
            None => self.bad()
        }
        CharLit => char_value(tok.text) match {
            Some(v) => CInt { value = v, prim = Prim.Int }
            None => self.bad()
        }
        Ident => {
            if tok.text == "sizeof" {
                return self.size_of()
            }
            self.m.enum_values.get(tok.text) match {
                Some(v) => CInt { value = v, prim = Prim.Int }
                None => self.bad()
            }
        }
        _ => self.bad()
    }
}

fn size_of(self: &Eval) CInt {
    if !self.at_punct("(") {
        return self.bad()
    }
    self.pos = self.pos + 1
    const start = self.pos
    const p = self.cast_type()
    let size: u64? = null
    if p.is_some() and self.at_punct(")") {
        size = prim_size(self.host, p.unwrap())
    } else {
        self.pos = start
        const is_ptr = self.pos + 1 < self.toks.len and self.toks[self.pos + 1].is_punct("*")
        if self.pos < self.toks.len and self.toks[self.pos].kind == CTokKind.Ident and is_ptr {
            self.pos = self.pos + 2
            size = Some(8u64)
        }
    }
    if size.is_none() or !self.at_punct(")") {
        return self.bad()
    }
    self.pos = self.pos + 1
    return CInt { value = size.unwrap() as i64, prim = Prim.ULongLong }
}

/// Read a C integer literal: decimal, hex, octal or binary, with `u`/`l`/`ll` or MSVC `i64` suffixes.
pub fn parse_int_literal(host: Host, text: String) CInt? {
    let i: usize = 0
    let base: u64 = 10
    if text.len > 1 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X') {
        base = 16
        i = 2
    } else if text.len > 1 and text[0] == '0' and (text[1] == 'b' or text[1] == 'B') {
        base = 2
        i = 2
    } else if text.len > 1 and text[0] == '0' {
        base = 8
        i = 1
    }
    const digits_start = i
    let v: u64 = 0
    while i < text.len {
        const d = digit_value(text[i])
        if d.is_none() or d.unwrap() >= base {
            break
        }
        v = v * base + d.unwrap()
        i = i + 1
    }
    if i == digits_start and base != 8 {
        return null
    }
    const suffix = text[i..text.len]
    let unsigned = false
    let longs: u32 = 0
    let j: usize = 0
    while j < suffix.len {
        const c = suffix[j]
        if c == 'u' or c == 'U' {
            unsigned = true
            j = j + 1
        } else if c == 'l' or c == 'L' {
            longs = longs + 1
            j = j + 1
        } else if suffix[j..suffix.len] == "i64" {
            longs = 2
            j = suffix.len
        } else if suffix[j..suffix.len] == "i32" or suffix[j..suffix.len] == "i16"
            or suffix[j..suffix.len] == "i8" {
            j = suffix.len
        } else {
            return null
        }
    }
    let p = make_int_prim(null, unsigned, false, longs)
    // An unsuffixed literal too wide for its type takes the next type that holds it.
    const fits_i32 = v <= 0x7FFFFFFFu64
    const fits_u32 = v <= 0xFFFFFFFFu64
    if longs == 0 {
        if !unsigned and !fits_i32 {
            p = if base != 10 and fits_u32 { Prim.UInt } else { Prim.LongLong }
        } else if unsigned and !fits_u32 {
            p = Prim.ULongLong
        }
    }
    if longs == 1 and host.long_bits == 32 and !fits_u32 {
        p = if unsigned { Prim.ULongLong } else { Prim.LongLong }
    }
    if p == Prim.LongLong and v > 0x7FFFFFFFFFFFFFFFu64 {
        p = Prim.ULongLong
    }
    return Some(CInt { value = v as i64, prim = p })
}

fn digit_value(c: u8) u64? {
    if c >= '0' and c <= '9' {
        return Some((c - '0') as u64)
    }
    if c >= 'a' and c <= 'f' {
        return Some((c - 'a' + 10) as u64)
    }
    if c >= 'A' and c <= 'F' {
        return Some((c - 'A' + 10) as u64)
    }
    return null
}

fn char_value(text: String) i64? {
    let q: usize = 0
    while q < text.len and text[q] != '\'' {
        q = q + 1
    }
    if q + 2 >= text.len {
        return null
    }
    const body = text[q + 1..text.len - 1]
    if body.len == 1 {
        return Some(body[0] as i64)
    }
    if body[0] != '\\' {
        return null
    }
    return body[1] match {
        'n' => Some(10i64)
        't' => Some(9i64)
        'r' => Some(13i64)
        '0' => Some(0i64)
        '\\' => Some(92i64)
        '\'' => Some(39i64)
        '"' => Some(34i64)
        'x' => {
            let v: i64 = 0
            for k in 2..body.len {
                const d = digit_value(body[k])
                if d.is_none() {
                    return null
                }
                v = v * 16 + (d.unwrap() as i64)
            }
            Some(v)
        }
        _ => null
    }
}

fn promote(p: Prim) Prim {
    return p match {
        Bool | Char | SChar | UChar | Short | UShort => Prim.Int
        _ => p
    }
}

fn rank(p: Prim) u32 {
    return p match {
        Long | ULong => 2
        LongLong | ULongLong => 3
        _ => 1
    }
}

fn int_bits(host: Host, p: Prim) u32 {
    return p match {
        Long | ULong => host.long_bits
        LongLong | ULongLong => 64
        Bool => 1
        Char | SChar | UChar => 8
        Short | UShort => 16
        _ => 32
    }
}

fn to_unsigned(p: Prim) Prim {
    return p match {
        Int => Prim.UInt
        Long => Prim.ULong
        LongLong => Prim.ULongLong
        _ => p
    }
}

// C's usual arithmetic conversions, for integers.
fn common(host: Host, a0: Prim, b0: Prim) Prim {
    const a = promote(a0)
    const b = promote(b0)
    if a == b {
        return a
    }
    const hi = if rank(a) >= rank(b) { a } else { b }
    const lo = if rank(a) >= rank(b) { b } else { a }
    if rank(a) == rank(b) {
        return to_unsigned(hi)
    }
    if is_unsigned(hi) or !is_unsigned(lo) {
        return hi
    }
    if int_bits(host, hi) > int_bits(host, lo) {
        return hi
    }
    return to_unsigned(hi)
}

// Reduce `v` to the range of `p`, as C's conversion to `p` does.
fn wrap(host: Host, v: i64, p: Prim) CInt {
    const bits = int_bits(host, p)
    if bits >= 64 {
        return CInt { value = v, prim = p }
    }
    if p == Prim.Bool {
        return CInt { value = bool_int(v != 0), prim = p }
    }
    const mask = (1i64 << (bits as i64)) - 1
    let r = v & mask
    if !is_unsigned(p) and (r >> ((bits - 1) as i64)) & 1 == 1 {
        r = r - (1i64 << (bits as i64))
    }
    return CInt { value = r, prim = p }
}

fn eval_text(src: String) CInt? {
    const lexed = lex_c(src)
    defer lexed.deinit()
    const m = c_model()
    defer m.deinit()
    m.enum_values.set("K", 7)
    const host = Host { long_bits = 32, wchar_bits = 16 }
    const toks = lexed.toks.as_slice()
    return eval_int(&m, host, toks[0..toks.len - 1])
}

test "literal suffixes give C types" {
    assert_eq(eval_text("0x20u").unwrap().prim == Prim.UInt, true, "u is unsigned int")
    assert_eq(eval_text("0x1ui64").unwrap().prim == Prim.ULongLong, true, "MSVC ui64")
    assert_eq(eval_text("0x80000000").unwrap().prim == Prim.UInt, true, "hex overflow to unsigned")
    assert_eq(eval_text("5000000000").unwrap().prim == Prim.LongLong, true, "decimal overflow")
    assert_eq(eval_text("017").unwrap().value, 15i64, "octal")
}

test "operators, casts and enum constants fold" {
    assert_eq(eval_text("(1u << 5) | 3").unwrap().value, 35i64, "shift and or")
    assert_eq(eval_text("-(K + 1)").unwrap().value, -8i64, "enum constant")
    assert_eq(eval_text("((unsigned char)0x1FF)").unwrap().value, 255i64, "cast truncates")
    assert_eq(eval_text("sizeof(int) * 2 - 1").unwrap().value, 7i64, "sizeof")
    assert_eq(eval_text("1 ? 2 : 3").unwrap().value, 2i64, "ternary")
    assert_eq(eval_text("'A'").unwrap().value, 65i64, "char literal")
}

test "non-constants do not fold" {
    assert_eq(eval_text("foo").is_none(), true, "unknown identifier")
    assert_eq(eval_text("1.5f").is_none(), true, "float")
    assert_eq(eval_text("(Color){ 1, 2 }").is_none(), true, "compound literal")
    assert_eq(eval_text("1 / 0").is_none(), true, "division by zero")
}
