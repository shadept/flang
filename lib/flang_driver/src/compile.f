// One-shot build: lower a checked unit to FIR and hand it to the C backend.
// The back half of the pipeline `flang_driver.analyze` opens.

import std.allocator
import std.option
import std.result
import std.string
import flang_codegen.fir
import flang_codegen.backend
import flang_codegen.c_backend
import flang_driver.driver
import flang_driver.lower

// Lower `unit` to FIR and compile+link it to an executable at
// `output_path` (the backend appends a platform extension if missing).
// The unit must be error-free - callers check `error_count` first; a unit
// that failed to type-check has no usable types to lower.
pub fn build_unit(unit: &AnalyzedUnit, output_path: String, allocator: &Allocator? = null) Result(BuildResult, BuildError) {
    let alloc = allocator.or_global()
    let m = lower_module(&unit.module, &unit.result, alloc)
    let opts = build_options(output_path, alloc)
    let r = compile(&m, &opts)
    opts.deinit()
    m.deinit()
    return r
}
