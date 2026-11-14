// What a header declares, read off its preprocessed text.
//
// Types live in one arena and refer to each other by index, so a recursive C type (a pointer to a
// function taking a pointer to the same struct) needs no ownership cycle. Fields, parameters and
// enum constants are kept in shared lists; each record, signature and enum holds the range that
// belongs to it, which keeps every declaration a plain copyable value.

import std.collections.dict
import std.collections.list
import std.string

pub type TyId = u32

// The C data model of the machine the header was preprocessed for.
pub type Host = struct {
    // 32 on Windows (LLP64), 64 on LP64 systems.
    long_bits: u32
    // 16 on Windows, 32 elsewhere.
    wchar_bits: u32
}

pub type Prim = enum {
    Bool
    Char
    SChar
    UChar
    Short
    UShort
    Int
    UInt
    Long
    ULong
    LongLong
    ULongLong
    Float
    Double
    LongDouble
}

pub type CTy = enum {
    TVoid
    TPrim(Prim)
    // A typedef name, resolved when the binding is written.
    TNamed(String)
    TRecord(u32)
    TEnum(u32)
    TPtr(TyId)
    // Element and length; a length of -1 is an array of unknown bound.
    TArray(TyId, i64)
    TFunc(u32)
    // A type FLang has no spelling for; the text says which.
    TBad(String)
}

pub type CRange = struct {
    start: u32
    len: u32
}

pub type CField = struct {
    // Empty for an unnamed member (a C11 anonymous struct or union).
    name: String
    ty: TyId
    is_bitfield: bool
}

pub type CRecord = struct {
    // Empty for an anonymous record.
    tag: String
    is_union: bool
    complete: bool
    fields: CRange
    // The `#pragma pack` in force at the definition, 0 when none is.
    pack: u32
    file: u32
    line: u32
}

pub type CEnumConst = struct {
    name: String
    value: i64
}

pub type CEnum = struct {
    tag: String
    consts: CRange
    file: u32
}

pub type CParam = struct {
    // Empty when the prototype leaves it unnamed.
    name: String
    ty: TyId
}

pub type CSig = struct {
    params: CRange
    ret: TyId
    variadic: bool
}

pub type CTypedef = struct {
    name: String
    ty: TyId
    file: u32
}

pub type CFunc = struct {
    name: String
    sig: u32
    file: u32
    line: u32
}

// An integer constant with the C type it carries.
pub type CInt = struct {
    value: i64
    prim: Prim
}

pub type CConst = enum {
    IntConst(CInt)
    // The literal as written without its suffix, whether it is negated, and whether it was suffixed
    // `f`.
    FloatConst(String, bool, bool)
    // Index into `CModel.strings`.
    StrConst(u32)
}

pub type CMacro = struct {
    name: String
    value: CConst
}

pub type CDecl = enum {
    DRecord(u32)
    DEnum(u32)
    DTypedef(u32)
    DFunc(u32)
}

pub type CError = struct {
    file: u32
    line: u32
    message: OwnedString
}

pub fn deinit(self: move CError) {
    self.message.deinit()
}

pub type CModel = struct {
    tys: List(CTy)
    records: List(CRecord)
    enums: List(CEnum)
    sigs: List(CSig)
    typedefs: List(CTypedef)
    funcs: List(CFunc)
    fields: List(CField)
    params: List(CParam)
    consts: List(CEnumConst)
    macros: List(CMacro)
    strings: List(OwnedString)
    // Declarations in source order.
    decls: List(CDecl)
    typedef_ids: Dict(String, u32)
    // C has one tag namespace for structs, unions and enums.
    tag_ids: Dict(String, CDecl)
    enum_values: Dict(String, i64)
    // Declarations that could not be read, from any file.
    errors: List(CError)
}

pub fn c_model() CModel {
    return CModel {
        tys = list(1024),
        records = list(64),
        enums = list(64),
        sigs = list(256),
        typedefs = list(256),
        funcs = list(256),
        fields = list(512),
        params = list(512),
        consts = list(512),
        macros = list(64),
        strings = list(16),
        decls = list(512),
        typedef_ids = dict(),
        tag_ids = dict(),
        enum_values = dict(),
        errors = list(0),
    }
}

pub fn deinit(self: move CModel) {
    self.tys.deinit()
    self.records.deinit()
    self.enums.deinit()
    self.sigs.deinit()
    self.typedefs.deinit()
    self.funcs.deinit()
    self.fields.deinit()
    self.params.deinit()
    self.consts.deinit()
    self.macros.deinit()
    self.strings.deinit()
    self.decls.deinit()
    self.typedef_ids.deinit()
    self.tag_ids.deinit()
    self.enum_values.deinit()
    self.errors.deinit()
}

pub fn add_ty(self: &CModel, t: CTy) TyId {
    self.tys.push(t)
    return (self.tys.len - 1) as TyId
}

pub fn ty(self: &CModel, id: TyId) CTy {
    return self.tys[id as usize]
}

pub fn field_at(self: &CModel, r: CRange, i: u32) CField {
    return self.fields[(r.start + i) as usize]
}

pub fn param_at(self: &CModel, r: CRange, i: u32) CParam {
    return self.params[(r.start + i) as usize]
}

pub fn const_at(self: &CModel, r: CRange, i: u32) CEnumConst {
    return self.consts[(r.start + i) as usize]
}
