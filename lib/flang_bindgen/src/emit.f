// A FLang module from a C model: the raw binding layer.
//
// Only declarations from files inside the library's own directory are written; a system header
// contributes the types a library declaration reaches through it. The translation is faithful:
// every C pointer may be null, so it becomes `&T?`; a struct FLang cannot lay out the way C does is
// kept opaque, usable behind a pointer only; a declaration with no FLang spelling is left out and
// named in a warning.

import std.collections.dict
import std.collections.list
import std.collections.set
import std.option
import std.string
import std.string_builder
import std.test

import flang_bindgen.consteval
import flang_bindgen.lexer
import flang_bindgen.model

pub type BindgenConfig = struct {
    // How the generated file names the header it came from.
    header: String
    // The library's directory; declarations from files under it are the ones bound.
    root: String
    host: Host
    // Whether file paths compare case-insensitively, as on Windows.
    fold_case: bool
}

pub type Bindings = struct {
    source: OwnedString
    // The library headers the declarations came from, with forward slashes.
    files: List(OwnedString)
    warnings: List(OwnedString)
}

pub fn deinit(self: move Bindings) {
    self.source.deinit()
    self.files.deinit()
    self.warnings.deinit()
}

/// Write the binding module for the declarations in `m` that come from the library's own files.
pub fn emit_bindings(m: &CModel, files: &List(String), cfg: BindgenConfig) Bindings {
    let lib_files: List(OwnedString) = list(4)
    let warnings: List(OwnedString) = list(0)
    let e = Emitter {
        m = m,
        files = files,
        cfg = cfg,
        own = list(files.len),
        lib_files = &lib_files,
        rec_name = list(m.records.len),
        rec_state = list(m.records.len),
        rec_queued = list(m.records.len),
        td_state = list(m.typedefs.len),
        td_hidden = list(m.typedefs.len),
        pool = list(16),
        renamed = dict(),
        names = set(),
        out = string_builder(64 * 1024),
        warnings = &warnings,
        why = "",
        pending = list(16),
    }
    e.classify_files(files)
    e.name_records()
    e.write_header()
    e.write_decls()
    e.write_macros()
    e.drain_pending()
    const source = e.out.to_string()
    e.deinit()
    return Bindings { source = move source, files = move lib_files, warnings = move warnings }
}

const STATE_UNKNOWN: u8 = 0
const STATE_VISITING: u8 = 1
const STATE_OK: u8 = 2
const STATE_BAD: u8 = 3

type Emitter = struct {
    m: &CModel
    // Every file as its line marker spells it.
    files: &List(String)
    cfg: BindgenConfig
    // Per file index: whether it lies inside the library's directory.
    own: List(bool)
    lib_files: &List(OwnedString)
    // The FLang name of each record; empty until one is known.
    rec_name: List(String)
    // Whether a complete record can be written with C's layout.
    rec_state: List(u8)
    // Whether a record has been written or queued to be.
    rec_queued: List(bool)
    td_state: List(u8)
    // A typedef that only names a record of the same name, so writes nothing of its own.
    td_hidden: List(bool)
    // Names made up for anonymous records and capitalized C names.
    pool: List(OwnedString)
    renamed: Dict(String, String)
    // Every top-level name written, so a macro never redeclares one.
    names: Set(String)
    out: StringBuilder
    warnings: &List(OwnedString)
    // Why the last spelling attempt failed.
    why: String
    pending: List(u32)
}

fn deinit(self: move Emitter) {
    self.out.deinit()
    self.own.deinit()
    self.rec_name.deinit()
    self.rec_state.deinit()
    self.rec_queued.deinit()
    self.td_state.deinit()
    self.td_hidden.deinit()
    self.pool.deinit()
    self.renamed.deinit()
    self.names.deinit()
    self.pending.deinit()
}

// ---- Files ----

fn classify_files(self: &Emitter, files: &List(String)) {
    const root = normalize_path(self.cfg.root, self.cfg.fold_case, true)
    defer root.deinit()
    let seen: Set(OwnedString) = set()
    defer seen.deinit()
    for f in files.as_slice() {
        const key = normalize_path(f, self.cfg.fold_case, false)
        const inside = key.view().len > 0 and key.view().starts_with(root.view())
        self.own.push(inside)
        if inside and seen.add(key.view()) {
            self.lib_files.push(normalize_path(f, false, false))
        }
        key.deinit()
    }
}

/// A path as a line marker spells it, with escapes undone and forward slashes; `dir` adds a
/// trailing slash.
pub fn normalize_path(raw: String, fold_case: bool, dir: bool) OwnedString {
    let sb = string_builder(raw.len + 1)
    let i: usize = 0
    while i < raw.len {
        let c = raw[i]
        if c == '\\' and i + 1 < raw.len and raw[i + 1] == '\\' {
            i = i + 1
        }
        if c == '\\' {
            c = '/' as u8
        }
        if fold_case and c >= 'A' and c <= 'Z' {
            c = c + 32
        }
        const doubled = c == '/' and sb.as_view().len > 0
            and sb.as_view()[sb.as_view().len - 1] == '/'
        if !doubled {
            sb.append_byte(c)
        }
        i = i + 1
    }
    if dir and sb.as_view().len > 0 and sb.as_view()[sb.as_view().len - 1] != '/' {
        sb.append_byte('/' as u8)
    }
    return sb.to_string()
}

fn is_own(self: &Emitter, file: u32) bool {
    return (file as usize) < self.own.len and self.own[file as usize]
}

// ---- Names ----

// A record is named by its tag, or by the typedef that names it: an anonymous `typedef struct {}`
// takes the typedef's name, and so does an incomplete one, whose typedef is how C code spells the
// handle.
fn name_records(self: &Emitter) {
    for r in 0..self.m.records.len {
        self.rec_name.push(self.m.records[r].tag)
        self.rec_state.push(STATE_UNKNOWN)
        self.rec_queued.push(false)
    }
    for i in 0..self.m.typedefs.len {
        self.td_state.push(STATE_UNKNOWN)
        const td = self.m.typedefs[i]
        let hidden = false
        self.m.ty(td.ty) match {
            TRecord(r) => {
                const rec = self.m.records[r as usize]
                const takes_name = rec.tag.len == 0 or !rec.complete
                const named = self.rec_name[r as usize]
                const already_renamed = named.len > 0 and named != rec.tag
                if takes_name and !already_renamed {
                    self.rec_name[r as usize] = td.name
                }
                hidden = self.rec_name[r as usize] == td.name
            }
            _ => {}
        }
        self.td_hidden.push(hidden)
    }
}

fn synth_name(self: &Emitter, outer: String, field: String) String {
    let sb = string_builder(outer.len + field.len + 1)
    sb.append(outer)
    sb.append("_")
    sb.append(field)
    self.pool.push(sb.to_string())
    return self.pool[self.pool.len - 1].view()
}

/// A C identifier that FLang reserves, with `_` appended.
pub fn safe_ident(name: String, sb: &StringBuilder) {
    sb.append(name)
    if is_flang_keyword(name) {
        sb.append("_")
    }
}

fn is_flang_keyword(w: String) bool {
    return w match {
        "pub" | "fn" | "return" | "let" | "const" | "if" | "else" | "for" | "loop" | "while" | "in"
            | "break" | "continue" | "defer" | "move" | "import" | "struct" | "enum" | "contract"
            | "context" | "match" | "as" | "test" | "type" | "and" | "or" | "true" | "false"
            | "null" | "_" | "Self" => true
        _ => false
    }
}

// The FLang name of a C type. FLang types are capitalized, so `rAudioBuffer` becomes `RAudioBuffer`
// and `_XDisplay` becomes `XDisplay`. C never sees the name: an aggregate crossing the boundary is
// emitted under a name the compiler derives, so the rename changes nothing on the C side.
fn type_name(self: &Emitter, cname: String) String {
    if cname.len == 0 or (cname[0] >= 'A' and cname[0] <= 'Z') {
        return cname
    }
    const memo = self.renamed.get(cname)
    if memo.is_some() {
        return memo.unwrap()
    }
    let i: usize = 0
    while i < cname.len and cname[i] == '_' {
        i = i + 1
    }
    if i == cname.len {
        return ""
    }
    let sb = string_builder(cname.len)
    const c = cname[i]
    sb.append_byte(if c >= 'a' and c <= 'z' { c - 32 } else { c })
    sb.append(cname[i + 1..cname.len])
    self.pool.push(sb.to_string())
    const name = self.pool[self.pool.len - 1].view()
    self.renamed.set(cname, name)
    return name
}

// ---- Spelling types ----

fn bad(self: &Emitter, why: String) bool {
    self.why = why
    return false
}

fn prim_name(self: &Emitter, p: Prim) String? {
    const wide_long = self.cfg.host.long_bits == 64
    return p match {
        Bool => Some("bool")
        Char | UChar => Some("u8")
        SChar => Some("i8")
        Short => Some("i16")
        UShort => Some("u16")
        Int => Some("i32")
        UInt => Some("u32")
        Long => Some(if wide_long { "i64" } else { "i32" })
        ULong => Some(if wide_long { "u64" } else { "u32" })
        LongLong => Some("i64")
        ULongLong => Some("u64")
        Float => Some("f32")
        Double => Some("f64")
        LongDouble => null
    }
}

// Standard typedefs keep the FLang type they mean, not the width a system header happens to give.
fn builtin_typedef(self: &Emitter, name: String) String? {
    return name match {
        "int8_t" => Some("i8")
        "uint8_t" => Some("u8")
        "int16_t" => Some("i16")
        "uint16_t" => Some("u16")
        "int32_t" => Some("i32")
        "uint32_t" => Some("u32")
        "int64_t" => Some("i64")
        "uint64_t" => Some("u64")
        "size_t" | "uintptr_t" => Some("usize")
        "ssize_t" | "ptrdiff_t" | "intptr_t" => Some("isize")
        "char16_t" => Some("u16")
        "char32_t" => Some("u32")
        "wchar_t" => Some(if self.cfg.host.wchar_bits == 16 { "u16" } else { "i32" })
        _ => null
    }
}

fn enum_int(self: &Emitter, e: u32) String {
    const en = self.m.enums[e as usize]
    for k in 0..en.consts.len {
        if self.m.const_at(en.consts, k).value > 0x7FFFFFFF {
            return "u32"
        }
    }
    return "i32"
}

// Write the FLang spelling of `t` as a value type. False, with `why` set, when there is none.
fn spell(self: &Emitter, t: TyId, sb: &StringBuilder) bool {
    return self.m.ty(t) match {
        TVoid => self.bad("`void` as a value")
        TPrim(p) => self.prim_name(p) match {
            Some(n) => {
                sb.append(n)
                true
            }
            None => self.bad("`long double`")
        }
        TNamed(n) => self.spell_named(n, sb)
        TRecord(r) => self.spell_record_value(r, sb)
        TEnum(e) => {
            sb.append(self.enum_int(e))
            true
        }
        TPtr(p) => self.spell_pointer(p, sb)
        TArray(elem, len) => {
            if len <= 0 {
                return self.bad("an array of unknown or zero length")
            }
            sb.append("[")
            if !self.spell(elem, sb) {
                return false
            }
            sb.append("; ")
            sb.append(len)
            sb.append("]")
            true
        }
        TFunc(_) => self.bad("a function type used as a value")
        TBad(why) => self.bad(why)
    }
}

fn spell_named(self: &Emitter, n: String, sb: &StringBuilder) bool {
    if n == "va_list" or n == "__builtin_va_list" or n == "__gnuc_va_list" {
        return self.bad("`va_list`")
    }
    const builtin = self.builtin_typedef(n)
    if builtin.is_some() {
        sb.append(builtin.unwrap())
        return true
    }
    const id = self.m.typedef_ids.get(n)
    if id.is_none() {
        return self.bad("an undeclared type name")
    }
    const i = id.unwrap()
    const td = self.m.typedefs[i as usize]
    if !self.is_own(td.file) or self.td_hidden[i as usize] {
        return self.spell(td.ty, sb)
    }
    if !self.typedef_ok(i) {
        return false
    }
    sb.append(self.type_name(n))
    return true
}

fn spell_record_value(self: &Emitter, r: u32, sb: &StringBuilder) bool {
    const rec = self.m.records[r as usize]
    if !rec.complete or !self.record_ok(r) {
        return self.bad("an opaque struct passed by value")
    }
    const name = self.type_name(self.record_name(r))
    if name.len == 0 {
        return self.bad("an unnamed struct")
    }
    self.queue_record(r)
    sb.append(name)
    return true
}

fn record_name(self: &Emitter, r: u32) String {
    return self.rec_name[r as usize]
}

fn queue_record(self: &Emitter, r: u32) {
    if self.rec_queued[r as usize] {
        return
    }
    self.rec_queued[r as usize] = true
    self.pending.push(r)
}

// `&T?` for a pointer to `T`; a pointer to a function is the `#foreign fn` code pointer itself.
fn spell_pointer(self: &Emitter, p: TyId, sb: &StringBuilder) bool {
    const pointee = self.resolve_shallow(p)
    self.m.ty(pointee) match {
        TVoid => {
            sb.append("&u8?")
            return true
        }
        TFunc(s) => return self.spell_fn_type(s, sb)
        TRecord(r) => {
            const name = self.type_name(self.record_name(r))
            if name.len == 0 {
                return self.bad("a pointer to an unnamed struct")
            }
            self.queue_record(r)
            sb.append("&")
            sb.append(name)
            sb.append("?")
            return true
        }
        _ => {}
    }
    let inner = string_builder(32)
    defer inner.deinit()
    if !self.spell(p, &inner) {
        return false
    }
    const s = inner.as_view()
    sb.append("&")
    const needs_parens = s.starts_with("&") or s.starts_with("#")
    if needs_parens {
        sb.append("(")
    }
    sb.append(s)
    if needs_parens {
        sb.append(")")
    }
    sb.append("?")
    return true
}

// Through typedefs from system headers and typedefs that only name a record or function, to the
// type a pointer's pointee decides on.
fn resolve_shallow(self: &Emitter, t: TyId) TyId {
    return self.m.ty(t) match {
        TNamed(n) => {
            if self.builtin_typedef(n).is_some() {
                return t
            }
            self.m.typedef_ids.get(n) match {
                Some(i) => {
                    const target = self.m.typedefs[i as usize].ty
                    const r = self.resolve_shallow(target)
                    self.m.ty(r) match {
                        TVoid => r
                        TFunc(_) => r
                        TRecord(_) => r
                        _ => t
                    }
                }
                None => t
            }
        }
        _ => t
    }
}

fn spell_fn_type(self: &Emitter, s: u32, sb: &StringBuilder) bool {
    const sig = self.m.sigs[s as usize]
    if sig.variadic {
        return self.bad("a variadic callback")
    }
    sb.append("#foreign fn(")
    for k in 0..sig.params.len {
        if k > 0 {
            sb.append(", ")
        }
        if !self.spell(self.m.param_at(sig.params, k).ty, sb) {
            return false
        }
    }
    sb.append(")")
    return self.spell_ret(sig.ret, sb)
}

// A return type, with a leading space; nothing for `void`.
fn spell_ret(self: &Emitter, t: TyId, sb: &StringBuilder) bool {
    const r = self.resolve_shallow(t)
    const is_void = self.m.ty(r) match {
        TVoid => true
        _ => false
    }
    if is_void {
        return true
    }
    sb.append(" ")
    return self.spell(t, sb)
}

fn typedef_ok(self: &Emitter, i: u32) bool {
    const st = self.td_state[i as usize]
    if st == STATE_OK or st == STATE_VISITING {
        return true
    }
    if st == STATE_BAD {
        return self.bad("a skipped typedef")
    }
    self.td_state[i as usize] = STATE_VISITING
    let scratch = string_builder(64)
    defer scratch.deinit()
    const ok = self.spell_typedef_target(self.m.typedefs[i as usize].ty, &scratch)
    self.td_state[i as usize] = if ok { STATE_OK } else { STATE_BAD }
    return ok
}

fn spell_typedef_target(self: &Emitter, t: TyId, sb: &StringBuilder) bool {
    const r = self.resolve_shallow(t)
    return self.m.ty(r) match {
        TFunc(_) => self.bad("a function type")
        TVoid => self.bad("`void`")
        _ => self.spell(t, sb)
    }
}

// Whether a complete record can be written as a `#foreign` struct or union that C lays out the
// same.
fn record_ok(self: &Emitter, r: u32) bool {
    const st = self.rec_state[r as usize]
    if st == STATE_OK or st == STATE_VISITING {
        return true
    }
    if st == STATE_BAD {
        return self.bad("a struct kept opaque")
    }
    self.rec_state[r as usize] = STATE_VISITING
    const ok = self.check_record(r)
    self.rec_state[r as usize] = if ok { STATE_OK } else { STATE_BAD }
    return ok
}

fn check_record(self: &Emitter, r: u32) bool {
    const rec = self.m.records[r as usize]
    if rec.pack > 0 and rec.pack < 8 {
        return self.bad("a packed struct")
    }
    if rec.fields.len == 0 {
        return self.bad("an empty struct")
    }
    let scratch = string_builder(64)
    defer scratch.deinit()
    for k in 0..rec.fields.len {
        const f = self.m.field_at(rec.fields, k)
        if f.is_bitfield {
            return self.bad("bit-fields")
        }
        if self.is_trailing_flexible(rec, k) {
            continue
        }
        if !self.spell_field(r, f, &scratch) {
            return false
        }
    }
    return true
}

// A flexible array member (`T data[];`) ends a struct and adds nothing to its size.
fn is_trailing_flexible(self: &Emitter, rec: CRecord, k: u32) bool {
    if k + 1 != rec.fields.len {
        return false
    }
    return self.m.ty(self.m.field_at(rec.fields, k).ty) match {
        TArray(_, len) => len <= 0
        _ => false
    }
}

fn spell_field(self: &Emitter, r: u32, f: CField, sb: &StringBuilder) bool {
    const anon = self.m.ty(f.ty) match {
        TRecord(inner) => if self.m.records[inner as usize].tag.len == 0 { Some(
            inner,
        ) } else { null }
        _ => null
    }
    if anon.is_some() {
        const inner = anon.unwrap()
        if self.rec_name[inner as usize].len == 0 {
            const outer = self.record_name(r)
            const field = if f.name.len > 0 { f.name } else { "anon" }
            self.rec_name[inner as usize] = self.synth_name(outer, field)
        }
    }
    return self.spell(f.ty, sb)
}

// ---- Writing ----

fn warn(self: &Emitter, file: u32, line: u32, what: String, name: String) {
    const path = normalize_path(self.file_label(file), false, false)
    defer path.deinit()
    self.warnings.push($"{path.view()}:{line}: skipped {what} `{name}`: {self.why}")
}

fn file_label(self: &Emitter, file: u32) String {
    if (file as usize) < self.files.len {
        return self.files[file as usize]
    }
    return self.cfg.header
}

fn write_header(self: &Emitter) {
    self.out.append("// Generated by flang from ")
    self.out.append(self.cfg.header)
    self.out.append(". Do not edit: `flang build` rewrites it when the header changes.\n")
}

fn write_decls(self: &Emitter) {
    for d in self.m.decls.as_slice() {
        d match {
            DRecord(r) => {
                const named = self.rec_name[r as usize].len > 0
                if named and self.is_own(self.m.records[r as usize].file) {
                    self.queue_record(r)
                }
            }
            DEnum(e) => self.write_enum(e)
            DTypedef(i) => self.write_typedef(i)
            DFunc(f) => self.write_func(f)
        }
    }
    self.drain_pending()
    for &err in self.m.errors {
        if self.is_own(err.file) {
            self.why = err.message.view()
            self.warn(err.file, err.line, "declaration", "?")
        }
    }
}

fn drain_pending(self: &Emitter) {
    let i: usize = 0
    while i < self.pending.len {
        self.write_record(self.pending[i])
        i = i + 1
    }
    self.pending.clear()
}

fn write_record(self: &Emitter, r: u32) {
    const rec = self.m.records[r as usize]
    const name = self.type_name(self.record_name(r))
    if name.len == 0 {
        self.rec_queued[r as usize] = false
        return
    }
    if !self.names.add(name) {
        return
    }
    if !rec.complete {
        self.out.append($"\npub type {name} = #foreign struct {{}}\n")
        return
    }
    if !self.record_ok(r) {
        if self.is_own(rec.file) {
            const path = normalize_path(self.file_label(rec.file), false, false)
            self.warnings.push(
                $"{path.view()}:{rec.line}: `{name}` has {self.why}; it is opaque, usable behind a pointer only",
            )
            path.deinit()
        }
        self.out.append($"\npub type {name} = #foreign struct {{}}\n")
        return
    }
    let body = string_builder(256)
    defer body.deinit()
    body.append("\npub type ")
    body.append(name)
    body.append(if rec.is_union { " = #foreign union {\n" } else { " = #foreign struct {\n" })
    let unnamed: u32 = 0
    for k in 0..rec.fields.len {
        const f = self.m.field_at(rec.fields, k)
        if self.is_trailing_flexible(rec, k) {
            continue
        }
        body.append("    ")
        if f.name.len > 0 {
            safe_ident(f.name, &body)
        } else {
            body.append("anon")
            body.append(unnamed)
            unnamed = unnamed + 1
        }
        body.append(": ")
        self.spell_field(r, f, &body)
        body.append("\n")
    }
    body.append("}\n")
    self.out.append(body.as_view())
}

fn write_enum(self: &Emitter, e: u32) {
    const en = self.m.enums[e as usize]
    if !self.is_own(en.file) {
        return
    }
    const int_ty = self.enum_int(e)
    self.out.append("\n")
    for k in 0..en.consts.len {
        const c = self.m.const_at(en.consts, k)
        if !self.names.add(c.name) {
            continue
        }
        self.out.append($"pub const {c.name}: {int_ty} = {c.value}\n")
    }
}

fn write_typedef(self: &Emitter, i: u32) {
    const td = self.m.typedefs[i as usize]
    if !self.is_own(td.file) or self.td_hidden[i as usize] {
        return
    }
    const name = self.type_name(td.name)
    let sb = string_builder(64)
    defer sb.deinit()
    if !self.typedef_ok(i) or !self.spell_typedef_target(td.ty, &sb) {
        return
    }
    if name.len == 0 or !self.names.add(name) {
        return
    }
    self.out.append($"\npub type {name} = {sb.as_view()}\n")
}

fn write_func(self: &Emitter, f: u32) {
    const fun = self.m.funcs[f as usize]
    if !self.is_own(fun.file) or self.names.contains(fun.name) {
        return
    }
    const sig = self.m.sigs[fun.sig as usize]
    if sig.variadic {
        self.why = "variadic functions have no FLang spelling"
        self.warn(fun.file, fun.line, "function", fun.name)
        return
    }
    let sb = string_builder(128)
    defer sb.deinit()
    sb.append("#foreign pub fn ")
    sb.append(fun.name)
    sb.append("(")
    for k in 0..sig.params.len {
        const prm = self.m.param_at(sig.params, k)
        if k > 0 {
            sb.append(", ")
        }
        if prm.name.len > 0 {
            safe_ident(prm.name, &sb)
        } else {
            sb.append("p")
            sb.append(k)
        }
        sb.append(": ")
        if !self.spell(prm.ty, &sb) {
            self.warn(fun.file, fun.line, "function", fun.name)
            return
        }
    }
    sb.append(")")
    if !self.spell_ret(sig.ret, &sb) {
        self.warn(fun.file, fun.line, "function", fun.name)
        return
    }
    self.names.add(fun.name)
    self.out.append(sb.as_view())
    self.out.append("\n")
}

fn write_macros(self: &Emitter) {
    if self.m.macros.len == 0 {
        return
    }
    self.out.append("\n")
    for mac in self.m.macros.as_slice() {
        if self.names.contains(mac.name) or is_flang_keyword(mac.name) {
            continue
        }
        const line = mac.value match {
            IntConst(v) => self.int_const(mac.name, v)
            FloatConst(text, neg, is_f32) => float_const(mac.name, text, neg, is_f32)
            StrConst(i) => str_const(mac.name, self.m.strings[i as usize].view())
        }
        if line.is_some() {
            self.names.add(mac.name)
            const text = line.unwrap()
            self.out.append(text.view())
            text.deinit()
        }
    }
}

fn int_const(self: &Emitter, name: String, v: CInt) OwnedString? {
    const ty = self.prim_name(v.prim)
    if ty.is_none() or v.prim == Prim.Bool {
        return null
    }
    if is_unsigned(v.prim) {
        return Some($"pub const {name}: {ty.unwrap()} = {v.value as u64}\n")
    }
    return Some($"pub const {name}: {ty.unwrap()} = {v.value}\n")
}

// A float constant from its C literal: FLang wants a digit on each side of the point.
fn float_const(name: String, text: String, neg: bool, is_f32: bool) OwnedString? {
    let sb = string_builder(48)
    sb.append("pub const ")
    sb.append(name)
    sb.append(if is_f32 { ": f32 = " } else { ": f64 = " })
    if neg {
        sb.append("-")
    }
    if text[0] == '.' {
        sb.append("0")
    }
    let i: usize = 0
    let point = false
    while i < text.len {
        const c = text[i]
        if c == 'e' or c == 'E' {
            break
        }
        if c == '.' {
            point = true
        }
        sb.append_byte(c)
        i = i + 1
    }
    if !point {
        sb.append(".0")
    } else if text[i - 1] == '.' {
        sb.append("0")
    }
    sb.append(text[i..text.len])
    sb.append("\n")
    return Some(sb.to_string())
}

// A string constant, when every byte has a FLang literal spelling.
fn str_const(name: String, s: String) OwnedString? {
    let sb = string_builder(s.len + 32)
    sb.append("pub const ")
    sb.append(name)
    sb.append(" = \"")
    for i in 0..s.len {
        const c = s[i]
        if c == '"' or c == '\\' {
            sb.append_byte('\\' as u8)
            sb.append_byte(c)
        } else if c == 10u8 {
            sb.append("\\n")
        } else if c == 9u8 {
            sb.append("\\t")
        } else if c == 13u8 {
            sb.append("\\r")
        } else if c < 32u8 or c == 127u8 {
            sb.deinit()
            return null
        } else {
            sb.append_byte(c)
        }
    }
    sb.append("\"\n")
    return Some(sb.to_string())
}
