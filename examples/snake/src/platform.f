// Platform shim for snake — see platform.c for the POSIX / Windows bodies.

#foreign pub fn snake_enter_raw_mode()
#foreign pub fn snake_exit_raw_mode()
#foreign pub fn snake_sleep_us(us: u32)
#foreign pub fn snake_read_key(buf: &u8, max: i32) i32
#foreign pub fn snake_random_upper(upper: u32) u32
#foreign pub fn snake_write_stdout(buf: &u8, len: usize)
