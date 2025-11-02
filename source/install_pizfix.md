# Installing The Pizfix Distribution

The most unobtrusive way to try out Fil-C is using a [pizfix slice](pizfix.html) binary release.

Fil-C currently only supports Linux/X86_64.

## Download And Install

You can [download binary releases from the Fil-C GitHub](https://github.com/pizlonator/fil-c/releases). The Pizfix slice binary releases are named [`filc-0.674-linux-x86_64.tar.xz`](https://github.com/pizlonator/fil-c/releases/download/v0.674/filc-0.674-linux-x86_64.tar.xz).

Once you download a release and unpack it, simply run:

    ./setup.sh

from the directory that you unpacked it to (for example `/home/pizlo/filc-0.674-linux-x86_64`). At that point, you can run the compiler using `build/bin/clang` or `build/bin/clang++` (or via absolute path, for example `/home/pizlo/filc-0.674-linux-x86_64/build/bin/clang`).

This kind of Fil-C installation operates using the [pizfix slice](pizfix.html): the Fil-C libraries are in the `pizfix/lib` directory, and the headers are in `pizfix/include`. The compiler automatically knows how to find those headers and libraries, and will link programs in such a way that they will look for their dependent shared libraries there.

The pizfix binary releases of Fil-C use musl as the libc.

## Try It Out

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

