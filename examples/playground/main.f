import std.io.file
import std.io.fmt
import std.char
import std.derive
import std.iter
import std.rc
import std.result
import std.string_builder

type Vector2 = struct {
    x: f32
    y: f32
}

#derive(Vector2, eq, clone, debug, hash)

pub fn main() i32 {
    const file = open_file("test.f", FileMode.Read).except("Failed to open file")
    defer close_file(&file).except("Failed to close file")

    print("Open fd: ")
    println(file.handle.fd)

    const content = file.read_all().except("Failed to read file")
    defer content.deinit()

    print("File size: ")

    let sb = string_builder(content.len)
    let writer = sb.buffered_writer()  // example using writer
    for c in content.chars().map(fn(c) { c.upper() }) {
        writer.write(c as u8)
    }

    println("Uppercase content:")
    println(sb.as_view())

    const some_point = rc(Vector2{x=1f32, y=2})
    defer some_point.release()

    print("ref_count: ")
    println(some_point.ref_count())

    const p = some_point.borrow()
    print("value: ")
    println(p)  // from derive(debug)
    print("hash: ")
    println(p.hash()) // from derive(hash)

    return 0
}
