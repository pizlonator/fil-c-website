# Fil-C Runtime

Programs compiled with Fil-C enjoy comprehensive memory safety thanks to the entire userland stack being compiled with the [Fil-C compiler](compiler.html). There is no interoperability with Yolo-C (i.e. classic C). This is both a *goal* and the outcome of a *non goal*.

**Goal:** *To prevent memory safety issues arising from code linked into your Fil-C program.* Lots of memory safety solutions make it easy to lock down just a small part of your program. While this can be a satisfying thing to do for systems builders as it shows progress towards memory safety, it's also easy for the attackers to work around. Software that's in a perpetually "partly memory safe" state is really in a perpetually unsafe state. It's a goal of Fil-C to take a giant leap towards complete memory safety, rather than slowly inching towards it.

**Non-Goal:** <s>*To support interoperability with Yolo-C.*</s> That kind of interoperability is hard to engineer, both from a language design and a language implementation standpoint. Fil-C uses pointers that carry [capabilities](invisicaps.html). It's hard to imagine a satisfactory language design that allows Yolo-C code to pass a pointer to Fil-C while having some kind of meaningful capability associated with that pointer. Even if a design existed, actually making it work is even harder, particularly since Fil-C uses [accurate garbage collection](fugc.html) and Yolo-C++ has [explicitly removed support for garbage collection of any kind](https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2021/p2186r2.html). It's a non-goal of Fil-C to try to marry its garbage collected capabilities with languages that disallow garbage collection and lack capabilities.

Building a meaningful product often means accepting what you can and cannot do and then embracing the limitations that fall out. Fil-C proudly embraces *comprehensive memory safety*.

What does this look like in practice? This document shows the current status.

## The libc Sandwich

Fil-C has a runtime (`libpizlo.so` and `filc_crt.o`) that is written in Yolo-C and that links to a libc compiled with Yolo-C. Another libc, compiled with Fil-C, lives on top of the runtime. The rest of your software stack then lives on top of that libc.

<img src="sandwich.svg" class="centered-svg-60" alt="Fil-C Sandwich Runtime">

Let's review the components:

- `ld-yolo-x86_64.so`. This is the ELF loader. Because Fil-C currently uses musl as the libc, this is really a symbolic link to `libyoloc.so` (this loader-symlibs-libc trick is a musl-ism). It's compiled with Yolo-C.

- `libyoloc.so`. This is a mostly unmodified musl libc, compiled with Yolo-C. The only changes are to expose some libc internal functionality that is useful for implementing `libpizlo.so`. Note that `libpizlo.so` only relies on this library for system calls and a few low level functions. In the future, it's possible that the Fil-C runtime would not have a libc in Yolo Land, but instead `libpizlo.so` would make syscalls directly.

- `crt*.o`. These are the Yolo-C program startup trampolines that call musl's libc start function.

- `libpizlo.so`. The Fil-C runtime lives in this library. It is based on the libpas memory management toolkit, the [FUGC](fugc.html) and [safepoints](safepoints.html), and everything needed to support memory safe threading, system calls, signal handling, capability slow paths, and other things not provided by the compiler. Programs compiled with the Fil-C compiler strongly depend on `libpizlo.so` (you will see symbols with the `filc_` prefix imported by any module compiled with the Fil-C compiler; this symbols are defined in `libpizlo.so`). `libpizlo.so` contains some code written in Fil-C, like the C personality function (for supporting C exceptions), and some of the logic to make `epoll(2)` work in Fil-C.

- `filc_crt.o`. This provides the Yolo-C `main` function that the libc start function expects to be able to call, and imports the `pizlonated_main` function that a Fil-C program would define. `filc_crt.o`'s job is to call `libpizlo.so`'s `filc_start_program` function, passing it the program arguments and pointer to `pizlonated_main`.

- `libc.so`. This is a modified musl libc compiled with Fil-C. Most of the modifications are about replacing inline assembly for system calls with calls to `libpizlo.so`'s [syscall API](https://github.com/pizlonator/fil-c/blob/deluge/filc/include/pizlonated_syscalls.h).

- `libc++abi.so`. This is a modified LLVM project libc++abi compiled with Fil-C. The largest modification is to use [Fil-C's variant of libunwind](https://github.com/pizlonator/fil-c/blob/deluge/filc/include/unwind.h) and Fil-C's way of [tracking exception tables](https://github.com/pizlonator/fil-c/blob/deluge/filc/include/pizlonated_eh_landing_pad.h). `libpizlo.so` provides the core unwind functionality, like `_Unwind_RaiseException`. `libc++abi.so` provides the C++ personability function. Note that the personality function is compiled with Fil-C (so it's totally memory safe).

- `libc++.so`. A lightly modified LLVM project libc++ compiled with Fil-C.

- Your program and your libraries. Your whole program must be compiled with Fil-C. Your programs dependencies must be compiled with Fil-C as well.

Note that while I'm showing shared libraries (`.so`s), it's possible to compile a static Fil-C executable, in which case `ld-yolo-x86_64` doesn't come into play at all and the rest of the stack is statically linked into your program.

You can see a bit of this architecture by calling the [stdfil.h](stdfil.html) `zdump_stack` function:

    #include <stdfil.h>
    
    int main()
    {
        zdump_stack();
        return 0;
    }

This program prints:

        <runtime>: zdump_stack
        stack.c:5:5: main
        src/env/__libc_start_main.c:79:7: __libc_start_main
        <runtime>: start_program

Let's examine these frames starting from the bottom:

- `<runtime>: start_program`. This is the `libpizlo.so` `filc_start_program` function called by `filc_crt.o`. Note that this is sandwiched between two `__libc_start_main` functions. Further below the stack (where the Fil-C stack scan cannot see) is the Yolo-C `__libc_start_main` function from `libyoloc.so`, and directly above this is the Fil-C `__libc_start_main` from `libc.so`.

- `src/env/__libc_start_main.c:79:7: __libc_start_main`. This is the user `libc.so` start function, compiled with Fil-C.

- `stack.c:5:5: main`. This is our actual `main` function, compiled with Fil-C.

- `<runtime>: zdump_stack`. This is `libpizlo.so`'s implementation of `zdump_stack`.

## Memory Safe Linking And Loading

Fil-C relies on ELF. I have also previously demonstrated it working on Mach-O. Fil-C does not require changes to the linker. The only changes to the musl loader are to teach it that from its standpoint, the libc that it cares about is called `libyoloc.so` not `libc.so`. Fil-C even supports advanced ELF features like weak symbols, weak or strong aliases, comdats, and even ifuncs. Fil-C ifuncs are just Fil-C functions and they are totally memory safe. That said, Fil-C has its own ABI (Application Binary Interface) and that ABI is not compatible with Yolo-C.

Linking and loading "just works" because of the following four ABI modifications:

- Mangling: each symbol in your program is mangled by having `pizlonated_` prepended to it. This prevents `libc` symbols from colliding with `libyoloc` symbols, for example. It also prevents any of your code from colliding with `libpizlo`.

- Getter indirection: the `pizlonated_` symbols, like `pizlonated_main`, are getters that return the [Fil-C flight pointer (so intval and capability)](invisicaps.html) to the thing that the symbol refers to. When you access a symbol in your C or C++ code, the compiler emits a call to the relevant getter (with minimal optimizations to eliminate redundant calls to the same getter), and then your code uses the returned pointer and capability *without trusting anything about it* (i.e. function calls do the function check, reads and writes do full bounds and permission checking, etc). Note that ifuncs are implemented by having the getter call back into Fil-C (with special shenanigans to catch recursive calls).

- Demotion of ODR to Any: Fil-C does not allow the compiler or linker to assume that multiple definitions by the same name are equivalent; it forces the more conservative assumption that they may differ.

- The compiler and loader (`ld-yolo-x86_64.so`) both search for headers and libraries in the [pizfix](pizfix.html), so that Fil-C gets its own *slice* separate from system libraries that follow Yolo-C ABI rather than Fil-C ABI.

Put together, this means that even wild misuse of linker capabilities in your Fil-C program will at worst result in a memory safe outcome (like a Fil-C panic).

To learn more, check out [Explanation of Fil-C Disassembly](compiler_example.html).
