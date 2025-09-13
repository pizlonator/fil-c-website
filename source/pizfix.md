# Pizfix: The Fil-C Staging Area

Fil-C is fanatically compatible with C/C++ at the source level, but [not compatible at all at the ABI level](runtime.html). This means that:

- Fil-C cannot share headers with your system. You cannot `#include` anything from `/usr/include`, for example.

- Fil-C cannot share libraries with your system. You cannot link to any thing in `/usr/lib`, for example.

Fil-C requires its own separate *slice* of headers, libraries, and executables. This document describes the current approach (called the Pizfix) as well as two potential alternative approaches (Pizlix and `/opt/filc`).

## The Pizfix Slice

When you [install](installation.html) Fil-C, either from source or from binary, you will get relevant libraries, binaries, and headers in two places, assuming you unpacked Fil-C in the `fil-c` directory:

- `fil-c/build/` contains clang and clang's own headers. For example, you can run clang using `fil-c/build/bin/clang` or `fil-c/build/bin/clang++`.

- `fil-c/pizfix/` contains the Fil-C system headers and libraries. For example:

    - `fil-c/pizfix/include/` contains libc headers.

    - `fil-c/pizfix/lib/` contains Fil-C [libraries](runtime.html), including `libc.so` and `libpizlo.so`.

This allows for users to easily set up a Fil-C slice anywhere on their Linux machine, and the Fil-C compiler and loader both search for headers and libraries in the pizfix. The compiler knows to do this by finding the pizfix relative to the location of its own binary. The clang driver is just doing this logic:

1. Observe that the clang binary is at `filc/build/bin/clang`.

2. Locate clang's own headers in `filc/build/bin/../lib/clang/20/include`.

3. Locate the pizfix at `filc/build/bin/../../pizfix`.

4. Locate the headers in `filc/build/bin/../../pizfix/include`.

5. Locate the libraries in `filc/build/bin/../../pizfix/lib`.

When installing additional libraries and software, it's easiest to tell the build system that `--prefix=fil-c/pizfix` - i.e. put all software in the pizfix staging area. Additionally, it's useful to build `pkgconf` and put it in the pizfix and then run all build systems with `PATH=fil-c/pizfix/bin:$PATH` so that various packages in the pizfix are able to find one another the "pkg" way.

Currently, the Fil-C clang will only pull this trick if it locates the pizfix. Otherwise, it will look for headers and libraries the normal Linux way (i.e. `/usr/include`, `/lib`, and `/usr/lib`). In other words, Fil-C is already set up to support being used as the primary slice of a Linux distribution with a Fil-C userland.

## The Pizlix Distribution

One implication of Fil-C is that it is possible to build a Linux distribution where the entire userland is memory safe. Fil-C has already demonstrated sufficient compatibility with C/C++ to make this a reality. It hasn't been done yet, but it'll happen eventually. In such a distribution, there would either be no Yolo-C at all in userland, or the Yolo-C would be in a secondary slice (in some odd directory, not `/usr/include`/`/lib`/`/usr/lib`) in the same way that we currently put Fil-C in a secondary slice.

In Pizlix, there would be no staging area, and so the Fil-C compiler and loader would just use default Linux directories. This enables Fil-C-compiled software to just be installed with `--prefix/usr`.

Stay tuned for more information about Pizlix!

## The `/opt/filc` Slice

An alternative approach to making Fil-C available to users would be to have an `/opt/filc` prefix. In this world, we would:

- Rename clang to `/opt/filc/bin/filcc`.

- Place all of clang's headers in `/opt/filc/lib/clang/20/include`.

- Place Fil-C system headers in `/opt/filc/include`.

- Place Fil-C libraries in `/opt/filc/lib`.

This would be an awesome way to distribute Fil-C, and you could set it up yourself by hacking the current Fil-C install. This is likely superior to the pizfix slice. It's complementary to the Pizlix Distribution.


