# Installing From Source

Clone Fil-C from GitHub:

    git clone https://github.com/pizlonator/fil-c.git

Source releases can be built in four different ways:

1. Fast build with musl using `./build_all_fast.sh`.
2. Fast build with glibc using `./build_all_fast_glibc.sh`.
3. Full build with musl using `./build_all.sh`.
4. Full build with glibc using `./build_all_glibc.sh`.
5. [`/opt/fil`](optfil.html) build using `cd optfil; sudo ./build.sh`. This builds the glibc-based `/opt/fil` slice and requires root privileges.
6. [Pizlix](pizlix.html) build using `cd pizlix; sudo ./build.sh`. This builds the glibc-based Pizlix Linux distribution where all of userland is compiled with Fil-C. Requires root privileges and a [specific set of preparations inspired by LFS](pizlix.html).

The fast build (options 1 and 2) just builds the compiler, runtime, libc (either musl or glibc), libc++abi, and libc++. When building with glibc, the fast build also builds libxcrypt.

The full build (options 3 and 4) builds everything that the fast build builds plus the full Fil-C corpus, i.e. [most of the programs that have been ported to Fil-C](programs_that_work.html). Full builds require more prerequisites and take much longer.

The [`/opt/fil`](optfil.html) and [Pizlix](pizlix.html) builds give you the most complete Fil-C-based environments. The `/opt/fil` environment is ideal for having a Fil-C slice coexist with non-Fil-C code on a single Linux machine. The Pizlix build gives you a full Linux system where everything is memory safe.

# Try It Out

Assuming you used either a fast build or a full build (so not `/opt/fil` or Pizlix), you will get a [pizfix slice](pizfix.html):

- The compiler will be in `./build/bin/clang`.
- All of the libraries and headers will be in `./pizfix`.

Once you have this build then you can try out Fil-C by writing a simple program, say `hello.c`:

You can compile it using `<path to Fil-C>/build/bin/clang` like so:

    build/bin/clang -O2 -g -o hello hello.c

Similarly C++ just works:

    #include <iostream>

    using namespace std;

    int main() {
        cout << "Hello!" << endl;
        return 0;
    }

This builds with `clang++` like so:

    build/bin/clang++ -O2 -g -o hello hello.cpp

If you did a full build, you will also have a bunch of useful programs in `pizfix/bin` that are all compiled with Fil-C.

