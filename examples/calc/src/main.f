import calc.ast
import calc.parser
import calc.eval
import std.allocator
import std.env
import std.readline
import std.string_builder

fn eval_line(input: String) {
    if input.len == 0 { return }

    let arena_state = arena_allocator(&global_allocator)
    let arena = arena_state.allocator()
    defer arena_state.deinit()

    let p = parser(input, &arena)
    const expr = p.parse()
    const result = eval(expr)
    println(result)
}

fn run_repl() {
    let rl = readline("> ")
    defer rl.deinit()

    loop {
        const line = rl.read_line()
        if line.is_none() { break }
        eval_line(line.value)
    }
}

fn run_args() {
    // Join all args after program name with spaces
    let sb = string_builder(128)
    defer sb.deinit()

    const count = args_count()
    let i: usize = 1
    loop {
        if i >= count { break }
        if i > 1 { sb.append(" ") }
        const a = arg(i)
        if a.is_some() {
            sb.append(a.value)
        }
        i = i + 1
    }

    eval_line(sb.as_view())
}

pub fn main() i32 {
    if args_count() > 1 {
        run_args()
    } else {
        run_repl()
    }
    return 0
}
