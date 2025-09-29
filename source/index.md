Welcome to Fil-C, a memory safe implementation of the C and C++ programming languages you already know and love.

## What is Fil-C?

Fil-C is a fanatically compatible memory-safe implementation of C and C++. Lots of software compiles and runs with Fil-C with zero or minimal changes. All memory safety errors are caught as Fil-C panics. Fil-C achieves this using a combination of [concurrent garbage collection](fugc.html) and invisible capabilities ([InvisiCaps](invisicaps.html)). Every possibly-unsafe C and C++ operation is checked. Fil-C has no `unsafe` escape hatch of any kind.

## Key Features

- **Memory Safety**: Advanced runtime checks to prevent [exploitable memory safety errors](invisicaps_by_example.html). Unlike other approaches to increasing the safety of C, Fil-C achieves complete memory safety with zero escape hatches.
- **C and C++ Compatibility**: Your C or C++ software most likely compiles and runs in Fil-C with zero changes. [Many open source programs](programs_that_work.html), including CPython, OpenSSH, GNU Emacs, and Wayland work great in Fil-C. Even advanced features like threads, atomics, exceptions, signal handling, `longjmp`/`setjmp`, and shared memory (`mmap` style or Sys-V style) work. It's possible to run a [totally memory safe Linux userland](pizlix.html), including GUI, with Fil-C.
- **Modern Tooling**: [Compiler](compiler.html) is based on a recent version of clang (20.1.8), supports all clang extensions, most GCC extensions, and works with existing C/C++ build systems (make, autotools, cmake, meson, etc).

## Quick Links

- [Download Fil-C 0.671](https://github.com/pizlonator/fil-c/releases/tag/v0.671)
- [Installation Guide](installation.html)
- [InvisiCaps: The Fil-C Capability Model](invisicaps.html)
- [Fil's Unbelievable C Compiler](compiler.html)
- [Fil's Unbelievable Garbage Collector](fugc.html)
- [List of programs ported to Fil-C](programs_that_work.html)
- [*More Documentation*](documentation.html)

## License

Fil-C's compiler is licensed under [Apache 2](https://github.com/pizlonator/fil-c/blob/deluge/LLVM-LICENSE.txt). Fil-C's runtime is licensed under [BSD 2-clause](https://github.com/pizlonator/fil-c/blob/deluge/libpas/LICENSE.txt). Fil-C has two standard libraries; musl is used in binary distributions and is licensed under [MIT](https://github.com/pizlonator/fil-c/blob/deluge/projects/usermusl/COPYRIGHT), while glibc is available for source builds and in [Pizlix](pizlix.html) and is licensed under [LGPL 2.1](https://github.com/pizlonator/fil-c/blob/deluge/projects/user-glibc-2.40/COPYING.LIB).

## Community

Join the [Fil-C Discord community](https://discord.gg/dPyNUaeajg) to discuss the language implementation, share projects, and contribute to its development.

