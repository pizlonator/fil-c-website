# Safepoints and Fil-C

Safepointing is an underappreciated aspect of modern multithreaded VM/GC tech. It forms the foundation of Fil-C's accurate stack scanning, safe signal handling, and safe forking. It also forms the foundation of accurate GC, debugging, and profiling in modern lots of other virtual machines (JVMs in particular). Perhaps most crucially:

*Safepointing is the reason why multiple threads can race on the heap in Fil-C using non-atomic unordered instructions, under any widely used hardware memory model, without breaking the soundness guarantees of the garbage collector.*

You can replace "Fil-C" with "Java" or most other GC-based languages that support threads and the same thing holds. Let's dig into what this magical technique does!

## What Does Safepointing Do?

Safepointing is:

- a lightweight synchronization mechanism that allows threads in a VM to make assumptions about the VM's state, and

- a lightweight mechanism for threads executing in the VM to report their current state.

Let's dig into how safepointing works by considering *just one of the many assumptions* that we want [the compiler](compiler.html) to be able to make about how it interacts with [the accurate garbage collector](fugc.html): we want to allow threads to assume that a pointer loaded from the heap will point to a live object even if that thread hasn't done anything to enable the GC's root scanning to find that pointer. Say that one thread does:

    void* local_variable = object->field;

while another thread runs the garbage collector. The thread that loaded `object->field` is doing so with code compiled with a sophisticated compiler based on LLVM so we cannot practically know what instruction sequence this results in. Let's say that the instruction sequence happens to be:

    movdqu (%rsi),%xmm0

This is surprising but entirely possible. The compiler is using a vector instruction! Perhaps there was a control-flow-equivalent load of a 64-bit field right next to `object->field`, so the compiler combined the two loads into a SIMD load. Now imagine that *right after this instruction executes*, the thread gets preempted, and the garbage collector runs start to finish.

## What Could Possibly Go Wrong?

In the worst case, there's another thread in the race: a thread that stores a different pointer (perhaps `NULL`) to `object->field`. Now, the only place that points to the object is half of `%xmm0`! Therefore, we need the GC to somehow know to scan that half of `%xmm0`. Since Fil-C uses an accurate GC, the GC would have to know exactly which half.

Unfortunately, we have no way to do this practically, since this would require a highly invasive rewrite of the LLVM compiler to track precisely where pointers end up, and to produce data about where pointers might be at every single instruction boundary. Even if such a rewrite was possible, it would likely pessimize LLVM's code generator and make every pass in LLVM harder to understand. We don't want that!

But let's even say that we did exactly that undesirable change to LLVM. This would mean that the GC would have to have some way to suspend threads and then lift up those threads' register state, and have a plan for what to do no matter what the state of the registers was (including if the program counter was off in some kind of native code). Sounds awful! Not only would such an approach be bad for the compiler, it would be bad for the whole rest of the system, too!

## So What Do We Do?

We pick specific points ("safe points") in each function where we force the compiler to tell us where the pointers are, and then we make sure that the GC can only preempt a thread of execution at those safepoints.

If our compiler did happen to have the ability to report that a pointer is in some specific lane of a vector register, then the point right after `movdqu (%rsi),%xmm0` could be a safepoint and the GC could run start-to-finish while our thread is stopped at that point. Since our compiler doesn't have that ability, we have the GC wait for the thread to make progress to a safepoint inserted later in the code before finishing.

Making safepoints efficient is a bottomless pit of innovation across many virtual machines. There are many ways to do it! Fil-C currently does it in a very simple way that focuses in maximum concurrency rather than peak throughput. Let's look at how it works.

<a name="pollchecks">
## How Fil-C Compiles Safepoints

The Fil-C compiler inserts *pollchecks* at each backward control flow edge. A pollcheck is just:

    if (UNLIKELY((my_thread->state & (FILC_THREAD_STATE_CHECK_REQUESTED |
                                      FILC_THREAD_STATE_STOP_REQUESTED |
                                      FILC_THREAD_STATE_DEFERRED_SIGNAL))))
        filc_pollcheck_slow(my_thread, origin);

Where `my_thread` is a register-allocated pointer to the internal Fil-C representation of a thread. The compiler knows how to inline this (except for the call to the slow path, which is too big to inline). The instruction sequence on x86 is just a single `test` instruction involving a memory operand and a constant; usually something like:

    testb  $0xe,0x8(%rbx)
    jne    <somewhere>

We want to bound the amount of code that can execute between pollcheck executions, so it's worth dwelling a bit on what a *backward control flow edge* is and why it's important. Notably, we're not specifically talking about *loop edges*. In a compiler, a *loop* is whenever it's possible to prove that a structured looping construct is in use; usually it means *any set of blocks that is backwards-reachable from a block whose terminator branches to a block that dominates it*. In other words, *loop* doesn't actually encompass all of the cases where control flow leads to reexecution of the same code. On the other hand *backwards control flow edge* does conservatively encompass all of those cases, using a different definition: *any control flow edge from a descendant in the control flow graph's DFS tree to its ancestor*. Fil-C focuses only on such edges, and does not do any pollcheck insertion for calls. This is acceptable since Fil-C doesn't currently have tail calls (if it did, then pollchecks would have to be inserted at those).

<a name="pizderson">
## How Fil-C Tracks Pointers

Fil-C uses *Pizderson frames* to track pointers. A Pizderson frame is like a [Henderson frame](https://dl.acm.org/doi/10.1145/512429.512449) except optimized for non-moving GC. Pointer register allocation is still possible since pointers are just mirrored into Pizderson frames, as opposed to being outright stored there like a Henderson frame. Here's the struct layout of a Pizderson frame:

    struct filc_frame {
        filc_frame* parent;
        const filc_origin* origin;
        void* lowers[];
    };

The compiler stack-allocates such a frame, with enough room in `lowers` to track the high watermark of how many GC pointers are live at any time at any pollcheck. The compiler ensures that any pointer that may be live across a pollcheck is stored somewhere into the `lowers` array before that pollcheck fires.

<a name="softhandshake">
## How The GC Synchronizes With Safepoints

[FUGC](fugc.html) is an *on-the-fly* collector, meaning that there is no global stop-the-world where all threads are stopped for the GC. Instead of stop-the-world, Fil-C uses the *soft handshake* style of safepointing. In a soft handshake, the GC tells each thread what it would like it to do at the next safepoint and then sets the `FILC_THREAD_STATE_CHECK_REQUESTED` bit. Then the GC waits until all threads have executed the requested action at a safepoint.

Each thread has a lock and condition variable in addition to the `state` field. The `state` field has the following rules for how it must be accessed:

- The owning thread may read `state` without locks.

- The owning thread may modify `state` using CAS.

- Any other thread may read or CAS `state` if it holds the thread's lock.

- Some changes to `state` require the lock to be held even if they are made by the owning thread, and some changes to `state` require a broadcast on the condition variable.

<a name="native">
## What About Native Code?

Pollchecks are only executed by Fil-C-compiled code. So, if a Fil-C thread makes a blocking system call (like `read(2)` or one of the `futex` wait calls), then the thread may not execute any pollchecks for an unbounded amount of time. We still want the GC to make progress then!

The answer to this problem is two-fold:

- From the compiler's perspective, any function call that may conservatively have a pollcheck or native call in it is treated as a safepoint; i.e. the any pointers live across the call must be in `lowers`.

- Before a native blocking call, the Fil-C runtime performs a `filc_exit`, which tells the GC that the state of the thread is not `FILC_THREAD_STATE_ENTERED` anymore. After returning from a native call, the Fil-C runtime performs a `filc_enter`, which tells the GC that the thread is `FILC_THREAD_STATE_ENTERED` again. Both `filc_enter` and `filc_exit` use a compare-and-swap on the thread's state on the fast path. If the GC tries to request a soft handshake on a thread that isn't entered, then the GC will perform that action on behalf of the thread.

It's possible that a thread might be exiting or entering while the GC is safepointing. To protect this race, the enter/exit CAS fast paths only succeed if none of the `FILC_THREAD_STATE_CHECK_REQUESTED`, `FILC_THREAD_STATE_STOP_REQUESTED`, or `FILC_THREAD_STATE_DEFERRED_SIGNAL` bits are set. If any of those bits are set, the enter/exit has to also grab the thread's lock. Additionally, if the GC wants to execute the work of a soft handshake on behalf of an exited thread, then it must do so while holding the thread's lock. This ensures that there is no way for a thread to return from `filc_enter` while the GC is concurrently scanning the thread's stack.

## Other GC-Mutator Races

We have deeply explored the "mutator-loads-pointer/GC-runs-to-completion" race. That's a useful race to consider when designing safepoints because it forces us to answer both how threads synchronize with GC and what data threads provide to the GC when that happens. But safepointing in Fil-C (and other systems) also deals with a bunch of other races. Let's review those!

### Store Barrier

The [FUGC](fugc.html) store barrier for `object->field = new_value` looks something like:

    if (GC is marking
        && new_value is not NULL
        && new_value is not marked)
        mark(new_value)

Note that the `GC is marking` check is important; we cannot have objects marked by the barrier before the GC is ready for it, and we *must* have objects get marked by the barrier after the GC is both ready for it and starts to require it. Additionally, we cannot have a race like:

1. Thread executes the store barrier.

2. GC completes a full cycle.

3. Thread does the `object->field = new_value` store that the barrier guarded.

Safepoints protect us from all of these problems because we ensure that the compiler will *never insert a pollcheck between the barrier and the store it protects*.

### Weak Load Barrier

Fil-C supports a weak pointer API. Weak pointers only work if we have a load barrier, which leads to the same problem: everything breaks if the load barrier executes in a different GC cycle from the load it protects. Again, we protect this by ensuring that there is no pollcheck between the load and its barrier.

### Thread Local Caches

Fil-C optimizes allocation by giving threads local caches of memory they can allocate out of without synchronizing with the rest of the heap. But whenever the GC wishes to do something that affects allocation, we need those caches to get cleared. FUGC achieves this using soft handshakes that request that threads reset their local caches (give all of the memory back to the global heap).

## What Else?

Fil-C hooks into its safepointing mechanism for signal handling. When the OS delivers a signal, and the thread is entered, the Fil-C runtime's signal handler just raises the `FILC_THREAD_STATE_DEFERRED_SIGNAL` bit, and the next pollcheck will run the signal handler. This ensures signal handlers run at well-defined points that the runtime understands, which allows signal handlers to safely allocate GC memory (needed for stack allocations in Fil-C; and as a byproduct it means that Fil-C's malloc is signal-safe). If the thread is exited, then the signal is delivered immediately.

Fil-C's pollchecks also support stop-the-world (via the `FILC_THREAD_STATE_STOP_REQUESTED` bit). This is used for:

- Implementing `fork(2)`, which needs all threads to stop at a known-good point before the fork child jettisons them.

- Debuggint the [FUGC](fugc.html). If you set the `FUGC_STW=1` environment variable, then the GC runs in a stop-the-world mode. This is useful for figuring out if a crash bug is due specifically to the concurrency support.

## Further Reading

Check out [`filc_runtime.h`](https://github.com/pizlonator/fil-c/blob/deluge/libpas/src/libpas/filc_runtime.h) and [`filc_runtime.c`](https://github.com/pizlonator/fil-c/blob/deluge/libpas/src/libpas/filc_runtime.c), looking especially for the definition of `struct filc_thread`, and these functions: `filc_enter`, `filc_exit`, `filc_pollcheck`, and `filc_soft_handshake`. Also look at how [`fugc.c`](https://github.com/pizlonator/fil-c/blob/deluge/libpas/src/libpas/fugc.c) uses the `filc_soft_handshake` API. Finally, it's worth looking at the `FILC_SYSCALL` macro in [`filc_runtime.h`](https://github.com/pizlonator/fil-c/blob/deluge/libpas/src/libpas/filc_runtime.h) and uses of that macro in [`filc_runtime.c`](https://github.com/pizlonator/fil-c/blob/deluge/libpas/src/libpas/filc_runtime.c).

This is a super old technique! There are lots of variations on it in different VMs. The most sophisticated and mature implementations tend to be in JVMs (in my experience). [The Inner Workings of Safepoints](https://foojay.io/today/the-inner-workings-of-safepoints/) is a great write-up of how JVMs do it.

