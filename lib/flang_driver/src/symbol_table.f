// Symbols and callable signatures: which functions lowering can emit and
// call, and the C symbol each one gets.
//
// `SymbolBuilder` walks every registered function scheme once, up front,
// and admits only the lowerable ones - membership in the finished
// `SymbolTable` IS the "is this callable?" gate `lower.f` reads. Symbol
// names are a pure function of the declaration (module path + name +
// parameter types; docs/spec.md 7.1.1, docs/adr/0004), so inserting a
// function cannot rename another.

import std.allocator
import std.dict
import std.list
import std.option
import std.string
import std.string_builder
import std.test
import flang_parser.ast
import flang_typer.type
import flang_typer.node_id
import flang_typer.result
import flang_typer.nominal_registry
import flang_typer.function_registry
import flang_typer.scheme
import flang_typer.specialization
import flang_driver.driver
import flang_driver.layout

// Symbol table
//
// Definitions and call sites have to agree on every emitted C symbol. The
// merged program puts all modules in one translation unit, so a name is
// unique only after module-path mangling plus an ordinal for same-name
// overloads - and an ordinal handed out while walking definitions is not
// something a call site can re-derive. So symbols are assigned once, up
// front, and both sides read the same table.
//
// Call sites key by `FunctionScheme.id` - the id the checker records on
// each resolved call node as `RtFunction`. Definitions key by the decl's
// span fingerprint, which is how a `FunctionDecl` finds its own id.
//
// Membership is also the "is this callable?" gate: a function whose
// signature this milestone cannot lower is left out, so a call to it
// falls back to a placeholder rather than naming a symbol the module
// never defines - which would fail to link.
pub type SymbolTable = struct {
    // Symbol strings are OWNED by the table - lookups hand out views.
    // The IrModule's function names borrow them, so the table must
    // outlive the module (see the note in lower_program).
    by_fn_id: Dict(u32, OwnedString)
    by_decl: Dict(NodeId, u32)
    by_fn_sig: Dict(u32, FnSig)
    // Specializations (M10), keyed by `Specialization.id` - the id
    // `RtSpecialized` / `ResolvedOperator.spec_id` carry. Symbols are
    // mangled from the CONCRETE parameter types plus a return suffix
    // (a return-only-polymorphic template's instantiations share every
    // parameter token, and the suffix also keeps a specialization from
    // colliding with a same-signature monomorphic overload).
    by_spec_id: Dict(u32, OwnedString)
    by_spec_sig: Dict(u32, FnSig)
}

// The declared signature lowering works from: the checker's parameter and
// return types for one registered function. Both alias the scheme's
// storage inside `TypeCheckResult`, which outlives lowering - nothing
// here is owned.
pub type FnSig = struct {
    params: List(Ty)
    ret: Ty
}

pub fn lookup_symbol(self: &SymbolTable, fn_id: u32) String? {
    return self.by_fn_id.get(fn_id) match {
        Some(s) => Some(s.as_view()),
        None => null,
    }
}

// The registry id of the function this declaration declares.
pub fn decl_fn_id(self: &SymbolTable, decl: &FunctionDecl) u32? {
    return self.by_decl.get(node_id_of(decl.span))
}

// The declared signature of a registered lowerable function.
pub fn sig_of(self: &SymbolTable, fn_id: u32) FnSig? {
    return self.by_fn_sig.get(fn_id)
}

pub fn spec_symbol(self: &SymbolTable, spec_id: u32) String? {
    return self.by_spec_id.get(spec_id) match {
        Some(s) => Some(s.as_view()),
        None => null,
    }
}

pub fn spec_sig(self: &SymbolTable, spec_id: u32) FnSig? {
    return self.by_spec_sig.get(spec_id)
}

pub fn deinit(self: &SymbolTable) {
    self.by_fn_id.deinit()
    self.by_decl.deinit()
    self.by_fn_sig.deinit()
    self.by_spec_id.deinit()
    self.by_spec_sig.deinit()
}

// Assigns symbols across a whole program. `seen` carries the ordinal
// counter across modules, so the walk order fixes the ordinals - which is
// why symbols are assigned before any body lowers, not during.
// The tables are held flat rather than as a nested `SymbolTable`:
// mutating a dict two field-hops deep through a reference does not stick.
pub type SymbolBuilder = struct {
    by_fn_id: Dict(u32, OwnedString)
    by_decl: Dict(NodeId, u32)
    by_fn_sig: Dict(u32, FnSig)
    by_spec_id: Dict(u32, OwnedString)
    by_spec_sig: Dict(u32, FnSig)
    nominals: &NominalRegistry
    allocator: &Allocator?
}

// Index every lowerable scheme by its declaration span and registry id up
// front; the per-module walk then maps each decl to its symbol with one
// lookup. A scheme outside the lowerable subset is left out entirely -
// membership in these tables IS the "is this callable?" gate.
pub fn symbol_builder(result: &TypeCheckResult, allocator: &Allocator? = null) SymbolBuilder {
    let by_fn_id: Dict(u32, OwnedString) = dict(allocator)
    let by_decl: Dict(NodeId, u32) = dict(allocator)
    let by_fn_sig: Dict(u32, FnSig) = dict(allocator)
    for entry in result.functions.by_name {
        // Annotated: the self-hosted checker types for-over-iterator
        // variables as unconstrained vars (protocol resolution is
        // post-M10), so `entry.value` needs the pin.
        let overloads: List(FunctionScheme) = entry.value
        for i in 0..overloads.len {
            let f = &overloads[i]
            // Variadic functions are declared (the backend still emits
            // their extern) but not called - the variadic portion needs
            // per-argument types the call site doesn't carry yet.
            if f.has_variadic { continue }
            let sig = scheme_sig(&f.signature)
            if sig.is_none() { continue }
            let s = sig.unwrap()
            if !sig_lowerable(&s, f.is_foreign) { continue }
            by_decl.set(node_id_of(f.decl_span), f.id)
            by_fn_sig.set(f.id, s)
        }
    }

    // Specializations (M10): concrete by construction, so the callable
    // gate only filters the shapes lowering cannot represent yet.
    let by_spec_id: Dict(u32, OwnedString) = dict(allocator)
    let by_spec_sig: Dict(u32, FnSig) = dict(allocator)
    for i in 0..result.specializations.len {
        let sp = &result.specializations[i]
        let s = FnSig { params = sp.concrete_params, ret = sp.concrete_return }
        if !sig_lowerable(&s, false) { continue }
        let sym = mangle_spec_symbol(sp.module, sp.name, &s, &result.nominals, allocator)
        by_spec_id.set(sp.id, sym)
        by_spec_sig.set(sp.id, s)
    }

    return .{
        by_fn_id = by_fn_id,
        by_decl = by_decl,
        by_fn_sig = by_fn_sig,
        by_spec_id = by_spec_id,
        by_spec_sig = by_spec_sig,
        nominals = &result.nominals,
        allocator = allocator,
    }
}

// The declared signature of a function scheme. Null when the scheme's
// body isn't a function type (nothing callable to encode).
fn scheme_sig(s: &Scheme) FnSig? {
    return s.body match {
        Func(ft) => Some(FnSig { params = ft.params, ret = ft.ret.* }),
        _ => null,
    }
}

// Whether a call to a function with this signature can be lowered: every
// parameter and the return type must be a FIR scalar or a concrete
// aggregate. Foreign signatures stay scalar-only - a byte-buffer
// aggregate has no C ABI spelling the backend could give an extern.
fn sig_lowerable(sig: &FnSig, is_foreign: bool) bool {
    for i in 0..sig.params.len {
        if !ty_lowerable(&sig.params[i], is_foreign) { return false }
    }
    return sig.ret match {
        Void => true,
        Never => true,
        _ => ty_lowerable(&sig.ret, is_foreign),
    }
}

// Whether a value of this type can cross a lowered call boundary. Scalars
// always can; aggregates only when concrete - a type variable inside one
// would make `layout_of` guess a size, which is the M5 wrong-layout bug
// class - and not foreign.
fn ty_lowerable(ty: &Ty, is_foreign: bool) bool {
    if is_scalar_ty(ty) { return true }
    if !is_aggregate(ty) { return false }
    if is_foreign { return false }
    return ty_concrete(ty)
}

fn is_scalar_ty(ty: &Ty) bool {
    return ty.* match {
        Prim(_) => true,
        Ref(_) => true,
        Func(_) => true,
        _ => false,
    }
}

// No unresolved type variable reachable by value. Recursion stops at
// `Ref` and `Func` (pointers are opaque - `&List($T)` is 8 bytes whatever
// `T` is), mirroring `layout_rec`.
fn ty_concrete(ty: &Ty) bool {
    return ty.* match {
        Var(_) => false,
        Error => false,
        Array(a) => ty_concrete(a.elem),
        Tuple(elems) => all_concrete(&elems),
        Record(fields) => record_concrete(&fields),
        Nominal(nr) => all_concrete(&nr.args),
        _ => true,
    }
}

fn all_concrete(tys: &List(Ty)) bool {
    for i in 0..tys.len {
        if !ty_concrete(&tys[i]) { return false }
    }
    return true
}

fn record_concrete(fields: &List(Field)) bool {
    for i in 0..fields.len {
        if !ty_concrete(&fields[i].ty) { return false }
    }
    return true
}

// Record a symbol for each of `ast_module`'s callable functions.
pub fn add_module(self: &SymbolBuilder, ast_module: &Module, fqn: String) {
    for i in 0..ast_module.decls.len {
        let d = &ast_module.decls[i]
        d.* match {
            Function(fd) => add_function_symbol(self, &fd, fqn),
            _ => {},
        }
    }
}

fn add_function_symbol(self: &SymbolBuilder, decl: &FunctionDecl, fqn: String) {
    let fid = self.by_decl.get(node_id_of(decl.span))
    if fid.is_none() { return }
    let sig = self.by_fn_sig.get(fid.unwrap())
    if sig.is_none() { return }
    let s = sig.unwrap()
    let sym = mangle_symbol(fqn, decl.name, is_foreign_directive(&decl.directives),
        &s.params, self.nominals, self.allocator)
    self.by_fn_id.set(fid.unwrap(), sym)
}

pub fn finish(self: &SymbolBuilder) SymbolTable {
    return SymbolTable {
        by_fn_id = self.by_fn_id,
        by_decl = self.by_decl,
        by_fn_sig = self.by_fn_sig,
        by_spec_id = self.by_spec_id,
        by_spec_sig = self.by_spec_sig,
    }
}

// Symbol mangling (docs/spec.md 7.1.1, docs/adr/0004)
//
// A symbol is a `_`-joined sequence of escaped segments: the module path,
// the function name, then one token per parameter type. Parameter types are
// what separate overloads, so no counter is involved and a symbol is a pure
// function of the declaration - inserting a function cannot rename another.
//
// Escaping: a literal `_` in a source identifier is written `_0`, so a lone
// `_` never occurs inside a segment and the `__` from joining is
// unambiguously a separator. Without this, module `a.b` fn `c` and module
// `a` fn `b__c` both produced `a__b__c`.

// Append `s` with source underscores escaped as `_0`.
fn append_escaped(sb: &StringBuilder, s: String) {
    for i in 0..s.len {
        if s[i] == '_' {
            sb.append("_0")
        } else {
            sb.append_byte(s[i])
        }
    }
}

// Append a module path: `.` becomes the segment separator, and source
// underscores inside each segment are escaped, in one pass.
fn append_module_path(sb: &StringBuilder, fqn: String) {
    for i in 0..fqn.len {
        if fqn[i] == '.' {
            sb.append("__")
        } else {
            if fqn[i] == '_' {
                sb.append("_0")
            } else {
                sb.append_byte(fqn[i])
            }
        }
    }
}

// One token per parameter type. Distinct types must produce distinct
// tokens; unresolved and inference types collapse to `t` because they
// cannot appear in a lowered signature (the callable gate rejects them).
fn append_type_token(sb: &StringBuilder, ty: &Ty, reg: &NominalRegistry) {
    ty.* match {
        Prim(p) => sb.append(prim_token(p)),
        Ref(inner) => {
            sb.append("ref_")
            append_type_token(sb, inner, reg)
        },
        Array(arr) => {
            sb.append("arr")
            sb.append(arr.length as u64)
            sb.append("_")
            append_type_token(sb, arr.elem, reg)
        },
        Tuple(elems) => {
            sb.append("tup")
            for i in 0..elems.len {
                sb.append("_")
                append_type_token(sb, &elems[i], reg)
            }
        },
        Nominal(nr) => {
            // The name is an FQN, so it carries dots - route it through the
            // same escaping as a module path or the token is not a valid C
            // identifier.
            append_module_path(sb, nominal_name(reg, nr.id))
            for i in 0..nr.args.len {
                sb.append("_")
                append_type_token(sb, &nr.args[i], reg)
            }
        },
        Void => sb.append("void"),
        Never => sb.append("never"),
        _ => sb.append("t"),
    }
}

// The declaring FQN, so two same-named types from different modules do
// not produce the same token.
fn nominal_name(reg: &NominalRegistry, id: NominalId) String {
    return reg.get(id).* match {
        NomStruct(s) => s.fqn,
        NomEnum(e) => e.fqn,
    }
}

fn prim_token(p: PrimitiveKind) String {
    return p match {
        Bool => "bool",
        I8 => "i8",
        U8 => "u8",
        I16 => "i16",
        U16 => "u16",
        I32 => "i32",
        U32 => "u32",
        Char => "char",
        I64 => "i64",
        U64 => "u64",
        ISize => "isize",
        USize => "usize",
        F32 => "f32",
        F64 => "f64",
    }
}

// Shared mangling core: `module__name__param__param` into `sb`.
fn append_mangled(sb: &StringBuilder, fqn: String, name: String, params: &List(Ty), reg: &NominalRegistry) {
    if fqn.len > 0 {
        append_module_path(sb, fqn)
        sb.append("__")
    }
    append_escaped(sb, name)
    for i in 0..params.len {
        sb.append("__")
        append_type_token(sb, &params[i], reg)
    }
}

// The C symbol a function lowers to. The entry point and foreign functions
// keep their declared names - both name symbols fixed outside the compiler
// (the backend's entry wiring, and the C linker). Everything else is
// qualified by module path and separated by parameter types.
fn mangle_symbol(fqn: String, name: String, is_foreign: bool, params: &List(Ty), reg: &NominalRegistry, allocator: &Allocator? = null) OwnedString {
    if is_foreign or name == "main" { return from_view(name, allocator) }

    let sb = string_builder(fqn.len + name.len + 16, allocator)
    defer sb.deinit()
    append_mangled(&sb, fqn, name, params, reg)
    return sb.to_string()
}

// A specialization's C symbol: the ordinary mangle plus a `__ret_` token.
// The return participates in the specialization key, so it has to
// participate in the symbol too - a return-only-polymorphic template's
// instantiations differ in nothing else - and the suffix keeps every
// specialization distinct from same-parameter monomorphic overloads.
fn mangle_spec_symbol(fqn: String, name: String, sig: &FnSig, reg: &NominalRegistry, allocator: &Allocator? = null) OwnedString {
    let sb = string_builder(fqn.len + name.len + 24, allocator)
    defer sb.deinit()
    append_mangled(&sb, fqn, name, &sig.params, reg)
    sb.append("__ret_")
    append_type_token(&sb, &sig.ret, reg)
    return sb.to_string()
}

// Tests

test "assigns one symbol per callable function, keyed by registry id" {
    let unit = analyze(from_view("fn add(a: i32, b: i32) i32 { return a + b }"), "test.f")
    let sb = symbol_builder(&unit.result)
    assert_eq(sb.by_decl.length, 1 as usize, "the decl span keys back to a registry id")
    sb.add_module(&unit.module, "")
    assert_eq(sb.by_fn_id.length, 1 as usize, "one symbol assigned")
}

test "mangles symbols by module fqn, keeping main and foreigns bare" {
    let reg = nominal_registry()
    defer reg.deinit()
    let none: List(Ty) = list(0)
    defer none.deinit()

    // Source underscores escape to `_0`, so a lone `_` never appears inside a
    // segment and `__` is unambiguously the separator.
    let a = mangle_symbol("flang_typer.checker", "deinit", false, &none, &reg)
    defer a.deinit()
    let b = mangle_symbol("core.io", "printf", true, &none, &reg)
    defer b.deinit()
    let c = mangle_symbol("app.entry", "main", false, &none, &reg)
    defer c.deinit()
    let d = mangle_symbol("", "add", false, &none, &reg)
    defer d.deinit()
    assert_true(a.as_view() == "flang_0typer__checker__deinit", "dotted fqn separates, underscores escape")
    assert_true(b.as_view() == "printf", "foreign names pass through")
    assert_true(c.as_view() == "main", "main stays bare")
    assert_true(d.as_view() == "add", "no fqn, bare name")
}

test "escaping keeps a dotted path distinct from an underscored name" {
    // The previous encoding mapped `.` to `__` and left source underscores
    // alone, so module `a.b` fn `c` and module `a` fn `b__c` both produced
    // `a__b__c` - two different functions, one symbol.
    let reg = nominal_registry()
    defer reg.deinit()
    let none: List(Ty) = list(0)
    defer none.deinit()

    let dotted = mangle_symbol("a.b", "c", false, &none, &reg)
    defer dotted.deinit()
    let underscored = mangle_symbol("a", "b__c", false, &none, &reg)
    defer underscored.deinit()
    assert_true(dotted.as_view() == "a__b__c", "dotted path uses the separator")
    assert_true(underscored.as_view() == "a__b_0_0c", "source underscores escape")
    assert_true(!(dotted.as_view() == underscored.as_view()), "the two no longer collide")
}

test "overloads separate by parameter type, with no counter" {
    // Symbols are a pure function of the declaration: same name, different
    // parameters, different symbol - regardless of declaration order or of
    // how many overloads the walk has already seen.
    let reg = nominal_registry()
    defer reg.deinit()

    let one: List(Ty) = list(1)
    defer one.deinit()
    one.push(Ty.Prim(PrimitiveKind.I32))

    let two: List(Ty) = list(2)
    defer two.deinit()
    two.push(Ty.Prim(PrimitiveKind.I32))
    two.push(Ty.Prim(PrimitiveKind.I32))

    let a = mangle_symbol("m", "f", false, &one, &reg)
    defer a.deinit()
    let b = mangle_symbol("m", "f", false, &two, &reg)
    defer b.deinit()
    assert_true(a.as_view() == "m__f__i32", "one i32 parameter")
    assert_true(b.as_view() == "m__f__i32__i32", "two i32 parameters")
    assert_true(!(a.as_view() == b.as_view()), "arities separate")

    // Re-mangling the same declaration yields the same symbol - the property
    // the ordinal scheme could not provide.
    let again = mangle_symbol("m", "f", false, &one, &reg)
    defer again.deinit()
    assert_true(again.as_view() == a.as_view(), "deterministic across calls")
}
