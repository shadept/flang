import std.allocator
import std.string_builder
import std.io.writer
import std.terminal

fn append_piece(sb: &StringBuilder, piece: u8) {
    if piece == b'K' { sb.append("♔") }
    else if piece == b'Q' { sb.append("♕") }
    else if piece == b'R' { sb.append("♖") }
    else if piece == b'B' { sb.append("♗") }
    else if piece == b'N' { sb.append("♘") }
    else if piece == b'P' { sb.append("♙") }
    else if piece == b'k' { sb.append("♚") }
    else if piece == b'q' { sb.append("♛") }
    else if piece == b'r' { sb.append("♜") }
    else if piece == b'b' { sb.append("♝") }
    else if piece == b'n' { sb.append("♞") }
    else if piece == b'p' { sb.append("♟") }
}

fn set_square_bg(w: &Writer, rank: i32, col: i32) {
    const is_light = (rank + col) % 2 == 0
    if is_light { set_bg(w, Color.White) }
    else { set_bg(w, Color.Green) }
}

fn display_board(fen: String) {
    const buf = [0; 256]
    const fba = fixed_buffer_allocator(buf)
    const alloc = fba.allocator()
    let sb = string_builder_with_capacity_and_allocator(256, &alloc)
    defer sb.deinit()
    let w = sb.writer()

    let rank: i32 = 8
    let col: i32 = 0

    // Rank number
    set_style(&w, Style.Dim)
    sb.append(rank)
    reset(&w)
    sb.append(" ")

    let pos: usize = 0
    loop {
        if pos >= fen.len { break }

        const ch = fen[pos]

        if ch == b' ' {
            break
        } else if ch == b'/' {
            println(sb.as_view())
            sb.clear()
            rank = rank - 1
            col = 0
            set_style(&w, Style.Dim)
            sb.append(rank)
            reset(&w)
            sb.append(" ")
        } else if ch >= b'1' and ch <= b'8' {
            const count = (ch - b'0') as i32
            for (j in 0..count) {
                set_square_bg(&w, rank, col)
                sb.append("   ")
                reset(&w)
                col = col + 1
            }
        } else {
            set_square_bg(&w, rank, col)
            const is_white_piece = ch >= b'A' and ch <= b'Z'
            if is_white_piece {
                set_style(&w, Style.Bold)
                set_bright_fg(&w, Color.White)
            } else {
                set_fg(&w, Color.Black)
            }
            sb.append(" ")
            sb.append_piece(ch)
            sb.append(" ")
            reset(&w)
            col = col + 1
        }

        pos = pos + 1
    }

    println(sb.as_view())
    sb.clear()

    // Column labels
    set_style(&w, Style.Dim)
    sb.append("   a  b  c  d  e  f  g  h")
    reset(&w)
    println(sb.as_view())
    sb.clear()

    // Side to move
    pos = pos + 1
    if (pos < fen.len) {
        sb.append("  ")
        if (fen[pos] == b'w') {
            set_style(&w, Style.Bold)
            set_bright_fg(&w, Color.White)
            sb.append("White")
            reset(&w)
            sb.append(" to move")
        } else {
            set_style(&w, Style.Bold)
            set_fg(&w, Color.Yellow)
            sb.append("Black")
            reset(&w)
            sb.append(" to move")
        }
        println(sb.as_view())
    }
}

pub fn main() i32 {
    let sb = string_builder_with_capacity(64)
    let w = sb.writer()

    set_style(&w, Style.Bold)
    set_fg(&w, Color.Cyan)
    sb.append("♚ FEN Chess Board Display ♔")
    reset(&w)
    println(sb.as_view())
    sb.deinit()

    println("")

    println("=== Starting Position ===")
    println("")
    display_board("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")

    println("")

    println("=== Sicilian Defense ===")
    println("")
    display_board("rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2")

    println("")

    println("=== Scholar's Mate ===")
    println("")
    display_board("r1bqkb1r/pppp1Qpp/2n2n2/4p3/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 1 4")

    return 0
}
