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
    by_fn_id: Dict(u32, String)
    by_decl: Dict(NodeId, u32)
    // One signature, two parallel dicts, and the return type stored as a
    // singleton list: the reference compiler ICEs (unresolved-var at
    // lowering) when `Dict(u32, Ty)` and `Dict(u32, List(Ty))` coexist -
    // a generic-specialization collision - so both dicts use the one
    // instantiation and `FnSig` is assembled on lookup. See
    // docs/known-issues.md.
    by_fn_params: Dict(u32, List(Ty))
    by_fn_ret: Dict(u32, List(Ty))
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
    return self.by_fn_id.get(fn_id)
}

// The registry id of the function this declaration declares.
pub fn decl_fn_id(self: &SymbolTable, decl: &FunctionDecl) u32? {
    return self.by_decl.get(node_id_of(decl.span))
}

// The declared signature of a registered lowerable function.
pub fn sig_of(self: &SymbolTable, fn_id: u32) FnSig? {
    let params = self.by_fn_params.get(fn_id)
    if params.is_none() { return null }
    let ret = self.by_fn_ret.get(fn_id)
    if ret.is_none() { return null }
    let rl = ret.unwrap()
    return Some(FnSig { params = params.unwrap(), ret = rl[0] })
}

pub fn deinit(self: &SymbolTable) {
    self.by_fn_id.deinit()
    self.by_decl.deinit()
    self.by_fn_params.deinit()
    self.by_fn_ret.deinit()
}

// Assigns symbols across a whole program. `seen` carries the ordinal
// counter across modules, so the walk order fixes the ordinals - which is
// why symbols are assigned before any body lowers, not during.
// The two tables are held flat rather than as a nested `SymbolTable`:
// mutating a dict two field-hops deep through a reference does not stick.
pub type SymbolBuilder = struct {
    by_fn_id: Dict(u32, String)
    by_decl: Dict(NodeId, u32)
    by_fn_params: Dict(u32, List(Ty))
    by_fn_ret: Dict(u32, List(Ty))
    nominals: &NominalRegistry
    allocator: &Allocator?
}

// Index every lowerable scheme by its declaration span and registry id up
// front; the per-module walk then maps each decl to its symbol with one
// lookup. A scheme outside the lowerable subset is left out entirely -
// membership in these tables IS the "is this callable?" gate.
pub fn symbol_builder(result: &TypeCheckResult, allocator: &Allocator? = null) SymbolBuilder {
    let by_fn_id: Dict(u32, String) = dict(allocator)
    let by_decl: Dict(NodeId, u32) = dict(allocator)
    let by_fn_params: Dict(u32, List(Ty)) = dict(allocator)
    let by_fn_ret: Dict(u32, List(Ty)) = dict(allocator)
    for entry in result.functions.by_name {
        let overloads = entry.value
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
            by_fn_params.set(f.id, s.params)
            let rl: List(Ty) = list(1, allocator)
            rl.push(s.ret)
            by_fn_ret.set(f.id, rl)
        }
    }
    return .{
        by_fn_id = by_fn_id,
        by_decl = by_decl,
        by_fn_params = by_fn_params,
        by_fn_ret = by_fn_ret,
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
    let params = self.by_fn_params.get(fid.unwrap())
    if params.is_none() { return }
    let p = params.unwrap()
    let sym = mangle_symbol(fqn, decl.name, is_foreign_directive(&decl.directives),
        &p, self.nominals, self.allocator)
    self.by_fn_id.set(fid.unwrap(), sym)
}

pub fn finish(self: &SymbolBuilder) SymbolTable {
    return SymbolTable {
        by_fn_id = self.by_fn_id,
        by_decl = self.by_decl,
        by_fn_params = self.by_fn_params,
        by_fn_ret = self.by_fn_ret,
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

// The C symbol a function lowers to. The entry point and foreign functions
// keep their declared names - both name symbols fixed outside the compiler
// (the backend's entry wiring, and the C linker). Everything else is
// qualified by module path and separated by parameter types.
fn mangle_symbol(fqn: String, name: String, is_foreign: bool, params: &List(Ty), reg: &NominalRegistry, allocator: &Allocator? = null) String {
    if is_foreign { return name }
    if name == "main" { return name }

    let sb = string_builder(fqn.len + name.len + 16, allocator)
    if fqn.len > 0 {
        append_module_path(&sb, fqn)
        sb.append("__")
    }
    append_escaped(&sb, name)
    for i in 0..params.len {
        sb.append("__")
        append_type_token(&sb, &params[i], reg)
    }
    // ponytail: symbol strings are leaked - one-shot builds exit before it
    // matters; arena-own IrModule names if the LSP ever lowers.
    let owned = sb.to_string()
    sb.deinit()
    return owned.as_view()
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
    assert_true(mangle_symbol("flang_typer.checker", "deinit", false, &none, &reg) == "flang_0typer__checker__deinit", "dotted fqn separates, underscores escape")
    assert_true(mangle_symbol("core.io", "printf", true, &none, &reg) == "printf", "foreign names pass through")
    assert_true(mangle_symbol("app.entry", "main", false, &none, &reg) == "main", "main stays bare")
    assert_true(mangle_symbol("", "add", false, &none, &reg) == "add", "no fqn, bare name")
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
    let underscored = mangle_symbol("a", "b__c", false, &none, &reg)
    assert_true(dotted == "a__b__c", "dotted path uses the separator")
    assert_true(underscored == "a__b_0_0c", "source underscores escape")
    assert_true(!(dotted == underscored), "the two no longer collide")
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
    let b = mangle_symbol("m", "f", false, &two, &reg)
    assert_true(a == "m__f__i32", "one i32 parameter")
    assert_true(b == "m__f__i32__i32", "two i32 parameters")
    assert_true(!(a == b), "arities separate")

    // Re-mangling the same declaration yields the same symbol - the property
    // the ordinal scheme could not provide.
    assert_true(mangle_symbol("m", "f", false, &one, &reg) == a, "deterministic across calls")
}
