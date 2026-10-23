# Peregrine Fil-C: Actually Portable Memory Safe Executables

Since version 0.687, Fil-C can build a [runtime sandwich](runtime.html) using a fork of
[Cosmopolitan](https://github.com/jart/cosmopolitan). This combination is called **Peregrine Fil-C**
and gives you a compiler that:

- Supports all of Fil-C's [memory safety](gimso.html) and [garbage collection](fugc.html) features.
- Produces executables that run on Linux/x86\_64, Darwin/aarch64, and Windows/x86\_64.

This is still experimental. Simple programs seem to work great. The main limitations are that the
libc doesn't support nearly the same API surface as either native Cosmopolitan, or the
[musl](pizfix.html) or [glibc](optfil.html) releases of Fil-C.

Download: [perefil-0.687-linux-x86_64.tar.xz](https://github.com/pizlonator/fil-c/releases/download/v0.687/perefil-0.687-linux-x86_64.tar.xz)


