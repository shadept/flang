// The compile-time context a `#if` condition reads (spec §7.7), declared as the structs it reads
// as: `platform` is a `Platform`, `runtime` a `Runtime`. The compiler supplies their values for the
// target being built; no runtime value of either exists yet.

import core.option
import core.string

#foreign fn __flang_getenv(name: &u8) &u8?

// The machine you are compiling for, read as `platform` in a `#if`: `#if platform.os == "linux"`.
// It is the machine running the compiler unless `--target-os` / `--target-arch` say otherwise.
pub type Platform = struct {
    // The target operating system: `"windows"`, `"linux"`, `"macos"` or `"unknown"`.
    os: String
    // The target CPU: `"x86_64"`, `"arm64"`, `"x86"`, ...
    arch: String
}

// How this build was invoked, read as `runtime` in a `#if`: `#if runtime.testing`.
pub type Runtime = struct {
    // True under `flang test`: code only tests need can sit behind it.
    testing: bool
    // True when building with `--release`.
    release: bool
    // The environment variables the compiler sees: `runtime.env["MODE"] ?? "dev"`.
    env: Environment
}

// Environment variables, looked up one at a time: `env["HOME"]` is the value, or null when the
// variable is unset. Nothing is read until you ask for a variable.
pub type Environment = struct {}

// The value of variable `key`, or null when it is unset. `key` is any String view: it is copied
// into a terminated buffer first, and a key of 256 bytes or more is reported unset.
pub fn op_index(self: Environment, key: String) String? {
    let buf = [0u8; 256]
    if key.len >= 256 {
        return null
    }
    for i in 0..key.len {
        buf[i] = key[i]
    }
    buf[key.len] = 0u8
    const p = __flang_getenv(buf.ptr)?
    return Some(from_c_string(p))
}
