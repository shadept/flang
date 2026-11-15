/* std.runtime.coro - machines: the part of the coroutine runtime FLang cannot
 * express.
 *
 * A machine is a stack and the saved registers that resume it. Its stack is
 * reserved when the machine is created, with a guard page at its low end, and
 * committed by the operating system as it is touched; it never grows or moves.
 * A machine runs one function at a time, under a context link given by the
 * caller, inside a panic catch point on its own stack. Machines are reused,
 * never freed.
 *
 * Windows uses Fibers. POSIX uses an mmap reservation and the assembly switch
 * below, for x86_64 and arm64. Only the calling thread runs machines.
 */

#include <errno.h>
#include <setjmp.h>
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

#define MACHINE_DEFAULT_STACK ((size_t)1 << 20)
#define MACHINE_MIN_STACK ((size_t)64 << 10)

/* A FLang function: its own parameters, then the context, then env. */
typedef void (*FlangEntry)(void* arg, const void* ctx, void* env);

typedef struct {
    FlangEntry code;
    void* env;
} FlangFunctionValue;

typedef struct FlangMachine FlangMachine;

struct FlangMachine {
    FlangFunctionValue entry;
    void* arg;
    const void* ctx;
    /* 0 while a run is pending or in progress; 1 if it returned; 2 if it
     * panicked. */
    int32_t finished;
    int32_t started;
    FlangMachine* resumer;
    jmp_buf* catch_point;
#ifdef _WIN32
    void* fiber;
#else
    void* stack_pointer; /* while suspended */
    void* stack;         /* mapping base, guard page included */
    size_t stack_len;    /* mapping length */
#endif
};

static FlangMachine thread_machine;
static FlangMachine* current_machine = &thread_machine;

static void machine_fatal(const char* msg) {
    fprintf(stderr, "fatal: %s\n", msg);
    abort();
}

static void platform_switch(FlangMachine* from, FlangMachine* to);

/* __flang_machine_switch() suspends from, which must be the running machine,
 * and resumes to. errno is preserved across the switch. */
void __flang_machine_switch(FlangMachine* from, FlangMachine* to) {
    int saved = errno;
    to->resumer = from;
    current_machine = to;
    platform_switch(from, to);
    current_machine = from;
    errno = saved;
}

/* machine_body() runs each prepared function of m in turn, inside a catch
 * point, and after each one switches back to the machine that switched in. */
static void machine_body(FlangMachine* volatile m) {
    for (;;) {
        jmp_buf catch_point;
        m->catch_point = &catch_point;
        if (setjmp(catch_point) == 0) {
            m->entry.code(m->arg, m->ctx, m->entry.env);
            m->finished = 1;
        } else {
            m->finished = 2;
        }
        m->catch_point = NULL;
        __flang_machine_switch(m, m->resumer);
    }
}

#ifdef _WIN32

static size_t page_size(void) {
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    return (size_t)si.dwPageSize;
}

static VOID CALLBACK fiber_main(LPVOID p) {
    machine_body((FlangMachine*)p);
}

/* CreateFiberEx reserves the stack with a guard region, as for a thread. */
static void stack_init(FlangMachine* m, size_t size) {
    m->fiber = CreateFiberEx(0, size, FIBER_FLAG_FLOAT_SWITCH, fiber_main, m);
    if (!m->fiber) {
        machine_fatal("cannot reserve a coroutine stack");
    }
}

static void frame_start(FlangMachine* m) {
    (void)m;
}

static void platform_switch(FlangMachine* from, FlangMachine* to) {
    (void)from;
    SwitchToFiber(to->fiber);
}

/* thread_init() converts the calling thread to a fiber on first use; it
 * stays one. */
static void thread_init(void) {
    if (thread_machine.fiber) {
        return;
    }
    if (IsThreadAFiber()) {
        thread_machine.fiber = GetCurrentFiber();
        return;
    }
    thread_machine.fiber = ConvertThreadToFiberEx(NULL, FIBER_FLAG_FLOAT_SWITCH);
    if (!thread_machine.fiber) {
        machine_fatal("cannot start the coroutine scheduler");
    }
}

#else /* POSIX */

/* flang_coro_switch() saves the callee-saved registers on the current stack,
 * stores the stack pointer in *save_stack_pointer, loads load_stack_pointer,
 * restores the registers saved there and returns on that stack. On a new
 * stack, frame_init() has laid out a frame whose return enters coro_main(). */
void flang_coro_switch(void** save_stack_pointer, void* load_stack_pointer);

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
    machine_body(current_machine);
}

static void stack_init(FlangMachine* m, size_t size) {
    size_t page = page_size();
    size_t len = size + page;
    void* base = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (base == MAP_FAILED) {
        machine_fatal("cannot reserve a coroutine stack");
    }
    if (mprotect(base, page, PROT_NONE) != 0) {
        machine_fatal("cannot protect a coroutine stack's guard page");
    }
    m->stack = base;
    m->stack_len = len;
}

static void frame_start(FlangMachine* m) {
    m->stack_pointer = frame_init((char*)m->stack + m->stack_len, coro_main);
}

static void platform_switch(FlangMachine* from, FlangMachine* to) {
    flang_coro_switch(&from->stack_pointer, to->stack_pointer);
}

static void thread_init(void) {
}

#endif

static size_t stack_size_for(size_t requested) {
    size_t s = requested == 0 ? MACHINE_DEFAULT_STACK : requested;
    if (s < MACHINE_MIN_STACK) {
        s = MACHINE_MIN_STACK;
    }
    size_t page = page_size();
    return (s + page - 1) / page * page;
}

/* __flang_machine_thread() returns the machine of the calling thread itself,
 * the one coroutines switch back to. */
FlangMachine* __flang_machine_thread(void) {
    thread_init();
    return &thread_machine;
}

/* __flang_machine_new() returns a new machine with a stack of stack_size
 * bytes, or the default size if stack_size is 0. The machine is never freed;
 * the caller keeps it for reuse. On failure the process aborts. */
FlangMachine* __flang_machine_new(size_t stack_size) {
    FlangMachine* m = (FlangMachine*)calloc(1, sizeof *m);
    if (!m) {
        machine_fatal("out of memory creating a coroutine");
    }
    stack_init(m, stack_size_for(stack_size));
    return m;
}

/* __flang_machine_prepare() sets the next function m runs: entry, called
 * with arg under the context link ctx, once a switch enters m. m must be new
 * or finished, and ctx must remain valid until the run finishes. */
void __flang_machine_prepare(FlangMachine* m, const FlangFunctionValue* entry, void* arg,
                             const void* ctx) {
    m->entry = *entry;
    m->arg = arg;
    m->ctx = ctx;
    m->finished = 0;
    if (!m->started) {
        frame_start(m);
        m->started = 1;
    }
}

/* __flang_machine_finished() returns 0 while m's run is pending or in
 * progress, 1 once it returned, and 2 once it panicked. */
int32_t __flang_machine_finished(const FlangMachine* m) {
    return m->finished;
}

/* __flang_task_catch_panic() jumps to the catch point of the running
 * machine's current run, which then finishes as panicked; it does not return.
 * On the thread's own machine it returns. The test runner's panic recovery
 * calls it first. */
void __flang_task_catch_panic(void) {
    if (current_machine->catch_point) {
        longjmp(*current_machine->catch_point, 1);
    }
}
