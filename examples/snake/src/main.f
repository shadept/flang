// Snake game — demonstrates terminal control, raw input, and game loops.
//
// Controls: WASD or arrow keys to move, Q to quit.
// If interrupted with Ctrl+C, run `reset` to restore terminal settings.

import std.string_builder
import std.io.writer
import std.terminal
import std.mem

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

// =============================================================================
// Helpers
// =============================================================================

fn rand_range(lo: i32, hi: i32) i32 {
    return lo + snake_random_upper((hi - lo) as u32) as i32
}

fn flush_output(sb: &StringBuilder) {
    let view = sb.as_view()
    snake_write_stdout(view.ptr, view.len)
    sb.clear()
}

// =============================================================================
// Entry point
// =============================================================================

pub fn main() i32 {
    snake_enter_raw_mode()
    defer snake_exit_raw_mode()

    // --- Output buffer ---
    let sb = string_builder(8192)
    defer sb.deinit()
    let w = sb.writer()

    hide_cursor(w)
    clear_screen(w)
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
        let n = snake_read_key(input.ptr, 3) as isize

        if n == 1 {
            if input[0] == 'q' or input[0] == 'Q' { break }
            if input[0] == 'w' or input[0] == 'W' {
                if dir != DIR_DOWN { dir = DIR_UP }
            }
            if input[0] == 's' or input[0] == 'S' {
                if dir != DIR_UP { dir = DIR_DOWN }
            }
            if input[0] == 'a' or input[0] == 'A' {
                if dir != DIR_RIGHT { dir = DIR_LEFT }
            }
            if input[0] == 'd' or input[0] == 'D' {
                if dir != DIR_LEFT { dir = DIR_RIGHT }
            }
        }
        if n == 3 and input[0] == 27 and input[1] == '[' {
            if input[2] == 'A' and dir != DIR_DOWN { dir = DIR_UP }
            if input[2] == 'B' and dir != DIR_UP { dir = DIR_DOWN }
            if input[2] == 'D' and dir != DIR_RIGHT { dir = DIR_LEFT }
            if input[2] == 'C' and dir != DIR_LEFT { dir = DIR_RIGHT }
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
        while t > 0 {
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

        move_to(w, 1, 1)

        // Title bar
        sb.append("  ")
        set_style(w, Style.Bold)
        set_fg(w, Color.Yellow)
        sb.append("SNAKE")
        reset(w)
        sb.append("  Score: ")
        set_style(w, Style.Bold)
        sb.append(score)
        reset(w)
        clear_line_right(w)
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
                    set_fg(w, Color.Green)
                    set_style(w, Style.Bold)
                    sb.append("██")
                    reset(w)
                } else if cell == CELL_BODY {
                    set_fg(w, Color.Green)
                    sb.append("░░")
                    reset(w)
                } else if cell == CELL_FOOD {
                    set_fg(w, Color.Red)
                    set_style(w, Style.Bold)
                    sb.append("██")
                    reset(w)
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
        set_style(w, Style.Dim)
        sb.append("  WASD/Arrows: move  Q: quit")
        reset(w)
        clear_line_right(w)

        // Flush frame
        flush_output(&sb)

        snake_sleep_us(120000) // ~120ms per frame
    }

    // --- Cleanup ---
    show_cursor(w)
    reset(w)
    clear_screen(w)
    move_to(w, 1, 1)
    flush_output(&sb)

    // Game over message
    set_fg(w, Color.Red)
    set_style(w, Style.Bold)
    sb.append("Game Over!")
    reset(w)
    sb.append(" Final score: ")
    sb.append(score)
    sb.append("\n")
    flush_output(&sb)

    return 0
}
