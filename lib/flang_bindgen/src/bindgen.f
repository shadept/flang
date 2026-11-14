// Bindings for a C header, from its preprocessed text.
//
// The caller preprocesses a probe file (`macros.probe_source`) with the platform's C compiler and
// hands the output here; nothing in this library touches a file or a process.

import std.collections.list
import std.string
import std.test

import flang_bindgen.emit
import flang_bindgen.lexer
import flang_bindgen.model
import flang_bindgen.parser

/// Translate preprocessed C into the FLang binding module for the library under `cfg.root`.
pub fn generate_bindings(preprocessed: String, cfg: BindgenConfig) Bindings {
    const lexed = lex_c(preprocessed)
    defer lexed.deinit()
    const m = parse_c(&lexed, cfg.host)
    defer m.deinit()
    return emit_bindings(&m, &lexed.files, cfg)
}

fn gen(src: String) Bindings {
    return generate_bindings(
        src,
        BindgenConfig {
            header = "lib.h",
            root = "C:\\inc\\lib",
            host = Host { long_bits = 32, wchar_bits = 16 },
            fold_case = true,
        },
    )
}

fn has(b: &Bindings, line: String) bool {
    return b.source.view().contains(line)
}

test "only the library's own files are bound" {
    const b = gen(
        "#line 1 \"C:\\\\sys\\\\stdint.h\"\ntypedef unsigned int uint32_t;\nint sys_fn(void);\n#line 1 \"C:\\\\INC\\\\lib\\\\lib.h\"\nuint32_t lib_fn(uint32_t x);\n",
    )
    defer b.deinit()
    assert_eq(
        has(&b, "#foreign pub fn lib_fn(x: u32) u32\n"),
        true,
        "library function, standard typedef kept",
    )
    assert_eq(has(&b, "sys_fn"), false, "system function left out")
    assert_eq(b.files.len, 1 as usize, "one library file")
    assert_eq(b.files[0].view(), "C:/INC/lib/lib.h", "forward slashes, case kept")
}

test "pointers are nullable, handles opaque, unions real" {
    const b = gen(
        "#line 1 \"C:/inc/lib/lib.h\"\ntypedef struct Win Win;\ntypedef union Ev { unsigned type; float f[2]; } Ev;\nWin *open_win(const char *title, Win **out);\nvoid poll(Ev *e, void (*cb)(void *ud));\n",
    )
    defer b.deinit()
    assert_eq(has(&b, "pub type Win = #foreign struct {}\n"), true, "opaque handle")
    assert_eq(
        has(&b, "pub type Ev = #foreign union {\n    type_: u32\n    f: [f32; 2]\n}\n"),
        true,
        "union with a renamed member",
    )
    assert_eq(
        has(&b, "#foreign pub fn open_win(title: &u8?, out: &(&Win?)?) &Win?\n"),
        true,
        "pointers",
    )
    assert_eq(has(&b, "#foreign pub fn poll(e: &Ev?, cb: #foreign fn(&u8?))\n"), true, "callback")
}

test "what FLang cannot spell is left out with a warning" {
    const b = gen(
        "#line 1 \"C:/inc/lib/lib.h\"\ntypedef struct Bits { unsigned a : 3; } Bits;\nint logf(const char *fmt, ...);\nvoid use_bits(Bits b);\nvoid hold(Bits *b);\ntypedef struct rHandle rHandle;\nvoid take(rHandle *h);\n",
    )
    defer b.deinit()
    assert_eq(has(&b, "pub type Bits = #foreign struct {}\n"), true, "bit-field struct kept opaque")
    assert_eq(has(&b, "#foreign pub fn hold(b: &Bits?)\n"), true, "usable behind a pointer")
    assert_eq(has(&b, "use_bits"), false, "not by value")
    assert_eq(has(&b, "logf"), false, "variadic")
    assert_eq(has(&b, "#foreign pub fn take(h: &RHandle?)\n"), true, "lowercase type capitalized")
    assert_eq(b.warnings.len, 3 as usize, "bit-fields, variadic, by-value opaque")
}

test "constants from enums and macro probes" {
    const b = gen(
        "#line 1 \"C:/inc/lib/lib.h\"\ntypedef enum Key { KEY_A = 65, KEY_B } Key;\n#line 1 \"C:/tmp/probe.c\"\n__flang_probe \"FLAG\" 0x20u __flang_end\n__flang_probe \"NAME\" \"lib\" __flang_end\n__flang_probe \"HALF\" .5f __flang_end\n__flang_probe \"true\" 1 __flang_end\n__flang_probe \"KEY_A\" 65 __flang_end\n",
    )
    defer b.deinit()
    assert_eq(has(&b, "pub const KEY_B: i32 = 66\n"), true, "enum constant")
    assert_eq(has(&b, "pub type Key = i32\n"), true, "enum typedef")
    assert_eq(has(&b, "pub const FLAG: u32 = 32\n"), true, "unsigned macro")
    assert_eq(has(&b, "pub const NAME = \"lib\"\n"), true, "string macro")
    assert_eq(has(&b, "pub const HALF: f32 = 0.5\n"), true, "float macro")
    assert_eq(has(&b, "pub const true"), false, "keyword skipped")
    assert_eq(b.source.view().count("KEY_A:"), 1 as usize, "no duplicate of the enum constant")
}
