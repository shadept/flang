import std.allocator
import std.string_builder

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

fn display_board(fen: String) {
    const buf = [0; 80]
    const fba = fixed_buffer_allocator(buf)
    const alloc = fba.allocator()

    let sb = string_builder_with_capacity_and_allocator(80, &alloc)
    defer sb.deinit()

    const top = "  ┌───┬───┬───┬───┬───┬───┬───┬───┐"
    const mid = "  ├───┼───┼───┼───┼───┼───┼───┼───┤"
    const bot = "  └───┴───┴───┴───┴───┴───┴───┴───┘"

    println(top)

    let rank: i32 = 8
    sb.append(rank)
    sb.append(" │")

    let pos: usize = 0
    loop {
        if pos >= fen.len { break }

        const ch = fen[pos]

        if ch == b' ' {
            break
        } else if ch == b'/' {
            println(sb.as_view())
            println(mid)
            sb.clear()
            rank = rank - 1
            sb.append(rank)
            sb.append(" │")
        } else if ch >= b'1' and ch <= b'8' {
            const count = (ch - b'0') as i32
            for (j in 0..count) {
                sb.append("   │")
            }
        } else {
            sb.append(" ")
            sb.append_piece(ch)
            sb.append(" │")
        }

        pos = pos + 1
    }

    println(sb.as_view())
    println(bot)
    println("    a   b   c   d   e   f   g   h")

    // Display side to move
    pos = pos + 1
    if (pos < fen.len) {
        print("  ")
        if (fen[pos] == b'w') {
            println("White to move")
        } else {
            println("Black to move")
        }
    }
}

pub fn main() i32 {
    println("♚ FEN Chess Board Display ♔")
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
