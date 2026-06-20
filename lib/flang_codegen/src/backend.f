// Backend interface — shared types and contract that every codegen
// backend implements. The C backend lives in `c_backend.f`. Future
// backends (LLVM, QBE, Cranelift) plug in the same shape.
//
// The contract is a single function:
//
//   compile(module: &IrModule, options: &BuildOptions) -> Result(BuildResult, BuildError)
//
// It performs FIR -> target lowering, invokes the platform toolchain,
// and produces an executable at `options.output_path`. Extra .c files,
// libraries, include paths and link flags are passed through the
// `BuildOptions` struct (the compilation model is shared across
// backends).
//
// Each backend module re-exports `compile()` so callers stay agnostic:
//
//   import flang_codegen.c_backend
//   c_backend.compile(&m, &opts).unwrap()

import std.allocator
import std.list
import std.option
import std.string

// ─────────────────────────────────────────────────────────────────────────
// Build options
// ─────────────────────────────────────────────────────────────────────────

pub type BuildMode = enum {
    Debug
    Release
}

// Knobs threaded through every backend. Backends are free to ignore
// fields that don't apply to them (e.g. an LLVM backend that handles
// linkage internally may still produce a stand-alone object). The C
// backend honours every field.
//
// Lifetime: `BuildOptions` owns the inner lists; call `deinit()` when
// done. String fields are *borrowed* views — the caller keeps backing
// storage alive for the duration of `compile()`.
pub type BuildOptions = struct {
    // Final artifact path (executable). On Windows, the backend appends
    // ".exe" if missing.
    output_path: String

    // Debug or Release affects `-O` flags and debug-info emission.
    mode: BuildMode

    // Additional .c sources compiled and linked alongside the generated
    // file (used for FFI shims like stdlib/std/process.c).
    extra_c_files: List(String)

    // Pre-compiled object files linked as-is. Useful with a future build
    // cache where companion .c files compile once and stay cached.
    extra_obj_files: List(String)

    // Directories appended to the compiler's include search path (-I).
    include_paths: List(String)

    // Libraries to link against. Each entry may be:
    //   - An absolute path to a .a / .lib (passed through verbatim)
    //   - A bare name like "m" (the backend prepends "-l" on unix)
    // The C backend always appends "-lm" on unix automatically.
    libs: List(String)

    // Extra cflags / ldflags passed straight through to the compiler.
    cflags: List(String)
    ldflags: List(String)

    // When set, the backend writes the generated translation unit to
    // this path before invoking the compiler. The .c file otherwise
    // lives in a temporary location next to the executable.
    emit_c_path: String?

    // Skip cleanup of intermediate .c / .obj files.
    keep_temps: bool

    // Force a specific compiler binary instead of running discovery.
    // The path is taken verbatim; required env vars (e.g. MSVC
    // INCLUDE/LIB) are *not* synthesised — caller is responsible.
    compiler_override: String?

    // Allocator used for everything the backend allocates on behalf of
    // the call (temp strings, argv lists, the result struct, …).
    allocator: &Allocator
}

pub fn build_options(output_path: String, allocator: &Allocator? = null) BuildOptions {
    const alloc = allocator.or_global()
    let extra_c: List(String) = list(0, alloc)
    let extra_obj: List(String) = list(0, alloc)
    let includes: List(String) = list(0, alloc)
    let libs: List(String) = list(0, alloc)
    let cflags: List(String) = list(0, alloc)
    let ldflags: List(String) = list(0, alloc)
    return BuildOptions {
        output_path = output_path,
        mode = BuildMode.Debug,
        extra_c_files = extra_c,
        extra_obj_files = extra_obj,
        include_paths = includes,
        libs = libs,
        cflags = cflags,
        ldflags = ldflags,
        emit_c_path = null,
        keep_temps = false,
        compiler_override = null,
        allocator = alloc,
    }
}

pub fn deinit(self: &BuildOptions) {
    self.extra_c_files.deinit()
    self.extra_obj_files.deinit()
    self.include_paths.deinit()
    self.libs.deinit()
    self.cflags.deinit()
    self.ldflags.deinit()
}

// Fluent helpers — let callers chain configuration without juggling the
// inner lists.
pub fn add_c_file(self: &BuildOptions, p: String) &BuildOptions {
    self.extra_c_files.push(p)
    return self
}

pub fn add_obj_file(self: &BuildOptions, p: String) &BuildOptions {
    self.extra_obj_files.push(p)
    return self
}

pub fn add_include_path(self: &BuildOptions, p: String) &BuildOptions {
    self.include_paths.push(p)
    return self
}

pub fn add_lib(self: &BuildOptions, name_or_path: String) &BuildOptions {
    self.libs.push(name_or_path)
    return self
}

pub fn add_cflag(self: &BuildOptions, flag: String) &BuildOptions {
    self.cflags.push(flag)
    return self
}

pub fn add_ldflag(self: &BuildOptions, flag: String) &BuildOptions {
    self.ldflags.push(flag)
    return self
}

pub fn set_mode(self: &BuildOptions, m: BuildMode) &BuildOptions {
    self.mode = m
    return self
}

pub fn set_emit_c_path(self: &BuildOptions, p: String) &BuildOptions {
    self.emit_c_path = p
    return self
}

pub fn set_keep_temps(self: &BuildOptions, k: bool) &BuildOptions {
    self.keep_temps = k
    return self
}

// ─────────────────────────────────────────────────────────────────────────
// Build results and errors
// ─────────────────────────────────────────────────────────────────────────

pub type BuildResult = struct {
    // Absolute path to the produced executable.
    executable_path: OwnedString

    // Generated C file, if `keep_temps` or `emit_c_path` was set.
    c_source_path: OwnedString?
}

pub fn deinit(self: &BuildResult) {
    self.executable_path.deinit()
    self.c_source_path match {
        Some(p) => { let pp = p; pp.deinit() },
        None => {},
    }
}

pub type BuildError = enum {
    // Compiler discovery turned up nothing usable.
    NoCompilerFound
    // The C compiler ran but exited non-zero. The payload is its exit code.
    CompilerFailed(i32)
    // Spawning the compiler failed (binary missing, permission denied, …).
    SpawnFailed
    // Writing the generated .c file or reading the binary failed.
    IOError
    // FIR -> target lowering rejected the input module.
    LowerFailed
}

// ─────────────────────────────────────────────────────────────────────────
// Compiler info — populated by each backend's discovery routine
// ─────────────────────────────────────────────────────────────────────────

pub type CompilerKind = enum {
    Msvc          // cl.exe
    Gcc           // gcc
    Clang         // clang
    XcrunClang    // macOS: xcrun clang
}

// Result of compiler discovery. `extra_env_keys[i]` / `extra_env_vals[i]`
// are environment overrides that must be applied to the child process
// before invocation (cl.exe on Windows needs INCLUDE / LIB / PATH).
//
// Owns its strings. Call `deinit()` when done.
pub type CompilerInfo = struct {
    kind: CompilerKind
    // Human-readable name ("cl.exe", "gcc", "clang", "xcrun clang"). Used
    // in error messages and `--find-compilers` style output.
    name: OwnedString
    // Absolute path to the binary to spawn. For `XcrunClang` this is the
    // path to `xcrun`; the backend prepends `clang` as the first arg.
    path: OwnedString
    extra_env_keys: List(OwnedString)
    extra_env_vals: List(OwnedString)
    allocator: &Allocator
}

pub fn deinit(self: &CompilerInfo) {
    self.name.deinit()
    self.path.deinit()
    for i in 0..self.extra_env_keys.len {
        let k = self.extra_env_keys[i]
        k.deinit()
    }
    self.extra_env_keys.deinit()
    for i in 0..self.extra_env_vals.len {
        let v = self.extra_env_vals[i]
        v.deinit()
    }
    self.extra_env_vals.deinit()
}

pub fn is_msvc(self: &CompilerInfo) bool {
    return self.kind match { Msvc => true, _ => false }
}

pub fn is_xcrun(self: &CompilerInfo) bool {
    return self.kind match { XcrunClang => true, _ => false }
}
