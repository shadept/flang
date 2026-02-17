// Snake game — demonstrates terminal control, raw input, and game loops.
//
// Controls: WASD or arrow keys to move, Q to quit.
// If interrupted with Ctrl+C, run `reset` to restore terminal settings.

import std.string_builder
import std.io.writer
import std.terminal
import std.mem

// =============================================================================
// Foreign functions (POSIX + C stdlib)
// =============================================================================

#foreign fn ioctl(fd: i32, request: u64, argp: &u8) i32
#foreign fn read(fd: i32, buf: &u8, count: usize) isize
#foreign fn write(fd: i32, buf: &u8, count: usize) isize
#foreign fn usleep(usec: u32) i32
#foreign fn arc4random_uniform(upper_bound: u32) u32

// =============================================================================
// Constants
// =============================================================================

const BOARD_W: i32 = 20
const BOARD_H: i32 = 15

// Direction tags
const DIR_UP: i32 = 0
const DIR_DOWN: i32 = 1
const DIR_LEFT: i32 = 2
const DIR_RIGHT: i32 = 3

// Grid cell tags
const CELL_EMPTY: u8 = 0
const CELL_FOOD: u8 = 1
const CELL_BODY: u8 = 2
const CELL_HEAD: u8 = 3

// macOS arm64 termios layout (72 bytes):
//   offset  0: c_iflag  (u64)
//   offset  8: c_oflag  (u64)
//   offset 16: c_cflag  (u64)
//   offset 24: c_lflag  (u64)
//   offset 32: c_cc[20] (20 bytes)
//   offset 52: padding  (4 bytes)
//   offset 56: c_ispeed (u64)
//   offset 64: c_ospeed (u64)

// ioctl requests for terminal attributes (macOS arm64)
const TIOCGETA: u64 = 0x40487413  // get termios
const TIOCSETA: u64 = 0x80487414  // set termios

// ~(ICANON 0x100 | ECHO 0x8) pre-computed AND mask for c_lflag
const LFLAG_MASK: u64 = 0xFFFF_FFFF_FFFF_FEF7

// =============================================================================
// Helpers
// =============================================================================

fn rand_range(lo: i32, hi: i32) i32 {
    return lo + arc4random_uniform((hi - lo) as u32) as i32
}

fn flush_output(sb: &StringBuilder) {
    let view = sb.as_view()
    write(1, view.ptr, view.len)
    sb.clear()
}

// =============================================================================
// Entry point
// =============================================================================

pub fn main() i32 {
    // --- Raw terminal mode (macOS arm64 termios: 72 bytes) ---
    let old_term = [0u8; 72]
    let new_term = [0u8; 72]
    ioctl(0, TIOCGETA, old_term.ptr)
    memcpy(new_term.ptr, old_term.ptr, 72)

    // Clear ICANON and ECHO in c_lflag (offset 24)
    let lflag = (new_term.ptr + 24usize) as &u64
    lflag.* = lflag.* & LFLAG_MASK

    // VMIN=0, VTIME=0: non-blocking reads (c_cc[16], c_cc[17])
    let vmin = new_term.ptr + 48usize
    vmin.* = 0
    let vtime = new_term.ptr + 49usize
    vtime.* = 0

    ioctl(0, TIOCSETA, new_term.ptr)

    // --- Output buffer ---
    let sb = string_builder(8192)
    defer sb.deinit()
    let w = sb.writer()

    hide_cursor(&w)
    clear_screen(&w)
    flush_output(&sb)

    // --- Game state ---
    let sx = [0i32; 300]
    let sy = [0i32; 300]
    let slen: i32 = 3
    let dir: i32 = DIR_RIGHT
    let score: i32 = 0
    let game_over = false

    // Start in the middle
    sx[0] = BOARD_W / 2
    sy[0] = BOARD_H / 2
    sx[1] = BOARD_W / 2 - 1
    sy[1] = BOARD_H / 2
    sx[2] = BOARD_W / 2 - 2
    sy[2] = BOARD_H / 2

    let food_x = rand_range(0, BOARD_W)
    let food_y = rand_range(0, BOARD_H)

    // Render grid (BOARD_W * BOARD_H = 300 cells)
    let grid = [0u8; 300]

    // === Game loop ===
    loop {
        if game_over { break }

        // --- Input (non-blocking) ---
        let input = [0u8; 3]
        let n = read(0, input.ptr, 3)

        if n == 1 {
            if input[0] == b'q' or input[0] == b'Q' { break }
            if input[0] == b'w' or input[0] == b'W' {
                if dir != DIR_DOWN { dir = DIR_UP }
            }
            if input[0] == b's' or input[0] == b'S' {
                if dir != DIR_UP { dir = DIR_DOWN }
            }
            if input[0] == b'a' or input[0] == b'A' {
                if dir != DIR_RIGHT { dir = DIR_LEFT }
            }
            if input[0] == b'd' or input[0] == b'D' {
                if dir != DIR_LEFT { dir = DIR_RIGHT }
            }
        }
        if n == 3 and input[0] == 27 and input[1] == b'[' {
            if input[2] == b'A' and dir != DIR_DOWN { dir = DIR_UP }
            if input[2] == b'B' and dir != DIR_UP { dir = DIR_DOWN }
            if input[2] == b'D' and dir != DIR_RIGHT { dir = DIR_LEFT }
            if input[2] == b'C' and dir != DIR_LEFT { dir = DIR_RIGHT }
        }

        // --- Move ---
        let hx = sx[0]
        let hy = sy[0]
        if dir == DIR_UP { hy = hy - 1 }
        else if dir == DIR_DOWN { hy = hy + 1 }
        else if dir == DIR_LEFT { hx = hx - 1 }
        else { hx = hx + 1 }

        // Wall collision
        if hx < 0 or hx >= BOARD_W or hy < 0 or hy >= BOARD_H {
            game_over = true
            break
        }

        // Self collision
        for (i in 0..slen) {
            if sx[i as usize] == hx and sy[i as usize] == hy {
                game_over = true
            }
        }
        if game_over { break }

        // Eat food?
        let ate = hx == food_x and hy == food_y

        // Shift body (from tail toward head)
        let t: i32 = if ate { slen } else { slen - 1 }
        loop {
            if t <= 0 { break }
            sx[t as usize] = sx[(t - 1) as usize]
            sy[t as usize] = sy[(t - 1) as usize]
            t = t - 1
        }
        sx[0] = hx
        sy[0] = hy

        if ate {
            slen = slen + 1
            score = score + 10
            // Place food somewhere not on the snake
            loop {
                food_x = rand_range(0, BOARD_W)
                food_y = rand_range(0, BOARD_H)
                let ok = true
                for (j in 0..slen) {
                    if sx[j as usize] == food_x and sy[j as usize] == food_y {
                        ok = false
                    }
                }
                if ok { break }
            }
        }

        // --- Render ---
        // Populate grid
        memset(grid.ptr, 0, 300)
        grid[(food_y * BOARD_W + food_x) as usize] = CELL_FOOD
        for (i in 1..slen) {
            grid[(sy[i as usize] * BOARD_W + sx[i as usize]) as usize] = CELL_BODY
        }
        grid[(sy[0] * BOARD_W + sx[0]) as usize] = CELL_HEAD

        move_to(&w, 1, 1)

        // Title bar
        sb.append("  ")
        set_style(&w, Style.Bold)
        set_fg(&w, Color.Yellow)
        sb.append("SNAKE")
        reset(&w)
        sb.append("  Score: ")
        set_style(&w, Style.Bold)
        sb.append(score)
        reset(&w)
        clear_line_right(&w)
        sb.append("\n")

        // Top border
        sb.append("  ┌")
        for (c in 0..BOARD_W) {
            sb.append("──")
        }
        sb.append("┐\n")

        // Board rows
        for (row in 0..BOARD_H) {
            sb.append("  │")
            for (col in 0..BOARD_W) {
                const cell = grid[(row * BOARD_W + col) as usize]
                if cell == CELL_HEAD {
                    set_fg(&w, Color.Green)
                    set_style(&w, Style.Bold)
                    sb.append("██")
                    reset(&w)
                } else if cell == CELL_BODY {
                    set_fg(&w, Color.Green)
                    sb.append("░░")
                    reset(&w)
                } else if cell == CELL_FOOD {
                    set_fg(&w, Color.Red)
                    set_style(&w, Style.Bold)
                    sb.append("██")
                    reset(&w)
                } else {
                    sb.append("  ")
                }
            }
            sb.append("│\n")
        }

        // Bottom border
        sb.append("  └")
        for (c in 0..BOARD_W) {
            sb.append("──")
        }
        sb.append("┘\n")

        // Controls hint
        set_style(&w, Style.Dim)
        sb.append("  WASD/Arrows: move  Q: quit")
        reset(&w)
        clear_line_right(&w)

        // Flush frame
        flush_output(&sb)

        usleep(120000) // ~120ms per frame
    }

    // --- Cleanup ---
    show_cursor(&w)
    reset(&w)
    clear_screen(&w)
    move_to(&w, 1, 1)
    flush_output(&sb)

    // Restore terminal
    ioctl(0, TIOCSETA, old_term.ptr)

    // Game over message
    set_fg(&w, Color.Red)
    set_style(&w, Style.Bold)
    sb.append("Game Over!")
    reset(&w)
    sb.append(" Final score: ")
    sb.append(score)
    sb.append("\n")
    flush_output(&sb)

    return 0
}
