/* std.runtime.coro - stackful coroutines scheduled on the calling thread.
 *
 * One worker: the run loop drives every runnable coroutine on the thread that
 * calls it and returns once none is runnable. Each coroutine owns a stack
 * reserved up front with a guard page at its low end; the OS commits pages as
 * they are touched, and the stack never grows or moves.
 *
 * Windows: Fibers. POSIX: an mmap reservation and a hand-written switch for
 * x86_64 and arm64.
 */

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <sys/mman.h>
#include <unistd.h>
#endif

#define CORO_DEFAULT_STACK ((size_t)1 << 20)
#define CORO_MIN_STACK ((size_t)64 << 10)

enum { CORO_RUNNABLE, CORO_RUNNING, CORO_PARKED, CORO_DONE };

typedef struct FlangCoro FlangCoro;

struct FlangCoro {
    void (*entry)(void*);
    void* arg;
    int state;
    /* A wake that found the coroutine not parked; its next park returns at once. */
    int wake_pending;
    FlangCoro* next;
#ifdef _WIN32
    void* fiber;
#else
    void* sp;         /* saved stack pointer while suspended */
    void* stack;      /* mapping base, guard page included */
    size_t stack_len; /* mapping length */
#endif
};

static struct {
    FlangCoro* head;
    FlangCoro* tail;
    FlangCoro* current;
#ifdef _WIN32
    void* fiber;
#else
    void* sp;
#endif
} sched;

static void coro_fatal(const char* msg) {
    fprintf(stderr, "fatal: %s\n", msg);
    abort();
}

static void enqueue(FlangCoro* c) {
    c->state = CORO_RUNNABLE;
    c->next = NULL;
    if (sched.tail) {
        sched.tail->next = c;
    } else {
        sched.head = c;
    }
    sched.tail = c;
}

static FlangCoro* dequeue(void) {
    FlangCoro* c = sched.head;
    if (!c) {
        return NULL;
    }
    sched.head = c->next;
    if (!sched.head) {
        sched.tail = NULL;
    }
    c->next = NULL;
    return c;
}

#ifdef _WIN32

static size_t page_size(void) {
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    return (size_t)si.dwPageSize;
}

static VOID CALLBACK fiber_main(LPVOID p) {
    FlangCoro* c = (FlangCoro*)p;
    c->entry(c->arg);
    c->state = CORO_DONE;
    /* The run loop deletes a finished fiber without resuming it. */
    SwitchToFiber(sched.fiber);
}

/* CreateFiberEx reserves the stack with a guard page, as for a thread. */
static void stack_init(FlangCoro* c, size_t size) {
    c->fiber = CreateFiberEx(0, size, FIBER_FLAG_FLOAT_SWITCH, fiber_main, c);
    if (!c->fiber) {
        coro_fatal("cannot reserve a coroutine stack");
    }
}

static void stack_release(FlangCoro* c) {
    DeleteFiber(c->fiber);
    c->fiber = NULL;
}

static void switch_in(FlangCoro* c) {
    SwitchToFiber(c->fiber);
}

static void switch_out(FlangCoro* c) {
    (void)c;
    SwitchToFiber(sched.fiber);
}

/* Returns whether the thread was converted, so the caller converts it back. */
static int sched_enter(void) {
    if (IsThreadAFiber()) {
        sched.fiber = GetCurrentFiber();
        return 0;
    }
    sched.fiber = ConvertThreadToFiberEx(NULL, FIBER_FLAG_FLOAT_SWITCH);
    if (!sched.fiber) {
        coro_fatal("cannot start the coroutine scheduler");
    }
    return 1;
}

static void sched_leave(int converted) {
    if (converted) {
        ConvertFiberToThread();
    }
    sched.fiber = NULL;
}

#else /* POSIX */

/* Saves the callee-saved registers on the current stack, stores the stack
 * pointer through the first argument, loads the second as the stack pointer,
 * restores the registers saved there and returns into that context. A new
 * coroutine's stack is laid out so that this return enters coro_main. */
void flang_coro_switch(void** save_sp, void* load_sp);

#if defined(__APPLE__)
#define CORO_SYM "_flang_coro_switch"
#define CORO_HIDE ".private_extern " CORO_SYM "\n"
#else
#define CORO_SYM "flang_coro_switch"
#define CORO_HIDE ".hidden " CORO_SYM "\n"
#endif

#if defined(__x86_64__)

/* System V: rbx, rbp and r12-r15 are callee-saved, as are the MXCSR control
 * bits and the x87 control word, kept together in one 8-byte slot. */
__asm__(
    ".text\n"
    ".p2align 4\n"
    ".globl " CORO_SYM "\n"
    CORO_HIDE
    CORO_SYM ":\n"
    "    pushq %rbp\n"
    "    pushq %rbx\n"
    "    pushq %r12\n"
    "    pushq %r13\n"
    "    pushq %r14\n"
    "    pushq %r15\n"
    "    subq $8, %rsp\n"
    "    stmxcsr (%rsp)\n"
    "    fnstcw 4(%rsp)\n"
    "    movq %rsp, (%rdi)\n"
    "    movq %rsi, %rsp\n"
    "    ldmxcsr (%rsp)\n"
    "    fldcw 4(%rsp)\n"
    "    addq $8, %rsp\n"
    "    popq %r15\n"
    "    popq %r14\n"
    "    popq %r13\n"
    "    popq %r12\n"
    "    popq %rbx\n"
    "    popq %rbp\n"
    "    ret\n");

/* Slots below the top, low to high: control word, r15, r14, r13, r12, rbx,
 * rbp, the return address, and a null return address for coro_main's own
 * frame, which leaves the stack aligned as at any call. */
static void* frame_init(char* top, void (*start)(void)) {
    uint64_t* f = (uint64_t*)top - 9;
    for (int i = 0; i < 9; i++) {
        f[i] = 0;
    }
    f[0] = 0x1F80u | ((uint64_t)0x037Fu << 32); /* power-on MXCSR and x87 control word */
    f[7] = (uint64_t)(uintptr_t)start;
    return f;
}

#elif defined(__aarch64__)

/* AAPCS64: x19-x28, the frame pointer, the link register and d8-d15 are
 * callee-saved. x18 is reserved on Apple platforms and left alone. */
__asm__(
    ".text\n"
    ".p2align 4\n"
    ".globl " CORO_SYM "\n"
    CORO_HIDE
    CORO_SYM ":\n"
    "    sub sp, sp, #160\n"
    "    stp x19, x20, [sp, #0]\n"
    "    stp x21, x22, [sp, #16]\n"
    "    stp x23, x24, [sp, #32]\n"
    "    stp x25, x26, [sp, #48]\n"
    "    stp x27, x28, [sp, #64]\n"
    "    stp x29, x30, [sp, #80]\n"
    "    stp d8, d9, [sp, #96]\n"
    "    stp d10, d11, [sp, #112]\n"
    "    stp d12, d13, [sp, #128]\n"
    "    stp d14, d15, [sp, #144]\n"
    "    mov x2, sp\n"
    "    str x2, [x0]\n"
    "    mov sp, x1\n"
    "    ldp x19, x20, [sp, #0]\n"
    "    ldp x21, x22, [sp, #16]\n"
    "    ldp x23, x24, [sp, #32]\n"
    "    ldp x25, x26, [sp, #48]\n"
    "    ldp x27, x28, [sp, #64]\n"
    "    ldp x29, x30, [sp, #80]\n"
    "    ldp d8, d9, [sp, #96]\n"
    "    ldp d10, d11, [sp, #112]\n"
    "    ldp d12, d13, [sp, #128]\n"
    "    ldp d14, d15, [sp, #144]\n"
    "    add sp, sp, #160\n"
    "    ret\n");

/* Twenty zeroed slots below the top; the link register's slot holds the entry,
 * and a null frame pointer ends the frame chain. */
static void* frame_init(char* top, void (*start)(void)) {
    uint64_t* f = (uint64_t*)top - 20;
    for (int i = 0; i < 20; i++) {
        f[i] = 0;
    }
    f[11] = (uint64_t)(uintptr_t)start;
    return f;
}

#else
#error "std.runtime.coro: no context switch for this architecture"
#endif

static size_t page_size(void) {
    return (size_t)sysconf(_SC_PAGESIZE);
}

static void coro_main(void) {
    FlangCoro* c = sched.current;
    c->entry(c->arg);
    c->state = CORO_DONE;
    /* The run loop unmaps a finished stack without resuming it. */
    flang_coro_switch(&c->sp, sched.sp);
    abort();
}

static void stack_init(FlangCoro* c, size_t size) {
    size_t page = page_size();
    size_t len = size + page;
    void* base = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (base == MAP_FAILED) {
        coro_fatal("cannot reserve a coroutine stack");
    }
    if (mprotect(base, page, PROT_NONE) != 0) {
        coro_fatal("cannot protect a coroutine stack's guard page");
    }
    c->stack = base;
    c->stack_len = len;
    c->sp = frame_init((char*)base + len, coro_main);
}

static void stack_release(FlangCoro* c) {
    munmap(c->stack, c->stack_len);
    c->stack = NULL;
}

static void switch_in(FlangCoro* c) {
    flang_coro_switch(&sched.sp, c->sp);
}

static void switch_out(FlangCoro* c) {
    flang_coro_switch(&c->sp, sched.sp);
}

static int sched_enter(void) {
    return 0;
}

static void sched_leave(int converted) {
    (void)converted;
}

#endif

static size_t stack_size_for(size_t requested) {
    size_t s = requested == 0 ? CORO_DEFAULT_STACK : requested;
    if (s < CORO_MIN_STACK) {
        s = CORO_MIN_STACK;
    }
    size_t page = page_size();
    return (s + page - 1) / page * page;
}

static FlangCoro* require_current(const char* op) {
    if (!sched.current) {
        fprintf(stderr, "fatal: coroutine %s outside a coroutine\n", op);
        abort();
    }
    return sched.current;
}

/* errno belongs to the coroutine, not the thread it happens to run on. */
static void suspend(FlangCoro* c) {
    int saved = errno;
    switch_out(c);
    errno = saved;
}

/* A zero stack size picks the default. The coroutine first runs inside the run loop. */
FlangCoro* __flang_coro_spawn(void (*entry)(void*), void* arg, size_t stack_size) {
    FlangCoro* c = (FlangCoro*)calloc(1, sizeof *c);
    if (!c) {
        coro_fatal("out of memory spawning a coroutine");
    }
    c->entry = entry;
    c->arg = arg;
    stack_init(c, stack_size_for(stack_size));
    enqueue(c);
    return c;
}

void __flang_coro_run(void) {
    if (sched.current) {
        coro_fatal("coroutine run loop entered from inside a coroutine");
    }
    int converted = sched_enter();
    for (;;) {
        FlangCoro* c = dequeue();
        if (!c) {
            break;
        }
        c->state = CORO_RUNNING;
        sched.current = c;
        switch_in(c);
        sched.current = NULL;
        if (c->state == CORO_DONE) {
            stack_release(c);
        }
    }
    sched_leave(converted);
}

void __flang_coro_yield(void) {
    FlangCoro* c = require_current("yield");
    enqueue(c);
    suspend(c);
}

void __flang_coro_park(void) {
    FlangCoro* c = require_current("park");
    if (c->wake_pending) {
        c->wake_pending = 0;
        return;
    }
    c->state = CORO_PARKED;
    suspend(c);
}

void __flang_coro_wake(FlangCoro* c) {
    switch (c->state) {
    case CORO_PARKED:
        enqueue(c);
        break;
    case CORO_DONE:
        break;
    default:
        c->wake_pending = 1;
        break;
    }
}

FlangCoro* __flang_coro_current(void) {
    return sched.current;
}

int32_t __flang_coro_is_done(const FlangCoro* c) {
    return c->state == CORO_DONE;
}

void __flang_coro_free(FlangCoro* c) {
    if (c->state != CORO_DONE) {
        coro_fatal("coroutine freed before it finished");
    }
    free(c);
}
