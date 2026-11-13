// Hand-written subset of the SDL 3.4 API.

pub const SDL_INIT_VIDEO: u32 = 0x20
pub const SDL_EVENT_QUIT: u32 = 0x100

pub const SDL_SCANCODE_ESCAPE: usize = 41
pub const SDL_SCANCODE_RIGHT: usize = 79
pub const SDL_SCANCODE_LEFT: usize = 80
pub const SDL_SCANCODE_DOWN: usize = 81
pub const SDL_SCANCODE_UP: usize = 82

// SDL_Event is a 128-byte union; every variant starts with its event type.
pub type SDL_Event = #foreign struct {
    kind: u32
    rest: [u8; 124]
}

pub type SDL_FRect = #foreign struct {
    x: f32
    y: f32
    w: f32
    h: f32
}

#foreign pub fn SDL_Init(flags: u32) bool
#foreign pub fn SDL_Quit()
#foreign pub fn SDL_GetError() &u8
#foreign pub fn SDL_GetTicks() u64

#foreign pub fn SDL_CreateWindow(title: &u8, w: i32, h: i32, flags: u64) &u8?
#foreign pub fn SDL_DestroyWindow(window: &u8)

#foreign pub fn SDL_CreateRenderer(window: &u8, name: &u8?) &u8?
#foreign pub fn SDL_DestroyRenderer(renderer: &u8)
#foreign pub fn SDL_SetRenderVSync(renderer: &u8, vsync: i32) bool
#foreign pub fn SDL_SetRenderDrawColor(renderer: &u8, r: u8, g: u8, b: u8, a: u8) bool
#foreign pub fn SDL_RenderClear(renderer: &u8) bool
#foreign pub fn SDL_RenderFillRect(renderer: &u8, rect: &SDL_FRect) bool
#foreign pub fn SDL_RenderDebugText(renderer: &u8, x: f32, y: f32, text: &u8) bool
#foreign pub fn SDL_RenderPresent(renderer: &u8) bool

#foreign pub fn SDL_PollEvent(event: &SDL_Event) bool
#foreign pub fn SDL_GetKeyboardState(numkeys: &i32) &bool
