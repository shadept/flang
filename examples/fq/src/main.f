import std.encoding.json
import std.env
import std.io.file

fn print_usage() {
    println("Usage: fq [file] <query>")
    println("")
    println("Queries:")
    println("  .foo")
    println("  .foo.bar")
    println("  foo.bar   (leading dot is optional)")
    println("")
    println("If [file] is omitted, fq reads JSON from stdin.")
}

fn apply_query(root: &JsonValue, query: String) &JsonValue? {
    if query.len == 0 or query == "." {
        return root
    }

    let current = root

    let i: usize = 0
    if query[0] == '.' {
        i = 1
    }

    if i >= query.len {
        return current
    }

    let segment_start = i
    loop {
        const at_end = i >= query.len
        if !at_end and query[i] != '.' {
            i = i + 1
            continue
        }

        if i == segment_start {
            return null
        }

        const key = query[segment_start..i]
        current.* match {
            Object(obj) => { current = obj.json_get_ref(key)? }
            else => { return null }
        }

        if at_end {
            break
        }

        i = i + 1
        segment_start = i
    }

    return current
}

fn print_selected(root: &JsonValue, query: String) {
    const selected = apply_query(root, query)
    if selected.is_none() {
        println("null")
        return
    }

    stringify_pretty(selected.unwrap(), stdout.writer(), 2)
    println("")
}

pub fn main() i32 {
    const argc = args_count()
    if argc < 2 or argc > 3 {
        print_usage()
        return 2
    }

    let file_path = ""
    let query = ""

    if argc == 2 {
        query = arg(1).unwrap()
    } else {
        file_path = arg(1).unwrap()
        query = arg(2).unwrap()
    }

    if file_path.len == 0 {
        const parsed = parse(stdin.reader())
        if parsed.is_err() {
            print("fq: failed to parse JSON: ")
            println(parsed.unwrap_err().to_string())
            return 1
        }

        let root = parsed.unwrap()
        print_selected(&root, query)
        root.deinit()
        return 0
    }

    const opened = open_file(file_path, FileMode.Read)
    if opened.is_err() {
        print("fq: cannot open ")
        println(file_path)
        return 1
    }

    let file = opened.unwrap()
    const parsed = parse(file.reader())
    close_file(&file)

    if parsed.is_err() {
        print("fq: failed to parse JSON: ")
        println(parsed.unwrap_err().to_string())
        return 1
    }

    let root = parsed.unwrap()
    print_selected(&root, query)
    root.deinit()

    return 0
}
