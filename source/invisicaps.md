# InvisiCaps: The Fil-C Capability Model

Fil-C ensures memory safety of all operations in the C and C++ language. The hardest part of C memory safety is pointer safety. Fil-C achieves pointer safety using a *capability system* for pointers. Specifically, each pointer dynamically tracks what object in memory it should be allowed to access, and using that pointer to access any memory that is not that object is dynamically prohibited.

Achieving memory safety using a pointer capability model means:

- Prohibiting accesses that are out of bounds of the object the pointer is allowed to access.

- Prohibiting accesses to freed objects.

- Prohibiting writes to readonly data.

- Prohibiting reads and writes to non-data objects, such as function pointers, or "special" objects internal to the Fil-C runtime (like the innards of threads or `jmp_buf`s).

- Prohibiting reads or writes that would corrupt Fil-C's understanding of any pointer's capability, leading to failure to meaningfully enforce any of these rules.

In addition to memory safety, Fil-C's other goal is fanatical compatibility. This means that Fil-C's capability model also has to allow most (or ideally all) "safe" uses of C pointers; that is, idioms that are in widespread use and don't lead to exploitation unless they violate the above rules. This means even supporting uses of pointers that the C spec deems to be undefined behavior. And it means preserving `sizeof(T*)` to be the same as what you'd expect - i.e. 8 bytes on 64-bit platforms.

This article describes how Fil-C's capability mode, called InvisiCaps (Invisible Capabilities), achieves all of these goals while also providing reasonable performance and memory usage.

## How Hard Can It Be?

Designing a capability model that satisfies these requirements is sufficiently hard that it is an area of active research. Fil-C has now gone through multiple capability systems; InvisiCaps are just the latest. To appreciate the difficulty of this journey, let's review the previous models and why they were abandoned:

- PLUT (Pointer Lower Upper Type): This required making pointers 256 bits (four 64-bit pointers). This model required knowing the type of each allocation up front and didn't meaningfully support unions. PLUTs were also not thread-safe, which meant that they were not memory safe in multi-threaded programs. PLUTs did not require a GC; they were coupled with an isoheap allocator. Use-after-free was not an error (was not detected), but could not be used to corrupt capabilities.

- SideCaps (Sidecar plus Capability): This was an ingenious capability model that solved the thread safety of PLUTs. SideCaps were a heroic racy atomic protocol that allowed 256 bits of data to be encoded atomically using only 128-bit atomic operations. I am very proud of SideCaps, but they were awful. They were extremely slow (back then, Fil-C was 200x slower than normal C). And, they required knowing the type at allocation time, so they did not meaningfully support unions. Use-after free was not an error (was not detected), but could not be used to corrupt any SideCaps.

- MonoCaps (Monotonic Capabilities): The main advantage of switching to MonoCaps was that the type of an object did not have to be determined at allocation time, but could be monotonically revealed as the program used the object. This allowed somewhat meaningful union usage, and obviated the need to infer the type at malloc callsites. MonoCaps also reduced the perf overhead of Fil-C to about 10x, reduced pointer size to 128 bits, unlocked C++ support, and added the ability to deterministically panic on use-after-free rather than only preventing capability corruption on use-after-free. MonoCaps also coincided with the introduction of [Fil's Unbelievable Garbage Collector](fugc.html). It's not possible to do MonoCaps without a GC.

InvisiCaps are a major improvement over MonoCaps:

- InvisiCaps allow for 64-bit pointers on 64-bit systems (and would allow for 32-bit pointers if Fil-C supported 32-bit systems).

- InvisiCaps have thus far allowed for a reduction of performance overhead to about 4x in the bad cases. There are still performance optimization opportunities with InvisiCaps that I haven't explored so they're likely to get faster still.

- InvisiCaps allow for meaningful union usage. The type of a memory location can change over the lifetime of that location.

InvisiCaps achieve this without sacrificing thread safety of the capability model.

## What Are InvisiCaps Most Like?

InvisiCaps can be thought of as a practical-to-implement and totally thread-safe variant of [SoftBound](https://dl.acm.org/doi/10.1145/1543135.1542504). InvisiCaps are heavily inspired by that work. Unlike SoftBound, InvisiCaps don't allow memory safety escapes by racing on pointers, and they allow for making all features of C and C++ safe, including subtle stuff like function pointer usage. The greatest similarity between SoftBound and InvisiCaps is that they both place the capability metadata "outside" of the address space visible to the program.

InvisiCaps can also be thought of as a software implementation of [CHERI](https://www.cl.cam.ac.uk/research/security/ctsrd/cheri/). Unlike CHERI, InvisiCaps are more compatible (pointers are 64-bit, not 128-bit or 256-bit) and InvisiCaps have a more deterministic use-after-free story.

<a name="flightptr"></a>
## The Intuition Of InvisiCaps

Let's start with a simple intuition for how InvisiCaps work, without worrying about how a pointer and its capability are stored in memory. Let's just consider:

- A pointer in a local variable, not in memory. We'll call this a *flight pointer*.

- The layout of the object that the pointer points at.

For our example, let's consider a pointer that points into the middle of an object.

<img src="object.svg" class="centered-svg-60" alt="Layout of a Fil-C object and flight pointer">

The flight pointer has two parts:

- The *lower bound ptr*. This gives us the lower bounds for the purpose of bounds checking pointer accesses. It *also* pointers *right above* the object header, which contains:

    - The *upper bound ptr*. We'll use this for the upper bounds check. This has to be at least as large as the lower bound ptr. It can be exactly equal to the lower bound ptr, for objects that cannot be accessed at all (like free objects or special objects).

    - The *aux word*. We'll come back to this! It's sneaky!

- The *ptr intval*. This is the raw integer value of the pointer as visible to the C program. When the C program reasons about the value of the pointer (using arithmetic, casts, printing the pointer, comparing the pointer to other pointers, etc), it only ever sees the intval.

We refer to the two parts of the flight ptr as the *lower* and the *intval* for short (though be warned, the Fil-C source code usually refers to the *intval* as the "ptr").

The *lower* cannot be modified by the C program; you get a *lower* when you allocate an object and then any pointer derived from the pointer that came out of the allocator has that *lower*. The *lower* is trusted by the Fil-C runtime, since it's used for bounds checks (both directly, for the lower bounds check, and indirectly, for all checks that rely on the object header *just below* where the *lower* points).

The *intval* can be modified by the C program and isn't trusted by the Fil-C runtime at all.

Every memory access involves an untrusted *intval*, indicating the location that the program wishes to access, and a trusted *lower*, indicating what addresses this particular pointer can access (and how).

As a bonus feature, the *lower* can be NULL. Pointers with NULL *lower* cannot be accessed (the access always traps with an error saying you have a NULL *lower*).

If pointers could only ever live in local variables and could not be stored to the heap, then that would be the whole story!

<a name="restptr"></a>
## InvisiCaps At Rest

When a pointer is stored to the heap, we call this a *pointer at rest* (or *rest pointer*). Like a pointer in flight, a pointer at rest must know its *lower* and *intval*. InvisiCaps for pointers at rest achieve the following goals:

- If you store a pointer to the heap and load it back as an integer, you get the intval.

- If you store an integer to the heap and load it back as a pointer, you get a pointer with a null *lower*, or whatever *lower* the last pointer stored to that location had. You never get an invalid or corrupted *lower*.

- It's not possible to access a pointer at the location where the *lower* is stored; no capability has the locations used for storing *lower*s (or any other Fil-C metadata) within its bounds. *This is the key property of InvisiCaps, and the thing that makes them "invisible" -- the C program just sees the intval portion of pointers.*

- Racing on pointer accesses results in the program loading some valid *lower* (it just might not be the *lower* you wanted, so you might trap on access).

- Atomic pointer accesses (using `_Atomic`, `volatile`, or `std::atomic`) are really atomic and lock-free.

The key insight behind how this is achieved is the InvisiCaps inductive hypothesis:

*Every flight pointer's* lower *points to the top of an object header whose aux word contains a way to get the* lower*s for all pointers stored to that object's payload.*

The aux word of an object that has no pointers is simply NULL. But if an object had any pointers stored into it, an *aux allocation* is allocated, which has the same size as the object's payload. The aux word then points at the aux allocation. *If we ignore atomic pointers for now,* all pointers at rest in the object have their *lower* in the aux allocation and their *intval* in the object payload.

<img src="object-with-aux.svg" class="centered-svg-80" alt="Layout of a Fil-C object that points at another object">

In this example, let's consider two objects. Object #1 has a pointer at rest in its payload, which points at Object #2. So, its aux word points at an aux alloation that contains that pointer's *lower*. The pointer's *intval* is in the object's payload. Note that the flight pointer in our example points at the pointer at rest in object #1.

Hence, all nonatomic pointer loads and stores access both the aux allocation (via the aux word, which is just below where *lower* points) and the object payload. Stores may cause the aux allocation to be lazily created.

Note that this is approach is very friendly to [garbage collection](fugc.html):

- If the aux word isn't set, then the GC treats the object as a leaf (it has no outgoing pointers from the GC's perspective).

- If the aux word is set, then the GC only looks for pointers in the aux allocation.

## Atomic InvisiCaps

But what if a pointer at rest is `_Atomic`, `volatile`, `std::atomic`, or was stored using any other type or mechanism that clang considers to require atomicity?

<img src="object-with-atomic.svg" class="centered-svg-80" alt="Layout of a Fil-C atomic pointer">

The aux allocation can contain either *lower*s or *atomic box* pointers. The type of entry in the aux allocation is determined by the low bit of that entry (zero indicates *lower*, one indicates atomic box pointer). Atomic boxes are 16-byte, 16-byte-aligned allocations that contain a flight pointer that we store using 128-bit atomics. Or, if the system does not support double-CAS, we could use 64-bit atomics on the atomic box pointer itself and allocate a new atomic box every time an atomic mutation happens (luckily both X86_64 and ARM64 have 128-bit atomics, so that's not necessary).

Note that when a pointer at rest is atomic, the payload contains a copy of the intval, purely for allowing integer loads to see the intval. However, racing an integer access against a pointer access may result in time travel, but cannot result in the atomic box being corrupted -- it'll just be a logic error.

This approach allows Fil-C to support atomic InvisiCaps when the program wants atomicity, while using a cheaper approach to pointers when atomicity is not requested.

## Additional Considerations

The aux word uses only its lower 48 bits for storing the aux allocation pointer; the upper 16 bits are used for flags and additional data. That additional data is helpful for nonstandard object allocations as well as *special objects* like functions, threads, and other builtin types provided by the Fil-C runtime. Let's consider some examples.

### Aligned Allocations

If an object is allocated using `posix_memalign` or similar API and a sufficiently large alignment is requested, then the the *lower* minus the object header size points inside an aligned allocation. So, the GC can't work out what the base of the allocation is just simply by subtracting the object header size from the *lower*. The extra flags in the aux word have enough space to encode the object alignment, which can be used to work out the true base of the allocation.

### Memory Mapping

`mmap` and Sys-V shared memory require special treatment. The GC knows how to manage even those allocations, but special care must be taken with them. The aux word has flags that are set if an object requires such special care.

### Function Pointers

Function pointers have an intval that points at the actual function entrypoint, while the *lower* points to a function capability that:

- Has an upper bound equal to the *lower*, which prevents all data accesses.

- Has flags set to indicate that the capability really is a function.

- The remainder of the aux word is used to indicate the true function entrypoint, so that function calls can check if the function pointer really points at the entrypoint.

Function pointer casts are handled dynamically (the Fil-C calling convention dynamically resolves mismatches in types passed by the caller and types expected by the callee).

### Threads

Fil-C's internal thread abstraction, called `zthread`, is used internally by musl's and glibc's pthread implementations. Because the `zthread` contains a lot of internal runtime state, it needs to be specially protected. A pointer to a `zthread` - or to any of the other builtin types - has the following structure:

- The *lower* points at the internal `zthread` payload.

- The upper bounds is equal to *lower*, so no data accesses are possible.

- The flags in the aux word indicate that this is really a `zthread` object.

All builtin functions that take a `zthread` pointer check that the pointer they are given is really a `zthread` pointer by looking at the aux word's flags.

### Freed Objects

Freeing an object results in deterministic panics when accessing the freed memory. This is simple to achieve:

- Freeing sets the pointer's upper bound to be equal to *lower*, thus preventing all accesses.

- A *free* bit is set in the aux word so that the diagnostic message printed when the program panics indicates that it was because of use after free.

## Conclusion

Fil-C uses a capability model for pointers to ensure memory safety. To ensure maximum compatibility, Fil-C's *InvisiCap* capability model gives the illusion that pointers are just 64-bit on 64-bit systems and allows flexible reinterpretation of memory type (including violations of the active member union rule) while preserving the soundness of the capability model itself. No matter how evil the program is, it will either get a memory safe outcome (all pointer accesses are in bounds of a capability that the pointer legitimately had) or a Fil-C panic.

Additional reading:

- [InvisiCaps by Example](invisicaps_by_example.html)

- [Explanation of Fil-C Disassembly](compiler_example.html)
