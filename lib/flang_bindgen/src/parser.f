// Declarations of preprocessed C, into a `CModel`.
//
// The parser reads what headers declare: typedefs, structs, unions, enums and function prototypes.
// Function bodies and initializers are skipped by bracket matching. Compiler extensions
// (`__declspec`, `__attribute__`, calling conventions, SAL leftovers) are skipped by name. A
// declaration it cannot read is recorded as an error with its file and line and skipped to the next
// `;`; system headers routinely hold such declarations, and only the ones a binding needs matter.

import std.collections.dict
import std.collections.list
import std.option
import std.string
import std.string_builder
import std.test

import flang_bindgen.consteval
import flang_bindgen.lexer
import flang_bindgen.model

/// Read every declaration in `lexed` into a model.
pub fn parse_c(lexed: &CLexed, host: Host) CModel {
    let p = Parser {
        m = c_model(),
        toks = lexed.toks.as_slice(),
        pos = 0,
        host = host,
        pack = 0,
        pack_stack = list(4),
        err = null,
    }
    while !p.at_eof() {
        const start = p.pos
        const t = p.cur()
        if t.kind == CTokKind.Pragma {
            p.pragma(t.text)
            p.pos = p.pos + 1
            continue
        }
        if t.is_punct(";") {
            p.pos = p.pos + 1
            continue
        }
        if t.is_ident("__flang_probe") {
            p.probe()
            continue
        }
        if p.inline_pragma() {
            continue
        }
        p.err = null
        if !p.external() {
            const why = p.err match {
                Some(e) => e
                None => "unsupported declaration"
            }
            p.m.errors.push(CError { file = t.file, line = t.line, message = from_view(why) })
            p.pos = start
            p.recover()
        }
    }
    p.pack_stack.deinit()
    return move p.m
}

type Parser = struct {
    m: CModel
    toks: CTok[]
    pos: usize
    host: Host
    // The `#pragma pack` value in force, 0 for the compiler default.
    pack: u32
    pack_stack: List(u32)
    err: String?
}

type Specs = struct {
    base: TyId
    is_typedef: bool
    // `static` or `inline`: no symbol the library exports.
    is_local: bool
}

type Declarator = struct {
    name: String
    ty: TyId
}

const NON_CONSTANT_BOUND: i64 = -2

type Suffix = enum {
    SArray(i64)
    SFunc(CRange, bool)
}

fn cur(self: &Parser) CTok {
    return self.toks[self.pos]
}

fn peek_at(self: &Parser, k: usize) CTok {
    const i = self.pos + k
    return if i < self.toks.len { self.toks[i] } else { self.toks[self.toks.len - 1] }
}

fn at_eof(self: &Parser) bool {
    return self.toks[self.pos].kind == CTokKind.Eof
}

fn at(self: &Parser, p: String) bool {
    return self.toks[self.pos].is_punct(p)
}

fn eat(self: &Parser, p: String) bool {
    if self.at(p) {
        self.pos = self.pos + 1
        return true
    }
    return false
}

fn fail(self: &Parser, why: String) bool {
    if self.err.is_none() {
        self.err = Some(why)
    }
    return false
}

// Skip to just past the next `;` at bracket depth 0, or past a top-level `{ ... }` group not
// followed by `;` (a function body).
fn recover(self: &Parser) {
    let depth: i32 = 0
    while !self.at_eof() {
        const t = self.cur()
        self.pos = self.pos + 1
        if t.kind != CTokKind.Punct {
            continue
        }
        t.text match {
            "(" | "[" => depth = depth + 1
            ")" | "]" => depth = depth - 1
            "{" => depth = depth + 1
            "}" => {
                depth = depth - 1
                if depth <= 0 {
                    self.eat(";")
                    return
                }
            }
            ";" => {
                if depth <= 0 {
                    return
                }
            }
            _ => {}
        }
    }
}

// Skip a balanced `( ... )`, `[ ... ]` or `{ ... }` starting at the current token.
fn skip_group(self: &Parser) {
    let depth: i32 = 0
    while !self.at_eof() {
        const t = self.cur()
        self.pos = self.pos + 1
        if t.kind != CTokKind.Punct {
            continue
        }
        t.text match {
            "(" | "[" | "{" => depth = depth + 1
            ")" | "]" | "}" => {
                depth = depth - 1
                if depth == 0 {
                    return
                }
            }
            _ => {}
        }
    }
}

// `#pragma pack(push, 8)`, `pack(pop)`, `pack(4)`, `pack()`. Other pragmas change no layout.
fn pragma(self: &Parser, text: String) {
    if !text.starts_with("pack") {
        return
    }
    const open = text.find('(')
    const close = text.rfind(')')
    if open.is_none() or close.is_none() {
        return
    }
    const args = text[open.unwrap() + 1..close.unwrap()]
    let n: u32? = null
    let push = false
    let pop = false
    const parts = args.split(',')
    defer parts.deinit()
    for part in parts {
        const w = part.trim()
        if w == "push" {
            push = true
        } else if w == "pop" {
            pop = true
        } else if w.len > 0 and w[0] >= '0' and w[0] <= '9' {
            n = Some(parse_u32_text(w))
        }
    }
    if push {
        self.pack_stack.push(self.pack)
    }
    if pop {
        self.pack = self.pack_stack.pop() match {
            Some(v) => v
            None => 0
        }
    }
    if n.is_some() {
        self.pack = n.unwrap()
    } else if !push and !pop {
        self.pack = 0
    }
}

// MSVC's `__pragma(pack(push, 8))`, standing between declarations. Preprocessors print C99's
// `_Pragma` as a `#pragma` line.
fn inline_pragma(self: &Parser) bool {
    if !self.cur().is_ident("__pragma") or !self.peek_at(1).is_punct("(") {
        return false
    }
    const from = self.pos + 2
    self.pos = self.pos + 1
    self.skip_group()
    const body = self.toks[from..self.pos - 1]
    let sb = string_builder(32)
    defer sb.deinit()
    for tok in body {
        sb.append(tok.text)
    }
    self.pragma(sb.as_view())
    return true
}

fn parse_u32_text(w: String) u32 {
    let v: u32 = 0
    for i in 0..w.len {
        if w[i] < '0' or w[i] > '9' {
            break
        }
        v = v * 10 + (w[i] - '0') as u32
    }
    return v
}

// ---- Declarations ----

fn external(self: &Parser) bool {
    const specs = self.specs()
    if specs.is_none() {
        return false
    }
    const s = specs.unwrap()
    if self.eat(";") {
        return true
    }
    while true {
        const d = self.declarator(s.base)
        if d.is_none() {
            return false
        }
        const decl = d.unwrap()
        self.skip_attributes()
        if self.at("{") {
            self.skip_group()
            return true
        }
        if self.at("=") {
            self.skip_initializer()
        }
        self.record_decl(s, decl)
        if self.eat(",") {
            continue
        }
        if !self.eat(";") {
            return self.fail("expected `;` after a declaration")
        }
        return true
    }
    return true
}

fn record_decl(self: &Parser, s: Specs, d: Declarator) {
    if d.name.len == 0 {
        return
    }
    const t = self.cur()
    if s.is_typedef {
        self.m.typedefs.push(CTypedef { name = d.name, ty = d.ty, file = t.file })
        const id = (self.m.typedefs.len - 1) as u32
        self.m.typedef_ids.set(d.name, id)
        self.m.decls.push(CDecl.DTypedef(id))
        return
    }
    const sig = self.m.ty(d.ty) match {
        TFunc(i) => Some(i)
        _ => null
    }
    if sig.is_none() or s.is_local {
        return
    }
    self.m.funcs.push(CFunc { name = d.name, sig = sig.unwrap(), file = t.file, line = t.line })
    self.m.decls.push(CDecl.DFunc((self.m.funcs.len - 1) as u32))
}

fn skip_initializer(self: &Parser) {
    self.pos = self.pos + 1
    while !self.at_eof() and !self.at(",") and !self.at(";") {
        if self.at("(") or self.at("{") or self.at("[") {
            self.skip_group()
        } else {
            self.pos = self.pos + 1
        }
    }
}

// `__attribute__((...))`, `__declspec(...)`, `__asm__("...")` and friends, wherever they stand.
fn skip_attributes(self: &Parser) {
    while self.cur().kind == CTokKind.Ident {
        const w = self.cur().text
        if is_attribute_word(w) {
            self.pos = self.pos + 1
            if self.at("(") {
                self.skip_group()
            }
            continue
        }
        if is_ignored_word(w) {
            self.pos = self.pos + 1
            continue
        }
        return
    }
}

fn is_attribute_word(w: String) bool {
    return w match {
        "__attribute__" | "__attribute" | "__declspec" | "__asm__" | "__asm" | "asm" | "__pragma"
            | "__alignof__" | "_Alignas" | "alignas" => true
        _ => false
    }
}

// Qualifiers and markers that change nothing a binding spells.
fn is_ignored_word(w: String) bool {
    return w match {
        "const" | "volatile" | "restrict" | "__restrict" | "__restrict__" | "__const" | "__volatile__"
            | "__volatile" | "_Nonnull" | "_Nullable" | "_Null_unspecified" | "__ptr64" | "__ptr32"
            | "__unaligned" | "__w64" | "__cdecl" | "__stdcall" | "__fastcall" | "__vectorcall"
            | "__thiscall" | "__clrcall" | "_cdecl" | "__extension__" | "register" | "auto"
            | "_Noreturn" | "noreturn" | "__sptr" | "__uptr" | "__nonnull" | "__nullable" => true
        _ => false
    }
}

fn is_aligning_attribute(self: &Parser) bool {
    const w = self.cur().text
    if w == "_Alignas" or w == "alignas" {
        return true
    }
    if w != "__declspec" and w != "__attribute__" and w != "__attribute" {
        return false
    }
    let k: usize = 1
    let depth: i32 = 0
    while self.pos + k < self.toks.len {
        const t = self.peek_at(k)
        if t.is_punct("(") {
            depth = depth + 1
        } else if t.is_punct(")") {
            depth = depth - 1
            if depth == 0 {
                return false
            }
        } else if t.is_ident("align") or t.is_ident("aligned") or t.is_ident("__aligned__")
            or t.is_ident("packed") or t.is_ident("__packed__") {
            return true
        }
        k = k + 1
    }
    return false
}

// Declaration specifiers: storage class, qualifiers and the base type.
fn specs(self: &Parser) Specs? {
    let is_typedef = false
    let is_local = false
    let iw = int_words()
    let is_void = false
    let float_word: Prim? = null
    let base: TyId? = null
    let bad: String? = null
    while true {
        const t = self.cur()
        if t.kind != CTokKind.Ident {
            break
        }
        const w = t.text
        if is_attribute_word(w) {
            if self.is_aligning_attribute() {
                bad = Some("an alignment or packing attribute")
            }
            self.pos = self.pos + 1
            if self.at("(") {
                self.skip_group()
            }
            continue
        }
        if is_ignored_word(w) or iw.take(w) {
            self.pos = self.pos + 1
            continue
        }
        const any_type = base.is_some() or iw.any or is_void or float_word.is_some()
        const handled = w match {
            "typedef" => {
                is_typedef = true
                true
            }
            "extern" => true
            "static" | "inline" | "__inline" | "__inline__" | "__forceinline" | "_Thread_local"
                | "__thread" => {
                is_local = true
                true
            }
            "float" => {
                float_word = Some(Prim.Float)
                true
            }
            "double" => {
                float_word = Some(Prim.Double)
                true
            }
            "void" => {
                is_void = true
                true
            }
            "__int128" | "_Complex" | "_Imaginary" | "_Float16" | "__bf16" | "__fp16" | "_Float128"
                | "__float128" | "__m64" | "_Atomic" => {
                bad = Some("a type FLang cannot spell")
                true
            }
            "__typeof__" | "__typeof" | "typeof" => {
                bad = Some("`typeof`")
                self.pos = self.pos + 1
                if self.at("(") {
                    self.skip_group()
                }
                continue
            }
            "struct" | "union" => {
                const r = self.record(w == "union")
                if r.is_none() {
                    return null
                }
                base = r
                continue
            }
            "enum" => {
                const e = self.enum_spec()
                if e.is_none() {
                    return null
                }
                base = e
                continue
            }
            _ => false
        }
        if handled {
            self.pos = self.pos + 1
            continue
        }
        if !any_type and self.m.typedef_ids.contains(w) {
            base = Some(self.m.add_ty(CTy.TNamed(w)))
            self.pos = self.pos + 1
            continue
        }
        break
    }
    let ty: TyId = 0
    if base.is_some() {
        ty = base.unwrap()
    } else if is_void {
        ty = self.m.add_ty(CTy.TVoid)
    } else if float_word.is_some() {
        const f = float_word.unwrap()
        const prim = if f == Prim.Double and iw.longs > 0 { Prim.LongDouble } else { f }
        ty = self.m.add_ty(CTy.TPrim(prim))
    } else if iw.any {
        ty = self.m.add_ty(CTy.TPrim(iw.prim()))
    } else {
        self.fail("expected a type")
        return null
    }
    if bad.is_some() {
        ty = self.m.add_ty(CTy.TBad(bad.unwrap()))
    }
    return Some(Specs { base = ty, is_typedef = is_typedef, is_local = is_local })
}

// `struct tag { fields }`, `struct tag`, `struct { fields }`; `pos` is on `struct` or `union`.
fn record(self: &Parser, is_union: bool) TyId? {
    const kw = self.cur()
    self.pos = self.pos + 1
    let aligned = false
    while self.cur().kind == CTokKind.Ident and is_attribute_word(self.cur().text) {
        if self.is_aligning_attribute() {
            aligned = true
        }
        self.pos = self.pos + 1
        if self.at("(") {
            self.skip_group()
        }
    }
    let tag = ""
    if self.cur().kind == CTokKind.Ident {
        tag = self.cur().text
        self.pos = self.pos + 1
    }
    if !self.at("{") {
        if tag.len == 0 {
            self.fail("expected a struct tag or body")
            return null
        }
        return Some(self.m.add_ty(CTy.TRecord(self.record_by_tag(tag, is_union, kw))))
    }
    self.pos = self.pos + 1
    let fields: List(CField) = list(8)
    defer fields.deinit()
    while !self.at("}") {
        if self.at_eof() {
            self.fail("unterminated struct body")
            return null
        }
        if self.cur().kind == CTokKind.Pragma {
            self.pragma(self.cur().text)
            self.pos = self.pos + 1
            continue
        }
        if self.eat(";") or self.inline_pragma() {
            continue
        }
        if self.cur().is_ident("_Static_assert") or self.cur().is_ident("static_assert") {
            self.pos = self.pos + 1
            self.skip_group()
            self.eat(";")
            continue
        }
        const s = self.specs()
        if s.is_none() {
            return null
        }
        const base = s.unwrap().base
        if self.eat(";") {
            fields.push(CField { name = "", ty = base, is_bitfield = false })
            continue
        }
        while true {
            let d = Declarator { name = "", ty = base }
            if !self.at(":") {
                const got = self.declarator(base)
                if got.is_none() {
                    return null
                }
                d = got.unwrap()
            }
            let bits = false
            if self.eat(":") {
                bits = true
                while !self.at(",") and !self.at(";") and !self.at_eof() {
                    self.pos = self.pos + 1
                }
            }
            self.skip_attributes()
            fields.push(CField { name = d.name, ty = d.ty, is_bitfield = bits })
            if !self.eat(",") {
                break
            }
        }
        if !self.eat(";") {
            self.fail("expected `;` after a struct member")
            return null
        }
    }
    self.pos = self.pos + 1
    self.skip_attributes()
    const start = self.m.fields.len as u32
    self.m.fields.push_all(fields.as_slice())
    const id = if tag.len > 0 { self.record_by_tag(tag, is_union, kw) } else {
        self.new_record("", is_union, kw)
    }
    const r = self.m.records[id as usize]
    self.m.records[id as usize] = CRecord {
        tag = r.tag,
        is_union = is_union,
        complete = true,
        fields = CRange { start = start, len = fields.len as u32 },
        pack = if aligned { 1 } else { self.pack },
        file = kw.file,
        line = kw.line,
    }
    return Some(self.m.add_ty(CTy.TRecord(id)))
}

fn record_by_tag(self: &Parser, tag: String, is_union: bool, at: CTok) u32 {
    self.m.tag_ids.get(tag) match {
        Some(d) => d match {
            DRecord(i) => return i
            _ => {}
        }
        None => {}
    }
    const id = self.new_record(tag, is_union, at)
    self.m.tag_ids.set(tag, CDecl.DRecord(id))
    return id
}

fn new_record(self: &Parser, tag: String, is_union: bool, at: CTok) u32 {
    self.m.records.push(CRecord {
        tag = tag,
        is_union = is_union,
        complete = false,
        fields = CRange { start = 0, len = 0 },
        pack = 0,
        file = at.file,
        line = at.line,
    })
    const id = (self.m.records.len - 1) as u32
    self.m.decls.push(CDecl.DRecord(id))
    return id
}

// `enum tag { A, B = 2 }` or `enum tag`; `pos` is on `enum`.
fn enum_spec(self: &Parser) TyId? {
    const kw = self.cur()
    self.pos = self.pos + 1
    self.skip_attributes()
    let tag = ""
    if self.cur().kind == CTokKind.Ident {
        tag = self.cur().text
        self.pos = self.pos + 1
    }
    if self.eat(":") {
        const underlying = self.specs()
        if underlying.is_none() {
            return null
        }
    }
    if !self.at("{") {
        if tag.len == 0 {
            self.fail("expected an enum tag or body")
            return null
        }
        return Some(self.m.add_ty(CTy.TEnum(self.enum_by_tag(tag, kw))))
    }
    self.pos = self.pos + 1
    const start = self.m.consts.len as u32
    let next: i64 = 0
    while !self.at("}") {
        if self.cur().kind != CTokKind.Ident {
            self.fail("expected an enumerator")
            return null
        }
        const name = self.cur().text
        self.pos = self.pos + 1
        self.skip_attributes()
        if self.eat("=") {
            const from = self.pos
            let depth: i32 = 0
            while !self.at_eof() {
                if depth == 0 and (self.at(",") or self.at("}")) {
                    break
                }
                if self.at("(") {
                    depth = depth + 1
                } else if self.at(")") {
                    depth = depth - 1
                }
                self.pos = self.pos + 1
            }
            const v = eval_int(&self.m, self.host, self.toks[from..self.pos])
            if v.is_none() {
                self.fail("an enumerator value that is not an integer constant")
                return null
            }
            next = v.unwrap().value
        }
        self.m.consts.push(CEnumConst { name = name, value = next })
        self.m.enum_values.set(name, next)
        next = next + 1
        if !self.eat(",") {
            break
        }
    }
    if !self.eat("}") {
        self.fail("expected `}` closing an enum")
        return null
    }
    const id = if tag.len > 0 { self.enum_by_tag(tag, kw) } else { self.new_enum("", kw) }
    const e = self.m.enums[id as usize]
    self.m.enums[id as usize] = CEnum {
        tag = e.tag,
        consts = CRange { start = start, len = self.m.consts.len as u32 - start },
        file = kw.file,
    }
    return Some(self.m.add_ty(CTy.TEnum(id)))
}

fn enum_by_tag(self: &Parser, tag: String, at: CTok) u32 {
    self.m.tag_ids.get(tag) match {
        Some(d) => d match {
            DEnum(i) => return i
            _ => {}
        }
        None => {}
    }
    const id = self.new_enum(tag, at)
    self.m.tag_ids.set(tag, CDecl.DEnum(id))
    return id
}

fn new_enum(self: &Parser, tag: String, at: CTok) u32 {
    self.m.enums.push(CEnum { tag = tag, consts = CRange { start = 0, len = 0 }, file = at.file })
    const id = (self.m.enums.len - 1) as u32
    self.m.decls.push(CDecl.DEnum(id))
    return id
}

// A declarator over `base`: pointers, a name (or none), array and function suffixes, and the
// parenthesized inner declarator of a function pointer, which applies to the type the suffixes
// outside it build.
fn declarator(self: &Parser, base0: TyId) Declarator? {
    let base = base0
    self.skip_attributes()
    while self.at("*") or self.at("^") {
        if self.at("^") {
            return self.fail_decl("a block pointer")
        }
        self.pos = self.pos + 1
        base = self.m.add_ty(CTy.TPtr(base))
        self.skip_attributes()
    }
    let name = ""
    let inner: usize? = null
    if self.at("(") and self.nested_declarator_follows() {
        inner = Some(self.pos + 1)
        self.skip_group()
    } else if self.cur().kind == CTokKind.Ident {
        name = self.cur().text
        self.pos = self.pos + 1
    }
    const ty = self.suffixes(base)
    if ty.is_none() {
        return null
    }
    if inner.is_none() {
        return Some(Declarator { name = name, ty = ty.unwrap() })
    }
    const after = self.pos
    self.pos = inner.unwrap()
    const d = self.declarator(ty.unwrap())
    if d.is_none() {
        return null
    }
    if !self.at(")") {
        return self.fail_decl("expected `)` closing a declarator")
    }
    self.pos = after
    return d
}

fn fail_decl(self: &Parser, why: String) Declarator? {
    self.fail(why)
    return null
}

// After a `(` in declarator position: a nested declarator (`(*f)`, `(__cdecl *f)`) rather than a
// parameter list.
fn nested_declarator_follows(self: &Parser) bool {
    const t = self.peek_at(1)
    if t.is_punct("*") or t.is_punct("^") or t.is_punct("(") {
        return true
    }
    if t.kind != CTokKind.Ident {
        return false
    }
    if is_ignored_word(t.text) or is_attribute_word(t.text) {
        return true
    }
    return false
}

fn suffixes(self: &Parser, base: TyId) TyId? {
    let list_: List(Suffix) = list(2)
    defer list_.deinit()
    while true {
        if self.at("[") {
            const from = self.pos + 1
            self.skip_group()
            const body = self.toks[from..self.pos - 1]
            let len: i64 = -1
            if body.len > 0 {
                len = eval_int(&self.m, self.host, strip_qualifiers(body)) match {
                    Some(v) => v.value
                    None => NON_CONSTANT_BOUND
                }
            }
            list_.push(Suffix.SArray(len))
            continue
        }
        if self.at("(") {
            self.pos = self.pos + 1
            const ps = self.params()
            if ps.is_none() {
                return null
            }
            const got = ps.unwrap()
            list_.push(Suffix.SFunc(got.0, got.1))
            self.skip_attributes()
            continue
        }
        break
    }
    let ty = base
    let k = list_.len
    while k > 0 {
        k = k - 1
        ty = list_[k] match {
            SArray(len) => {
                if len == NON_CONSTANT_BOUND {
                    self.m.add_ty(CTy.TBad("an array bound that is not an integer constant"))
                } else {
                    self.m.add_ty(CTy.TArray(ty, len))
                }
            }
            SFunc(range, variadic) => {
                self.m.sigs.push(CSig { params = range, ret = ty, variadic = variadic })
                self.m.add_ty(CTy.TFunc((self.m.sigs.len - 1) as u32))
            }
        }
    }
    return Some(ty)
}

// C99 lets an array parameter carry `static` and qualifiers inside its brackets.
fn strip_qualifiers(body: CTok[]) CTok[] {
    let i: usize = 0
    while i < body.len and body[i].kind == CTokKind.Ident and (body[i].text == "static"
        or is_ignored_word(body[i].text)) {
            i = i + 1
        }
    return body[i..body.len]
}

// A parameter list after its `(`, through the `)`.
fn params(self: &Parser) (CRange, bool)? {
    let ps: List(CParam) = list(4)
    defer ps.deinit()
    let variadic = false
    const empty = self.at(")") or (self.cur().is_ident("void") and self.peek_at(1).is_punct(")"))
    if empty {
        if !self.at(")") {
            self.pos = self.pos + 1
        }
        self.pos = self.pos + 1
        return Some((CRange { start = self.m.params.len as u32, len = 0 }, false))
    }
    while true {
        if self.eat("...") {
            variadic = true
            break
        }
        const s = self.specs()
        if s.is_none() {
            return null
        }
        const d = self.declarator(s.unwrap().base)
        if d.is_none() {
            return null
        }
        self.skip_attributes()
        ps.push(CParam { name = d.unwrap().name, ty = self.decay(d.unwrap().ty) })
        if !self.eat(",") {
            break
        }
    }
    if !self.eat(")") {
        self.fail("expected `)` closing a parameter list")
        return null
    }
    const start = self.m.params.len as u32
    self.m.params.push_all(ps.as_slice())
    return Some((CRange { start = start, len = ps.len as u32 }, variadic))
}

// A parameter of array or function type is a pointer.
fn decay(self: &Parser, t: TyId) TyId {
    return self.m.ty(t) match {
        TArray(elem, _) => self.m.add_ty(CTy.TPtr(elem))
        TFunc(_) => self.m.add_ty(CTy.TPtr(t))
        _ => t
    }
}

// `__flang_probe "NAME" <expansion> __flang_end`: one object-like macro, expanded by the
// preprocessor.
fn probe(self: &Parser) {
    self.pos = self.pos + 1
    const name_tok = self.cur()
    if name_tok.kind != CTokKind.Str {
        self.recover()
        return
    }
    self.pos = self.pos + 1
    const from = self.pos
    while !self.at_eof() and !self.cur().is_ident("__flang_end") {
        self.pos = self.pos + 1
    }
    const body = self.toks[from..self.pos]
    if !self.at_eof() {
        self.pos = self.pos + 1
    }
    const name = name_tok.text[1..name_tok.text.len - 1]
    const value = self.macro_value(body)
    if value.is_some() {
        self.m.macros.push(CMacro { name = name, value = value.unwrap() })
    }
}

fn macro_value(self: &Parser, body: CTok[]) CConst? {
    if body.len == 0 {
        return null
    }
    if all_strings(body) {
        const s = concat_strings(body)
        if s.is_none() {
            return null
        }
        self.m.strings.push(s.unwrap())
        return Some(CConst.StrConst((self.m.strings.len - 1) as u32))
    }
    const f = float_literal(body)
    if f.is_some() {
        return f
    }
    return eval_int(&self.m, self.host, body) match {
        Some(v) => Some(CConst.IntConst(v))
        None => null
    }
}

fn all_strings(body: CTok[]) bool {
    for t in body {
        if t.kind != CTokKind.Str or t.text[0] != '"' {
            return false
        }
    }
    return true
}

// Adjacent narrow string literals, concatenated and with their escapes decoded. Null when one holds
// an escape a FLang literal could not round-trip.
fn concat_strings(body: CTok[]) OwnedString? {
    let sb = string_builder(32)
    for t in body {
        const raw = t.text[1..t.text.len - 1]
        let i: usize = 0
        while i < raw.len {
            const c = raw[i]
            if c != '\\' {
                sb.append_byte(c)
                i = i + 1
                continue
            }
            if i + 1 >= raw.len {
                sb.deinit()
                return null
            }
            const e = raw[i + 1]
            const decoded: u8? = e match {
                'n' => Some(10u8)
                't' => Some(9u8)
                'r' => Some(13u8)
                '\\' => Some(92u8)
                '"' => Some(34u8)
                '\'' => Some(39u8)
                _ => null
            }
            if decoded.is_none() {
                sb.deinit()
                return null
            }
            sb.append_byte(decoded.unwrap())
            i = i + 2
        }
    }
    return Some(sb.to_string())
}

// A lone floating literal, possibly negated or parenthesized.
fn float_literal(body: CTok[]) CConst? {
    let i: usize = 0
    let j = body.len
    while i < j and body[i].is_punct("(") and body[j - 1].is_punct(")") {
        i = i + 1
        j = j - 1
    }
    let neg = false
    if i < j and body[i].is_punct("-") {
        neg = true
        i = i + 1
    }
    if j - i != 1 or body[i].kind != CTokKind.Number {
        return null
    }
    const text = body[i].text
    const is_hex = text.len > 1 and (text[1] == 'x' or text[1] == 'X')
    const looks_float = !is_hex and (text.find('.').is_some() or text.find('e').is_some()
        or text.find('E').is_some())
    if !looks_float {
        return null
    }
    let end = text.len
    const last = text[end - 1]
    const is_f32 = last == 'f' or last == 'F'
    if is_f32 or last == 'l' or last == 'L' {
        end = end - 1
    }
    const digits = text[0..end]
    if !is_decimal_float(digits) {
        return null
    }
    return Some(CConst.FloatConst(digits, neg, is_f32))
}

// Digits with a point or an exponent, the shape a FLang float literal can be written in.
fn is_decimal_float(s: String) bool {
    let i: usize = 0
    let digits = false
    while i < s.len and s[i] >= '0' and s[i] <= '9' {
        digits = true
        i = i + 1
    }
    if i < s.len and s[i] == '.' {
        i = i + 1
        while i < s.len and s[i] >= '0' and s[i] <= '9' {
            digits = true
            i = i + 1
        }
    }
    if !digits {
        return false
    }
    if i < s.len and (s[i] == 'e' or s[i] == 'E') {
        i = i + 1
        if i < s.len and (s[i] == '+' or s[i] == '-') {
            i = i + 1
        }
        const exp_start = i
        while i < s.len and s[i] >= '0' and s[i] <= '9' {
            i = i + 1
        }
        if i == exp_start {
            return false
        }
    }
    return i == s.len
}

fn parse_text(src: String) CModel {
    const lexed = lex_c(src)
    defer lexed.deinit()
    return parse_c(&lexed, Host { long_bits = 32, wchar_bits = 16 })
}

test "MSVC prototypes with calling conventions and declspecs" {
    const m = parse_text(
        "typedef struct SDL_Window SDL_Window;\nextern __declspec(dllimport) SDL_Window * __cdecl SDL_CreateWindow(const char *title, int w, int h, unsigned __int64 flags);\n",
    )
    defer m.deinit()
    assert_eq(m.funcs.len, 1 as usize, "one function")
    assert_eq(m.funcs[0].name, "SDL_CreateWindow", "name")
    const sig = m.sigs[m.funcs[0].sig as usize]
    assert_eq(sig.params.len, 4u32, "four parameters")
    assert_eq(m.param_at(sig.params, 3).name, "flags", "last parameter name")
    assert_eq(m.records[0].complete, false, "incomplete record")
}

test "function pointers, arrays and nested declarators" {
    const m = parse_text(
        "typedef void (__cdecl *Cb)(void *ud, int (*inner)(char));\nint grid[2][3];\nint (*pick(int k))[4];\n",
    )
    defer m.deinit()
    const cb = m.typedefs[0]
    assert_eq(cb.name, "Cb", "typedef name")
    const is_fn_ptr = m.ty(cb.ty) match {
        TPtr(inner) => m.ty(inner) match {
            TFunc(_) => true
            _ => false
        }
        _ => false
    }
    assert_eq(is_fn_ptr, true, "pointer to function")
    assert_eq(m.funcs.len, 1 as usize, "pick is a function")
    const ret = m.sigs[m.funcs[0].sig as usize].ret
    const ret_ok = m.ty(ret) match {
        TPtr(a) => m.ty(a) match {
            TArray(_, n) => n == 4
            _ => false
        }
        _ => false
    }
    assert_eq(ret_ok, true, "returns a pointer to an array of 4")
}

test "records, unions, bit-fields, enums and pack" {
    const m = parse_text(
        "#pragma pack(push, 1)\nstruct P { char a; int b; };\n#pragma pack(pop)\ntypedef union U { int i; float f; struct { short x; } s; } U;\nstruct B { unsigned a : 3; };\nenum E { A, B = 5, C, D = B << 1 };\n",
    )
    defer m.deinit()
    assert_eq(m.records[0].pack, 1u32, "packed struct")
    assert_eq(m.records[1].tag, "", "anonymous nested struct, completed before its parent")
    assert_eq(m.records[2].is_union, true, "union")
    assert_eq(m.records[2].fields.len, 3u32, "three members")
    assert_eq(m.fields[(m.records[3].fields.start) as usize].is_bitfield, true, "bit-field")
    assert_eq(m.enum_values.get("C").unwrap(), 6i64, "auto-increment")
    assert_eq(m.enum_values.get("D").unwrap(), 10i64, "constant expression")
}

test "inline bodies are skipped and unreadable declarations recorded" {
    const m = parse_text(
        "static __forceinline int twice(int x) { return x * 2; }\n__int128 big;\nint after(void);\n",
    )
    defer m.deinit()
    assert_eq(m.funcs.len, 1 as usize, "only the exported prototype")
    assert_eq(m.funcs[0].name, "after", "the declaration after the failures")
}

test "probes give typed constants" {
    const m = parse_text(
        "__flang_probe \"A\" 0x20u __flang_end\n__flang_probe \"S\" \"SDL.\" \"hint\" __flang_end\n__flang_probe \"P\" 3.5f __flang_end\n__flang_probe \"N\" __flang_end\n__flang_probe \"X\" foo __flang_end\n",
    )
    defer m.deinit()
    assert_eq(m.macros.len, 3 as usize, "empty and non-constant probes dropped")
    const a_ok = m.macros[0].value match {
        IntConst(v) => v.value == 32 and v.prim == Prim.UInt
        _ => false
    }
    assert_eq(a_ok, true, "unsigned int constant")
    assert_eq(m.strings[0].view(), "SDL.hint", "concatenated string")
}
