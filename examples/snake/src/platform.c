// Platform shim for the snake example. Keeps main.f portable by hiding the
// raw terminal / sleep / RNG differences between POSIX and Windows behind a
// small function surface.

#include <stdint.h>
#include <stdlib.h>

#ifdef _WIN32

#include <windows.h>
#include <conio.h>

static HANDLE snake_stdin;
static HANDLE snake_stdout;
static DWORD snake_old_in_mode;
static DWORD snake_old_out_mode;

void snake_enter_raw_mode(void) {
    snake_stdin = GetStdHandle(STD_INPUT_HANDLE);
    snake_stdout = GetStdHandle(STD_OUTPUT_HANDLE);
    GetConsoleMode(snake_stdin, &snake_old_in_mode);
    GetConsoleMode(snake_stdout, &snake_old_out_mode);

    DWORD in_mode = snake_old_in_mode
        & ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT);
    SetConsoleMode(snake_stdin, in_mode);

    // Snake draws via ANSI escapes; Windows needs this opt-in.
    SetConsoleMode(snake_stdout,
        snake_old_out_mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
}

void snake_exit_raw_mode(void) {
    SetConsoleMode(snake_stdin, snake_old_in_mode);
    SetConsoleMode(snake_stdout, snake_old_out_mode);
}

void snake_sleep_us(uint32_t us) {
    // Windows Sleep is millisecond-granular; round to at least 1 ms.
    DWORD ms = us / 1000;
    Sleep(ms == 0 ? 1 : ms);
}

// Non-blocking. Drains whatever input is available (up to `max` bytes) and
// translates Windows-extended arrow keys into the ANSI ESC-[-A/B/C/D
// sequences main.f already parses.
int snake_read_key(uint8_t* buf, int max) {
    int n = 0;
    while (n < max && _kbhit()) {
        int c = _getch();
        if ((c == 0x00 || c == 0xe0) && _kbhit() && n + 3 <= max) {
            int sc = _getch();
            char mapped = 0;
            switch (sc) {
                case 72: mapped = 'A'; break; // up
                case 80: mapped = 'B'; break; // down
                case 75: mapped = 'D'; break; // left
                case 77: mapped = 'C'; break; // right
                default: break;
            }
            if (mapped != 0) {
                buf[n++] = 27;
                buf[n++] = '[';
                buf[n++] = (uint8_t)mapped;
            }
        } else {
            buf[n++] = (uint8_t)c;
        }
    }
    return n;
}

#else  // POSIX

#include <unistd.h>
#include <termios.h>

static struct termios snake_old_term;

void snake_enter_raw_mode(void) {
    tcgetattr(0, &snake_old_term);
    struct termios new_term = snake_old_term;
    new_term.c_lflag &= ~(ICANON | ECHO);
    new_term.c_cc[VMIN] = 0;
    new_term.c_cc[VTIME] = 0;
    tcsetattr(0, TCSANOW, &new_term);
}

void snake_exit_raw_mode(void) {
    tcsetattr(0, TCSANOW, &snake_old_term);
}

void snake_sleep_us(uint32_t us) {
    usleep(us);
}

int snake_read_key(uint8_t* buf, int max) {
    ssize_t n = read(0, buf, (size_t)max);
    return n > 0 ? (int)n : 0;
}

#endif

// Shared: portable stdout write. `printf` would drag CRLF translation on
// Windows and mangle ANSI frames; `write`/`WriteFile` on the raw stdout
// handle keeps bytes intact.
#ifdef _WIN32
void snake_write_stdout(const uint8_t* buf, uintptr_t len) {
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    DWORD written = 0;
    WriteFile(out, buf, (DWORD)len, &written, NULL);
}
#else
void snake_write_stdout(const uint8_t* buf, uintptr_t len) {
    ssize_t _ignored = write(1, buf, (size_t)len);
    (void)_ignored;
}
#endif

// Shared: portable RNG. Seeds once from `time(NULL)` on first call so we
// don't need a dedicated init step.
#include <time.h>

uint32_t snake_random_upper(uint32_t upper) {
    static int seeded = 0;
    if (!seeded) {
        srand((unsigned)time(NULL));
        seeded = 1;
    }
    if (upper == 0) return 0;
    return (uint32_t)rand() % upper;
}
