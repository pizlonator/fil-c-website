# How Fil-C Works

Fil-C achieves memory safety for C and C++ code by [transforming](compiler.html) [all unsafe operations in LLVM IR](gimso.html) into code that does dynamic checking to catch all violations of Fil-C’s rules. Most of that is about transforming all operations involving `ptr` type to use [InvisiCaps](invisicaps.html).

I’ve also written about InvisiCaps [using examples of issues that this catches](invisicaps_by_example.html) and by doing a [deep dive into the disassembly of a simple program](compiler_example.html). 

InvisiCaps could work with a variety of memory management schemes, including sufficiently segregated malloc/free. However, they can produce the best guarantees with a GC. GC allows the `free()` operation to deterministically and atomically disable all pointers to the memory that was freed, so use after free, invalid free, and double free are all guaranteed to panic. For this reason, [Fil-C uses a concurrent garbage collector](fugc.html).

All C implementations rely on a runtime that provides helper functions for those operations that are just heavy enough to warrant outlining. Fil-C differs in that its [runtime is bigger and involves a different ABI from Yolo-C](runtime.html). The runtime’s job is also to provide a [safepoint mechanism to support accurate GC and safe signal handling](safepoints.html). 

Despite the fact that Fil-C’s implementation strategy differs from Yolo-C’s, [it’s possible to compile most C and C++ programs with Fil-C and they will work great with zero or minimal changes](programs_that_work.html). 

Because Fil-C is not ABI compatible with Yolo-C, installing Fil-C means installing a new ABI slice. Multiple approaches to this exist. The original approach I developed to get my own development bootstrapped is the [pizfix](pizfix.html) (Pizlo’s prefix), which puts all Fil-C libraries into a local directory and the compiler knows to default to that directory for headers and libraries. A much more comprehensive approach is to just [recompile all of the Linux userland](pizlix.html). My favorite way to install Fil-C is the [/opt/fil distribution](optfil.html). I’m currently working on making this include more programs and libraries. You should install this if you want to run a memory safe SSH server. Folks have started to contribute their own Fil-C distributions. Mikael Brockman created a Nix package of the Fil-C compiler, called [Filnix](https://github.com/mbrock/filnix). Daniel J Bernstein has [a lot of notes about using Fil-C including scripts to set up Filian - Debian with a Fil-C variant](https://cr.yp.to/2025/fil-c.html).

Finally, Fil-C exposes a lot of power that you won’t get in Yolo-C, like for introspecting pointer capabilities and using advanced GC features. That API is easy to include and [well documented](stdfil.html). 

More reading:

- [Installing Fil-C](installation.html)

- [Documentation](documentation.html)

