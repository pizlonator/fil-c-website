# Fil's Unbelievable Garbage Collector

Fil-C uses a *parallel concurrent on-the-fly grey-stack Dijkstra accurate non-moving* garbage collector called FUGC (Fil's Unbelievable Garbage Collector). You can find the source code for the collector itself in [fugc.c](https://github.com/pizlonator/fil-c/blob/deluge/libpas/src/libpas/fugc.c), though be warned, that code cannot possibly work without lots of support logic in the rest of the runtime and in the compiler.

Let's break down FUGC's features:

- Parallel: marking and sweeping happen in multiple threads, in parallel. The more cores you have, the
  faster the collector finishes.

- Concurrent: marking and sweeping happen on some threads other than the *mutator* threads (i.e. your
  program's threads). Mutator threads don't have to stop and wait for the collector. The interaction
  between the collector thread and mutator threads is mostly non-blocking (locking is only used on
  allocation slow paths).

- On-the-fly: there is no global stop-the-world, but instead we use
  "soft handshakes" (aka "ragged safepoints"). This means that the GC may ask threads to do some work (like scan stack), but threads do this
  asynchronously, on their own time, without waiting for the collector or other threads. The only "pause"
  threads experience is the callback executed in response to the soft handshake, which does work bounded
  by that thread's stack height. That "pause" is usually shorter than the slowest path you might take
  through a typical `malloc` implementation.

- Grey-stack: the collector assumes it must rescan thread stacks to fixpoint. That is, GC starts with
  a soft handshake to scan stack, and then marks in a loop. If this
  loop runs out of work, then FUGC does another soft handshake. If that reveals more objects, then
  concurrent marking resumes. This prevents us from having a *load barrier* (no instrumentation runs
  when loading a pointer from the heap into a local variable). Only a *store barrier* is
  necessary, and that barrier is very simple. This fixpoint converges super quickly because all newly
  allocated objects during GC are pre-marked.

- Dijkstra: storing a pointer field in an object that's in the heap or in a global variable while FUGC
  is in its marking phase causes the newly pointed-to object to get marked. This is called a *Dijkstra
  barrier* and it is a kind of *store barrier*. Due to the grey stack, there is no load barrier like
  in the [classic Dijkstra collector](https://lamport.azurewebsites.net/pubs/garbage.pdf). The FUGC store
  barrier uses a compare-and-swap with relaxed memory ordering on the slowest path (if the GC is running
  and the object being stored was not already marked).

- Accurate: the GC accurately (aka precisely, aka exactly) finds all pointers to objects, nothing more,
  nothing less. `llvm::FilPizlonator` ensures that the runtime always knows where the root pointers are
  on the stack and in globals. The Fil-C runtime has a clever API and Ruby code generator for tracking
  pointers in low-level code that interacts with pizlonated code. All objects know where their outgoing
  pointers are - they can only be in the [InvisiCap](invisicaps.html) auxiliary allocation.

- Non-moving: the GC doesn't move objects. This makes concurrency easy to implement and avoids
  a lot of synchronization between mutator and collector. However, FUGC will "move" pointers to free
  objects (it will repoint the [capability](invisicaps.html) pointer to the free singleton so it doesn't have to mark the
  freed allocation).

This makes FUGC an *advancing wavefront* garbage collector. Advancing wavefront means that the
mutator cannot create new work for the collector by modifying the heap. Once an
object is marked, it'll stay marked for that GC cycle. It's also an *incremental update* collector, since
some objects that would have been live at the start of GC might get freed if they become free during the
collection cycle.

FUGC relies on *safepoints*, which comprise:

- *Pollchecks* emitted by the compiler. The `llvm::FilPizlonator` compiler pass emits pollchecks often enough that only a
  bounded amount of progress is possible before a pollcheck happens. The fast path of a pollcheck is
  just a load-and-branch. The slow path runs a *pollcheck callback*, which does work for FUGC.

- Soft handshakes, which request that a pollcheck callback is run on all threads and then waits for
  this to happen.

- *Enter*/*exit* functionality. This is for allowing threads to block in syscalls or long-running
  runtime functions without executing pollchecks. Threads that are in the *exited* state will have
  pollcheck callbacks executed by the collector itself (when it does the soft handshake). The only
  way for a Fil-C program to block is either by looping while entered (which means executing a
  pollcheck at least once per loop iteration, often more) or by calling into the runtime and then
  exiting.

Safepointing is essential for supporting threading (Fil-C supports pthreads just fine) while avoiding
a large class of race conditions. For example, safepointing means that it's safe to load a pointer from
the heap and then use it; the GC cannot possibly delete that memory until the next pollcheck or exit.
So, the compiler and runtime just have to ensure that the pointer becomes tracked for stack scanning at
some point between when it's loaded and when the next pollcheck/exit happens, and only if the pointer is
still live at that point.

The safepointing functionality also supports *stop-the-world*, which is currently used to implement
`fork(2)` and for debugging FUGC (if you set the `FUGC_STW` environment variable to `1` then the
collector will stop the world and this is useful for triaging GC bugs; if the bug reproduces in STW
then it means it's not due to issues with the store barrier). The safepoint infrastructure also allows
safe signal delivery; Fil-C makes it possible to use signal handling in a practical way. Safepointing is
a common feature of virtual machines that support multiple threads and accurate garbage collection,
though usually, they are only used to stop the world rather than to request asynchronous activity from all
threads. See [here](https://foojay.io/today/the-inner-workings-of-safepoints/) for a write-up about
how OpenJDK does it. The Fil-C implementation is in [`filc_runtime.c`](https://github.com/pizlonator/fil-c/blob/deluge/libpas/src/libpas/filc_runtime.c).

Here's the basic flow of the FUGC collector loop:

1. Wait for the GC trigger.
2. Turn on the store barrier, then soft handshake with a no-op callback.
3. Turn on black allocation (new objects get allocated marked), then soft handshake with a callback
   that resets thread-local caches.
4. Mark global roots.
5. Soft handshake with a callback that requests stack scan and another reset of thread-local caches.
   If all collector mark stacks are empty after this, go to step 7.
6. Tracing: for each object in the mark stack, mark its outgoing references (which may grow the mark
   stack). Do this until the mark stack is empty. Then go to step 5.
7. Turn off the store barrier and prepare for sweeping, then soft handshake to reset thread-local
   caches again.
8. Perform the sweep. During the sweep, objects are allocated black if they happen to be allocated out
   of not-yet-swept pages, or white if they are allocated out of alraedy-swept pages.
9. Victory! Go back to step 1.

If you're familiar with the literature, FUGC is sort of like the DLG (Doligez-Leroy-Gonthier) collector
(published in [two](https://xavierleroy.org/publi/concurrent-gc.pdf)
[papers](http://moscova.inria.fr/~doligez/publications/doligez-gonthier-popl-1994.pdf) because they
had a serious bug in the first one), except it uses the Dijkstra barrier and a grey stack, which
simplifies everything but isn't as academically pure (FUGC fixpoints, theirs doesn't). I first came
up with the grey-stack Dijkstra approach when working on
[Fiji VM](http://www.filpizlo.com/papers/pizlo-eurosys2010-fijivm.pdf)'s CMR and
[Schism](http://www.filpizlo.com/papers/pizlo-pldi2010-schism.pdf) garbage collectors. The main
advantage of FUGC over DLG is that it has a simpler (cheaper) store barrier and it's a slightly more
intuitive algorithm. While the fixpoint seems like a disadvantage, in practice it converges after a few
iterations.

Additionally, FUGC relies on a sweeping algorithm based on bitvector SIMD. This makes sweeping insanely
fast compared to marking. This is made thanks to the
[Verse heap config](https://github.com/pizlonator/fil-c/blob/deluge/libpas/src/libpas/verse_heap.h)
that I added to
[libpas](https://github.com/WebKit/WebKit/blob/main/Source/bmalloc/libpas/Documentation.md). FUGC
typically spends <5% of its time sweeping.

## Bonus Features

FUGC supports a most of C-style, Java-style, and JavaScript-style memory management. Let's break down what that means.

### Freeing Objects

If you call `free`, the runtime will flag the object as free and all subsequent accesses to the object will trap. Additionally, FUGC will not scan outgoing references from the object (since they cannot be accessed anymore).

Also, FUGC will redirect all capability pointers (*lower*s in [InvisiCaps](invisicaps.html) jargon) to free objects to point at the free singleton object instead. This allows freed object memory to really be reclaimed.

This means that freeing objects can be used to prevent *GC-induced leaks*. Surprisingly, a program that works fine with `malloc`/`free` (no leaks, no crashes) that gets converted to GC the naive way (`malloc` allocates from the GC and `free` is a no-op) may end up leaking due to dangling pointers that the program never accesses. Those dangling pointers will be treated as live by the GC. In FUGC, if you freed those pointers, then FUGC will really kill them.

### Finalizers

FUGC supports finalizer queues using the `zgc_finq` API in [stdfil.h](https://github.com/pizlonator/fil-c/blob/deluge/filc/include/stdfil.h). This feature allows you to implement finalizers in the style of Java, except that you get to set up your own finalizer queues and choose which thread processes them.

### Weak References

FUGC supports weak references using the `zweak` API in [stdfil.h](https://github.com/pizlonator/fil-c/blob/deluge/filc/include/stdfil.h). Weak references work just like the weak references in Java, except there are no reference queues. Also, Fil-C 

### Weak Maps

FUGC supports weak maps using the `zweak_map` API in [stdfil.h](https://github.com/pizlonator/fil-c/blob/deluge/filc/include/stdfil.h). This API works almost exactly like the JavaScript [WeakMap](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/WeakMap), except that Fil-C's weak maps allow you to iterate all of their elements and get a count of elements.

# Conclusion

FUGC allows Fil-C to give the strongest possible guarantees on misuse of `free`:

- Freeing an object and then accessing it is guaranteed to result in a trap. Unlike tag-based approaches, which will trap on use after free until until memory reclamation is forced, FUGC means you will trap even after memory is reclaimed (due to *lower* repointing to the free singleton).

- Freeing an object twice is guaranteed to result in a trap.

- Failing to free an object means the object gets reclaimed for you.
