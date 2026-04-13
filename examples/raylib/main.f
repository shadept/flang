// Raylib demo — demonstrates FLang's C FFI binding generation.
//
// Build (macOS with Homebrew):
//   brew install raylib
//   flang -I $(brew --prefix raylib)/include/raylib.h \
//         -L $(brew --prefix raylib)/lib/libraylib.a \
//         --link "-framework CoreVideo" \
//         --link "-framework IOKit" \
//         --link "-framework Cocoa" \
//         --link "-framework GLUT" \
//         --link "-framework OpenGL" \
//         main.f

import vendor.raylib

const SCREEN_WIDTH: i32 = 800
const SCREEN_HEIGHT: i32 = 450

type State = struct {
    ball_x: f32,
    ball_y: f32,
}

fn update(s: &State) {
    let dt = GetFrameTime()
    let speed: f32 = 200.0
    if IsKeyDown(KEY_RIGHT) { s.ball_x = s.ball_x + speed * dt }
    if IsKeyDown(KEY_LEFT)  { s.ball_x = s.ball_x - speed * dt }
    if IsKeyDown(KEY_DOWN)  { s.ball_y = s.ball_y + speed * dt }
    if IsKeyDown(KEY_UP)    { s.ball_y = s.ball_y - speed * dt }
}

fn draw(s: &State, bg: Color, ball_color: Color, rect_color: Color, text_color: Color) {
    let rect = Rectangle { x = 50.0, y = 50.0, width = 120.0, height = 60.0 }

    BeginDrawing()
    ClearBackground(bg)
    DrawRectangleRec(rect, rect_color)
    DrawCircle(s.ball_x as i32, s.ball_y as i32, 20.0, ball_color)
    DrawText("FLang + Raylib FFI Demo".ptr, 10, 10, 20, text_color)
    DrawText("Move the ball with arrow keys!".ptr, 10, 420, 20, text_color)
    EndDrawing()
}

pub fn main() i32 {
    InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "FLang + Raylib".ptr)
    SetTargetFPS(60)

    let state = State { ball_x = 400.0, ball_y = 225.0 }
    let bg = Color { r = 245, g = 245, b = 245, a = 255 }
    let ball_color = Color { r = 230, g = 41, b = 55, a = 255 }
    let rect_color = Color { r = 0, g = 121, b = 241, a = 255 }
    let text_color = Color { r = 100, g = 100, b = 100, a = 255 }

    loop {
        if WindowShouldClose() { break }
        update(&state)
        draw(&state, bg, ball_color, rect_color, text_color)
    }

    CloseWindow()
    return 0
}
