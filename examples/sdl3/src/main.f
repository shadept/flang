import std.io.print

import sdl3.sdl

const WIDTH: i32 = 800
const HEIGHT: i32 = 450
const SPEED: f32 = 300.0

type State = struct {
    x: f32
    y: f32
    keys: bool[]
}

fn update(s: &State, dt: f32) {
    if s.keys[SDL_SCANCODE_RIGHT] {
        s.x = s.x + SPEED * dt
    }
    if s.keys[SDL_SCANCODE_LEFT] {
        s.x = s.x - SPEED * dt
    }
    if s.keys[SDL_SCANCODE_DOWN] {
        s.y = s.y + SPEED * dt
    }
    if s.keys[SDL_SCANCODE_UP] {
        s.y = s.y - SPEED * dt
    }
}

fn draw(r: &u8, s: &State) {
    SDL_SetRenderDrawColor(r, 245, 245, 245, 255)
    SDL_RenderClear(r)
    SDL_SetRenderDrawColor(r, 230, 41, 55, 255)
    let box = SDL_FRect { x = s.x, y = s.y, w = 40.0, h = 40.0 }
    SDL_RenderFillRect(r, &box)
    SDL_SetRenderDrawColor(r, 100, 100, 100, 255)
    SDL_RenderDebugText(r, 10.0, 10.0, "FLang + SDL3: arrows move, Esc quits".ptr)
    SDL_RenderPresent(r)
}

// True once the window is closed or Escape is held.
fn should_quit(s: &State) bool {
    let ev: SDL_Event
    while SDL_PollEvent(&ev) {
        if ev.kind == SDL_EVENT_QUIT {
            return true
        }
    }
    return s.keys[SDL_SCANCODE_ESCAPE]
}

fn run(r: &u8) {
    let numkeys: i32 = 0
    let keys = SDL_GetKeyboardState(&numkeys)
    let s = State { x = 380.0, y = 200.0, keys = slice_from_raw_parts(keys, numkeys as usize) }

    let last = SDL_GetTicks()
    while !should_quit(&s) {
        const now = SDL_GetTicks()
        update(&s, (now - last) as f32 / 1000.0)
        last = now
        draw(r, &s)
    }
}

pub fn main() i32 {
    if !SDL_Init(SDL_INIT_VIDEO) {
        println("SDL_Init failed")
        return 1
    }
    defer SDL_Quit()

    const window = SDL_CreateWindow("FLang + SDL3".ptr, WIDTH, HEIGHT, 0) match {
        Some(w) => w
        None => {
            println("SDL_CreateWindow failed")
            return 1
        }
    }
    defer SDL_DestroyWindow(window)

    const renderer = SDL_CreateRenderer(window, null) match {
        Some(r) => r
        None => {
            println("SDL_CreateRenderer failed")
            return 1
        }
    }
    defer SDL_DestroyRenderer(renderer)

    SDL_SetRenderVSync(renderer, 1)
    run(renderer)
    return 0
}
