# Installing

The easiest way to install [Fil-C](index.html) is using a binary release. It's also possible to build from source.

Fil-C currently only supports Linux/X86_64.

## Binary Release

You can [download binary releases from the Fil-C GitHub](https://github.com/pizlonator/fil-c/releases).

Once you download a release and unpack it, simply run:

    ./setup.sh

from the directory that you unpacked it to (for example `/home/pizlo/filc-0.672-linux-x86_64`). At that point, you can run the compiler using `build/bin/clang` or `build/bin/clang++` (or via absolute path, for example `/home/pizlo/filc-0.672-linux-x86_64/build/bin/clang`).

The Fil-C installation currently operates using the [pizfix slice](pizfix.html): the Fil-C libraries are in the `pizfix/lib` directory, and the headers are in `pizfix/include`. The compiler automatically knows how to find those headers and libraries, and will link programs in such a way that they will look for their dependent shared libraries there.

Binary releases of Fil-C use musl as the libc.

## Source Release

Clone Fil-C from GitHub:

    git clone https://github.com/pizlonator/fil-c.git

Source releases can be built in four different ways:

1. Fast build with musl using `./build_all_fast.sh`.
2. Fast build with glibc using `./build_all_fast_glibc.sh`.
3. Full build with musl using `./build_all.sh`.
4. Full build with glibc using `./build_all_glibc.sh`.

Building with glibc means getting a more GNU/Linux-compatible environment. Some software (like coreutils and OpenSSH) have minor issues or missing features when built against musl.

The fast build just builds the compiler, runtime, libc (either musl or glibc), libc++abi, and libc++. When building with glibc, the fast build also builds libxcrypt.

The full build builds everything that the fast build builds plus the full Fil-C corpus, i.e. [most of the programs that have been ported to Fil-C](programs_that_work.html). Full builds require more prerequisites and take much longer.

The most well-supported option right now is:

    ./build_all_fast.sh

This gives you the same environment you would get if you downloaded a binary release.

# Try It Out

Consider this simple C program; let's call it `hello.c`:

    #include <stdio.h>
    
    int main() {
        printf("Hello from Fil-C!\n");
        return 0;
    }

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

Additional reading:

- For examples of Fil-C catching memory safety issues, see
[InvisiCaps By Example](invisicaps_by_example.html).

- For a list of programs that have been ported to Fil-C, see [Programs That Work](programs_that_work.html).

- For more information about your Fil-C installation, see [Pizfix: The Fil-C Staging Area](pizfix.html) and [Fil-C Runtime](runtime.html).


