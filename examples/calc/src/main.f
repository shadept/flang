import calc.ast
import calc.parser
import calc.eval
import std.env
import std.readline

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
        const l = rl.read_line() match {
            Some(v) => v,
            None => break
        }
        eval_line(l)
    }
}

fn run_args() {
    // Join all args after program name with spaces
    let sb = string_builder(128)
    defer sb.deinit()

    const count = args_count()
    for i in 1..count {
        if i > 1 { sb.append(" ") }
        arg(i) match {
            Some(s) => sb.append(s),
            None => {}
        }
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
