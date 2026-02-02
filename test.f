import std.io.file
import std.io.fmt
import std.result

pub fn main() i32 {
    const file = open_file("test.f", FileMode.Read)
                .except("Failed to open file")
    defer close_file(&file).except("Failed to close file")

    print("Open fd: ")
    println(file.handle.fd)

    const content = file.read_all()
                    .except("Failed to read file")
    print("File size: ")
    println(content.len)
    println("File content:")
    println(content)
    return content.len as i32
}
