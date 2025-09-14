# Fil's Unbelievable C Compiler

Fil-C is a fork of clang 20.1.8 that includes:

- A new LLVM pass called [`llvm::FilPizlonator`](https://github.com/pizlonator/fil-c/blob/deluge/llvm/lib/Transforms/Instrumentation/FilPizlonator.cpp) that enforces *garbage in, memory safety out* semantics: either the pass will fail to generate any output (the compiler will crash), or the generated IR follows the [memory safety doctrine of Fil-C](invisicaps.html). So, the resulting code will get a [Fil-C panic](invisicaps_by_example.html) if it does something that violates the rules but otherwise has identical semantics to normal C/C++.

- Surgical changes to the clang frontend, including:

    - Small changes in clang CodeGen to make the generated LLVM code consistently use the `ptr` type for pointers as well as other tweaks to make the code obey Fil-C rules. In cases where CodeGen fails to obey these rules, the Fil-C checks end up being overzealous and a perfectly valid C or C++ program might get a Fil-C panic.

    - Changes to the clang Driver, mostly to support the [pizfix slice](pizfix.html).

    - Changes to [BackendUtil.cpp](https://github.com/pizlonator/fil-c/blob/deluge/clang/lib/CodeGen/BackendUtil.cpp) to use a Fil-C pass pipeline that invokes the `FilPizlonator`.

- Surgical changes to LLVM itself, to remove or slightly tweak optimizations that fail to follow Fil-C rules. These changes only affect passes when they run before `FilPizlonator` in the pipeline. In particular, [`DataLayout`](https://github.com/pizlonator/fil-c/blob/deluge/llvm/include/llvm/IR/DataLayout.h) has a method to detect if the IR must follow Fil-C rules.

## The `FilPizlonator`

This pass applies memory safety rules *to every single construct in LLVM IR*, including:

- All memory access instructions, including SIMD memory access intrinsics.

- All control flow instructions, including computed goto (i.e. `indirectbr`) and function calls. Function calls check that the pointer you're calling is a valid function and the calling convention is totally changed to ensure that type confusion of arguments and return values has safe outcomes.

- All kinds of allocations (globals and `alloca`s).

- All linker shenanigans (including ifuncs, comdats, etc).

- All assembly (module level and inline). In practice this means that assembly is effectively disallowed (but blank assembly idioms, which are super common, work as expected).

- Everything else in LLVM IR.

`FilPizlonator` will turn code into an always-panic if it doesn't know how to check it. If the code is particularly evil, `FilPizlonator` will simply crash and refuse to compile.

`FilPizlonator` also has extensive support for [accurate GC](fugc.html), including:

- Inserting pollchecks at back edges.

- Tracking pointers in Pizderson frames. A Pizderson frame is like a [Henderson frame](https://dl.acm.org/doi/10.1145/512429.512449) except optimized for non-moving GC. Pointer register allocation is still possible since pointers are just mirrored into Pizderson frames, as opposed to being outright stored there like a Henderson frame.

`FilPizlonator` started out as a zero-optimizations, instrument-everything-with-function-calls style, since I wasn't even sure if the technique would conceptually work out. [Since it did work out](programs_that_work.html), many optimizations have been added:

- Allocations and many other intrinsic operations are now inlined.

- Bounds checks are scheduled and redundant ones are removed. (However, this is an area that could be massively improved).

- Local variables are escape-analyzed so that those that are treated as escaping for SROA, but don't actually escape in the classic sense, are stack-allocated rather than heap-allocated.

- Many other small optimizations.

## The Fil-C Pass Pipeline

Below is a graphic showing the Fil-C pass pipeline.

<img src="llvm-pipeline.svg" class="centered-svg-60" alt="Fil-C pass pipeline">

Fil-C reuses the LLVM pass pipeline after `FilPizlonator`, and also runs a mini version of that pipeline before `FilPizlonator`. The pre-pizlonating passes achieve:

- Promotion of locals to registers. This is the job of passes like SROA. Note, due to clang CodeGen and SROA changes, SROA will give up on any local that has `union`-like behavior. This is why `FilPizlonator`'s escape analysis capability is so important.

- Inlining.

- Elimination of obviously redundant loads and stores.

- Lots of other optimizations (like all of the ones in InstCombine).

