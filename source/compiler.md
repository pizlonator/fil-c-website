# Fil's Unbelievable C Compiler

Fil-C is a fork of clang 20.1.8 that includes:

- A new LLVM pass called [`llvm::FilPizlonator`](https://github.com/pizlonator/fil-c/blob/deluge/llvm/lib/Transforms/Instrumentation/FilPizlonator.cpp) that enforces [*garbage in, memory safety out*](gimso.md) semantics: either the pass will fail to generate any output (the compiler will crash), or the generated IR follows the [memory safety doctrine of Fil-C](invisicaps.html). So, the resulting code will get a [Fil-C panic](invisicaps_by_example.html) if it does something that violates the rules but otherwise has identical semantics to normal C/C++.

- Surgical changes to the clang frontend, including:

    - Small changes in clang CodeGen to make the generated LLVM code consistently use the `ptr` type for pointers as well as other tweaks to make the code obey Fil-C rules. In cases where CodeGen fails to obey these rules, the Fil-C checks end up being overzealous and a perfectly valid C or C++ program might get a Fil-C panic.

    - Changes to the clang Driver to support the [pizfix slice](pizfix.html), [`/opt/fil`](optfil.html), [Pizlix](pizlix.html), [filnix](https://github.com/mbrock/filnix), and [filian](https://cr.yp.to/2025/fil-c.html).

    - Changes to [BackendUtil.cpp](https://github.com/pizlonator/fil-c/blob/deluge/clang/lib/CodeGen/BackendUtil.cpp) to use a Fil-C pass pipeline that invokes the `FilPizlonator`.

- Surgical changes to LLVM itself, to remove or slightly tweak optimizations that fail to follow Fil-C rules. These changes only affect passes when they run before `FilPizlonator` in the pipeline. In particular, [`DataLayout`](https://github.com/pizlonator/fil-c/blob/deluge/llvm/include/llvm/IR/DataLayout.h) has a method to detect if the IR must follow Fil-C rules.

## The `FilPizlonator`

This pass applies memory safety rules *to every single construct in LLVM IR*, including:

- How values of `ptr` type are represented in SSA data flow. These get lowered to a [*flight pointer*](invisicaps.html#flightptr): a tuple containing the lower bound pointer (which doubles as the capability object pointer) and the pointer's *intval* (i.e. raw value under the control of the C program).

- All memory access instructions, including SIMD memory access intrinsics. Loads, stores, atomic CAS, atomic RMW, and memory transfer instructions have bounds checking prepended. Any operation that may operate on pointers (i.e. may store pointers to the heap or load pointers from the heap) is also modified to obey the [*rest pointer*](invisicaps.html#restptr) protocol.

- All control flow instructions, including computed goto (i.e. `indirectbr`) and function calls. Function calls check that the pointer you're calling is a valid function and the calling convention is totally changed to ensure that type confusion of arguments and return values has safe outcomes.

- All kinds of allocations (globals and `alloca`s). `alloca`s are converted to calls to [FUGC](fugc.html) allocation APIs.

- All linker shenanigans (including ifuncs, comdats, etc).

- All assembly (module level and inline). In practice this means that assembly is effectively disallowed (but blank assembly idioms, which are super common, work as expected).

- Everything else in LLVM IR.

`FilPizlonator` will turn code into an always-panic if it doesn't know how to check it. If the code is particularly evil, `FilPizlonator` will simply crash and refuse to compile.

`FilPizlonator` also has [extensive support for accurate GC](safepoints.html), including:

- [Inserting pollchecks at back edges](safepoints.html#pollchecks).

- [Tracking pointers in Pizderson frames](safepoints.html#pizderson). A Pizderson frame is like a [Henderson frame](https://dl.acm.org/doi/10.1145/512429.512449) except optimized for non-moving GC. Pointer register allocation is still possible since pointers are just mirrored into Pizderson frames, as opposed to being outright stored there like a Henderson frame.

`FilPizlonator` started out as a zero-optimizations, instrument-everything-with-function-calls style, since I wasn't even sure if the technique would conceptually work out. [Since it did work out](programs_that_work.html), many optimizations have been added:

- Allocations and many other intrinsic operations are now inlined.

- Bounds checks are scheduled and redundant ones are removed. (However, this is an area that could be massively improved).

- Local variables are escape-analyzed so that those that are treated as escaping for SROA, but don't actually escape in the classic sense, are stack-allocated rather than heap-allocated.

- Many other small optimizations.

## Clang CodeGen Changes

Clang's CodeGen module lowers the AST (abstract syntax tree) into LLVM IR. The AST still contains C/C++ types, while LLVM IR uses a lower-level type system. A key insight of Fil-C is that clang CodeGen is mostly well-behaved with respect to pointers. Values that would have been thought of as having pointer type by the C or C++ programmer (so any `*` pointer or `&` reference, as well as any struct or class that contains pointers) are lowered to LLVM IR that uses the `ptr` type.

There are two major exceptions to this property of CodeGen, and to make Fil-C work, surgical changes had to be made to make CodeGen completely preserve pointer intent:

- `CGAtomic`, the part of CodeGen that deals with atomics, normally bitcasts pointers to integers in many cases. This is mostly to address a limitation in older LLVM IR, where atomic instructions only worked on integer type. This limitation no longer holds, so the Fil-C compiler changes `CGAtomic` to use `ptr` type for pointers, just like the rest of CodeGen would.

- C++-related lowering, for things like vtables and method pointers. This code contained many uses of integer-sized pointers to pass pointers around. This is correct in non-Fil-C LLVM IR because a pointer is nothing more than an integer. But to make C++ work with Fil-C, those uses of integer-sized pointers had to be changed to uses of `ptr`.

## Clang Driver

GCC and compatible compilers like clang have a *driver* process that takes command-line arguments from the user and transforms them into internal command-line arguments taken by the actual compiler process. The driver's responsibilities include:

- Figuring out where system headers are located (like `stdio.h` and `unistd.h`).

- Figuring out where C++ headers are located (like `vector` and `thread`).

- Figuring out where compiler-provided headers are located (like `stddef.h`, `stdatomic.h`, and `immintrin.h`).

- Figuring out how to invoke the linker.

- Figuring out where system libraries are located and how to link to them (like knowing to pass `-L/usr/lib -lc`, knowing to pass `-lm` by default for C++ builds, and knowing whether to pass `-lpthread`)

- Figuring out where the libc-provided crt files are (like `crti.o`).

- Figuring out where the compiler-provided crt files and builtin libraries are (like `crtbegin.o` and `libgcc.a`).

Every operating system has opinions about these things, and the clang driver knows about the opinions of every operating system supported by clang.

Fil-C has its own opinions, which vary a bit depending on how the Fil-C compiler and runtime are distributed. Some things that are common across distributions:

- Fil-C requires both a yolo libc (a libc compiled with Yolo-C) and a user libc (a libc compiled with Fil-C). The yolo libc is found with `-lyoloc`.

- Fil-C always requires the yolo libm, i.e. `-lyolom`, since the Fil-C runtime calls a few math functions.

- Fil-C has its own runtime called `libpizlo.so`, i.e. `-lpizlo`.

- Fil-C always uses the LLVM compiler-rt versions of crt and builtins, which ship as `crtbegin.o`, `crtend.o`, and `libyolort.a` (i.e. `-lyolort`).

- Fil-C always links a dummy `libyolounwind.a`, i.e. `-lyolounwind`, which just contains stubs. These are only used by glibc. Because it's a static library, they only get pulled in if you do a static build and you're linking to glibc.

- Fil-C has its own additional crt trampilines for executables, `filc_crt.o` (for normal builds) and `filc_mincrt.o` (for `-nodefaultlibs` builds).

- Fil-C uses its own loader, called `ld-yolo-x86_64.so`.

The clang driver contains changes to link these additional libraries and object files, as necessary.

Finally, depending on what kind of Fil-C distribution you are using, the driver takes different paths for working out the header file and library locations:

- In a [pizfix](pizfix.html) distribution, all system headers and libraries are found in the `../../pizfix` directory, relative to the location of the driver's executable. All compiler-provided headers are found in `../lib/clang` relative to the driver's executable. The driver automatically puts itself in pizfix mode if it locates a `../../pizfix` directory relative to the drivers' executable.

- In a [`/opt/fil`](optfil.html) distribution, all system and compiler headers and libraries are found in `/opt/fil`. The driver automatically puts itself in `/opt/fil` mode if it sees that the driver's executable is in `/opt/fil/bin`.

- In a [filnix](https://github.com/mbrock/filnix) distribution, there is a wrapper for the compiler driver that passes special arguments to specify the locations of headers and libraries.

- In a [Pizlix](pizlix.html) distribution, all system and compiler headers and libraries are found in system-default paths like `/usr/include` and `/lib`. The driver knows that it is in Pizlix mode if none of the other conditions hold.

## The Fil-C Pass Pipeline

Below is a graphic showing the Fil-C pass pipeline.

<img src="llvm-pipeline.svg" class="centered-svg-60" alt="Fil-C pass pipeline">

Fil-C reuses the LLVM pass pipeline after `FilPizlonator`, and also runs a mini version of that pipeline before `FilPizlonator`. The pre-pizlonating passes achieve:

- Promotion of locals to registers. This is the job of passes like SROA. Note, due to clang CodeGen and SROA changes, SROA will give up on any local that has `union`-like behavior. This is why `FilPizlonator`'s escape analysis capability is so important.

- Inlining.

- Elimination of obviously redundant loads and stores.

- Lots of other optimizations (like all of the ones in InstCombine).

