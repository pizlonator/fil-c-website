Welcome to Fil-C, a memory safe implementation of the C and C++ programming languages you already know and love.

## What is Fil-C?

Fil-C is a fanatically compatible memory-safe implementation of C and C++. Lots of software compiles and runs with Fil-C with zero or minimal changes. All memory safety errors are caught as Fil-C panics. Fil-C achieves this using a combination of concurrent garbage collection and invisible capabilities (InvisiCaps). Every possibly-unsafe C and C++ operation is checked. Fil-C has no `unsafe` escape hatch of any kind.

## Key Features

- **Memory Safety**: Advanced runtime checks to prevent [exploitable memory safety errors](invisicaps_by_example.html). Unlike other approaches to increasing the safety of C, Fil-C achieves complete memory safety with zero escape hatches.
- **C and C++ Compatibility**: Your C or C++ software most likely compiles and runs in Fil-C with zero changes. [Many open source programs](programs_that_work.html), including CPython, SQLite, OpenSSH, ICU and CMake work great in Fil-C. Even advanced features like threads, atomics, exceptions, signal handling, `longjmp`/`setjmp`, and shared memory (`mmap` style or Sys-V style) work.
- **Modern Tooling**: Compiler is based on a recent version of clang (20.1.8), supports all clang extensions, most GCC extensions, and works with existing C/C++ build systems (make, autotools, cmake, meson, etc).

## License

Fil-C's compiler is licensed under [Apache 2](https://github.com/pizlonator/fil-c/blob/deluge/LLVM-LICENSE.txt). Fil-C's runtime is licensed under [BSD 2-clause](https://github.com/pizlonator/fil-c/blob/deluge/libpas/LICENSE.txt). Fil-C's standard library is licensed under [MIT](https://github.com/pizlonator/fil-c/blob/deluge/projects/usermusl/COPYRIGHT).

## Documentation

- [Installation Guide](installation.html)
- [List of programs ported to Fil-C](programs_that_work.html)
- [InvisiCaps by Example](invisicaps_by_example.html)
- [Explanation of Fil-C Disassembly](compiler_example.html)
- [More on GitHub](https://www.github.com/pizlonator/fil-c/)

## Community

Join the [Fil-C Discord community](https://discord.gg/dPyNUaeajg) to discuss the language implementation, share projects, and contribute to its development.

