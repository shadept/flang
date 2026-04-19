// fcsv — CSV column/row selector
//
// Usage:
//   fcsv data.csv name,age 0..10
//   cat data.csv | fcsv name,age 0..10
//   fcsv --count data.csv      # SIMD-accelerated newline count

import std.encoding.csv
import std.io.file
import std.io.reader
import std.env
import std.list
import std.simd
import std.string
import std.string_builder
import std.conv

fn print_usage() {
    println("Usage: fcsv [file] [columns] [range]")
    println("")
    println("Arguments (positional, inferred):")
    println("  file       CSV file path (reads stdin if omitted)")
    println("  columns    Comma-separated column names (e.g. name,age)")
    println("  start..end Row range (e.g. 0..10, 5..)")
    println("  ..end      First N rows (e.g. ..5)")
    println("  -N         Last N rows (e.g. -5)")
    println("")
    println("Modes:")
    println("  --count    Print number of newlines via SIMD and exit")
}

const MAX_ROWS: usize = 0xFFFF_FFFF_FFFF_FFFF

// SIMD-accelerated count of `target` bytes in `data`.
// Processes 16 bytes per iteration via 128-bit vectors, then a scalar tail.
fn simd_count_byte(data: String, target: u8) usize {
    let count: usize = 0
    let i: usize = 0
    const splat = v128_splat_u8(target)
    while i + 16 <= data.len {
        const chunk = v128_load(data.ptr + i)
        const eq = v128_cmpeq_u8(chunk, splat)
        count = count + v128_count_true(eq) as usize
        i = i + 16
    }
    while i < data.len {
        if data[i] == target { count = count + 1 }
        i = i + 1
    }
    return count
}

fn parse_range(s: String) (usize, usize)? {
    const dot_pos = s.find("..")
    if dot_pos.is_none() { return null }

    const start_str = s[0..dot_pos.value]
    const end_str = s[dot_pos.value + 2..s.len]

    let start_val: usize = 0
    let end_val: usize = MAX_ROWS

    if start_str.len > 0 {
        const parsed = parse_usize(start_str)
        if parsed.is_err() { return null }
        start_val = parsed.unwrap().0 as usize
    }

    if end_str.len > 0 {
        const parsed = parse_usize(end_str)
        if parsed.is_err() { return null }
        end_val = parsed.unwrap().0 as usize
    }

    return (start_val, end_val)
}

fn parse_tail(s: String) usize? {
    if s.len < 2 { return null }
    if s[0] != '-' { return null }
    const num_str = s[1..s.len]
    const parsed = parse_usize(num_str)
    if parsed.is_err() { return null }
    return parsed.unwrap().0 as usize
}

fn split_columns(s: String, cols: &List(String)) {
    let start: usize = 0
    for (i in 0..s.len) {
        if s[i] == ',' {
            if i > start {
                cols.push(s[start..i])
            }
            start = i + 1
        }
    }
    if start < s.len {
        cols.push(s[start..s.len])
    }
}

fn print_record(sb: &StringBuilder, record: &CsvRecord, indices: &List(usize), has_columns: bool, delimiter: u8) {
    sb.clear()
    if has_columns {
        for (i in 0..indices.len) {
            if i > 0 { sb.append_byte(delimiter) }
            const field = record.get(indices[i])
            if field.is_some() { sb.append(field.value) }
        }
    } else {
        for (i in 0..record.field_count()) {
            if i > 0 { sb.append_byte(delimiter) }
            const field = record.get(i)
            if field.is_some() { sb.append(field.value) }
        }
    }
    println(sb.as_view())
}

fn run(reader: &CsvReader, columns_arg: String, range_start: usize, range_end: usize, has_range: bool, tail_count: usize, has_tail: bool) i32 {
    const hdrs = reader.get_headers()
    const rows = reader.get_rows()
    if rows.len == 0 { return 0 }

    // Resolve column indices
    let col_indices = list(16)
    let has_columns = false

    if columns_arg.len > 0 {
        let col_names = list(16)
        split_columns(columns_arg, &col_names)

        for (c in 0..col_names.len) {
            let found = false
            for (h in 0..hdrs.len) {
                if hdrs[h] == col_names[c] {
                    col_indices.push(h)
                    found = true
                    break
                }
            }
            if !found {
                print("fcsv: unknown column: ")
                println(col_names[c])
                return 1
            }
        }
        has_columns = true
    }

    let sb = string_builder(256)
    const delimiter = reader.options.delimiter

    // Print header row
    sb.clear()
    if has_columns {
        for (i in 0..col_indices.len) {
            if i > 0 { sb.append_byte(delimiter) }
            sb.append(hdrs[col_indices[i]])
        }
    } else {
        for (i in 0..hdrs.len) {
            if i > 0 { sb.append_byte(delimiter) }
            sb.append(hdrs[i])
        }
    }
    println(sb.as_view())

    // Determine row range
    let start: usize = 0
    let end: usize = rows.len

    if has_tail {
        start = if rows.len > tail_count { rows.len - tail_count } else { 0usize }
    } else if has_range {
        start = range_start
        end = if range_end < rows.len { range_end } else { rows.len }
    }

    // Print rows
    for (i in start..end) {
        print_record(&sb, &rows[i], &col_indices, has_columns, delimiter)
    }

    sb.deinit()
    return 0
}

fn run_count(file_path: String) i32 {
    const result = open_file(file_path, FileMode.Read)
    if result.is_err() {
        print("fcsv: cannot open ")
        println(file_path)
        return 1
    }
    let file = result.unwrap()
    const data = read_all(&file)
    close_file(&file)
    if data.is_err() {
        println("fcsv: read failed")
        return 1
    }
    let owned = data.unwrap()
    const n = simd_count_byte(owned.as_view(), '\n')
    let sb = string_builder(32)
    sb.append(n)
    println(sb.as_view())
    sb.deinit()
    owned.deinit()
    return 0
}

pub fn main() i32 {
    const argc = args_count()

    let file_path: String = ""
    let columns_arg: String = ""
    let range_start: usize = 0
    let range_end: usize = 0
    let has_range = false
    let tail_count: usize = 0
    let has_tail = false
    let count_mode = false

    for (i in 1..argc) {
        const a = arg(i)
        if a.is_none() { continue }
        const argv = a.value

        if argv == "--help" or argv == "-h" {
            print_usage()
            return 0
        }

        if argv == "--count" {
            count_mode = true
            continue
        }

        const tail = parse_tail(argv)
        if tail.is_some() {
            tail_count = tail.value
            has_tail = true
            continue
        }

        const range = parse_range(argv)
        if range.is_some() {
            range_start = range.value.0
            range_end = range.value.1
            has_range = true
            continue
        }

        // First non-range arg: try as file, fall back to columns
        if file_path.len == 0 and columns_arg.len == 0 {
            const probe = open_file(argv, FileMode.Read)
            if probe.is_ok() {
                close_file(&probe.unwrap())
                file_path = argv
            } else {
                columns_arg = argv
            }
        } else if columns_arg.len == 0 {
            columns_arg = argv
        }
    }

    if count_mode {
        if file_path.len == 0 {
            println("fcsv: --count requires a file argument")
            return 1
        }
        return run_count(file_path)
    }

    if file_path.len > 0 {
        const result = open_file(file_path, FileMode.Read)
        if result.is_err() {
            print("fcsv: cannot open ")
            println(file_path)
            return 1
        }
        let file = result.unwrap()
        let reader: CsvReader
        csv_reader_init(&reader, file.reader())
        const code = run(&reader, columns_arg, range_start, range_end, has_range, tail_count, has_tail)
        reader.deinit()
        close_file(&file)
        return code
    } else {
        let reader: CsvReader
        csv_reader_init(&reader, stdin.reader())
        const code = run(&reader, columns_arg, range_start, range_end, has_range, tail_count, has_tail)
        reader.deinit()
        return code
    }
}
