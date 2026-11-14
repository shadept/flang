import std.io.print
import std.option

import vendor.SDL

const WIDTH: i32 = 800
const HEIGHT: i32 = 450
const SPEED: f32 = 300.0

type State = struct {
    x: f32
    y: f32
    keys: bool[]
}

fn update(s: &State, dt: f32) {
    if s.keys[SDL_SCANCODE_RIGHT as usize] {
        s.x = s.x + SPEED * dt
    }
    if s.keys[SDL_SCANCODE_LEFT as usize] {
        s.x = s.x - SPEED * dt
    }
    if s.keys[SDL_SCANCODE_DOWN as usize] {
        s.y = s.y + SPEED * dt
    }
    if s.keys[SDL_SCANCODE_UP as usize] {
        s.y = s.y - SPEED * dt
    }
}

fn draw(r: &SDL_Renderer, s: &State) {
    SDL_SetRenderDrawColor(Some(r), 245, 245, 245, 255)
    SDL_RenderClear(Some(r))
    SDL_SetRenderDrawColor(Some(r), 230, 41, 55, 255)
    let box = SDL_FRect { x = s.x, y = s.y, w = 40.0, h = 40.0 }
    SDL_RenderFillRect(Some(r), Some(&box))
    SDL_SetRenderDrawColor(Some(r), 100, 100, 100, 255)
    SDL_RenderDebugText(Some(r), 10.0, 10.0, Some("FLang + SDL3: arrows move, Esc quits".ptr))
    SDL_RenderPresent(Some(r))
}

// True once the window is closed or Escape is held.
fn should_quit(s: &State) bool {
    let ev: SDL_Event
    while SDL_PollEvent(Some(&ev)) {
        if ev.type_ == SDL_EVENT_QUIT as u32 {
            return true
        }
    }
    return s.keys[SDL_SCANCODE_ESCAPE as usize]
}

fn run(r: &SDL_Renderer) {
    let numkeys: i32 = 0
    const keys = SDL_GetKeyboardState(Some(&numkeys)).unwrap()
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

    const window = SDL_CreateWindow(Some("FLang + SDL3".ptr), WIDTH, HEIGHT, 0) match {
        Some(w) => w
        None => {
            println("SDL_CreateWindow failed")
            return 1
        }
    }
    defer SDL_DestroyWindow(Some(window))

    const renderer = SDL_CreateRenderer(Some(window), null) match {
        Some(r) => r
        None => {
            println("SDL_CreateRenderer failed")
            return 1
        }
    }
    defer SDL_DestroyRenderer(Some(renderer))

    SDL_SetRenderVSync(Some(renderer), 1)
    run(renderer)
    return 0
}
