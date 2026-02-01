import std.io.file
import std.result

pub fn main() {
    const file = open_file("test.f", FileMode.Read).except("Failed to open file")
    defer close_file(&file).except("Failed to close file")

    print("Open fd: ")
    println(file.handle.fd)



    // const buffer = [u8; 1024]
    // const reader = file.reader()
    // const content = reader.read_all()
    // println(content)
}
