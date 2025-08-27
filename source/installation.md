# Installing Fil-C

The easiest way to install [Fil-C](index.html) is using a binary release. It's also possible to build from source.

Fil-C currently only supports Linux/X86_64.

## Binary Release

You can download binary releases [from the Fil-C GitHub](https://github.com/pizlonator/fil-c/releases).

Once you download a release and unpack it, simply run:

    ./setup.sh

from the directory that you unpacked it to (for example `/home/pizlo/filc-0.670-linux-x86_64`). At that point, you can run the compiler using `build/bin/clang` or `build/bin/clang++` (or via absolute path, for example `/home/pizlo/filc-0.670-linux-x86_64/build/bin/clang`).

Note that the Fil-C libraries are in the `pizfix/lib` directory, and the headers are in `pizfix/include`.

The compiler automatically knows how to find those headers and libraries, and will link programs in such a way that they will look for their dependent shared libraries there.

## Source Release

Clone Fil-C from GitHub:

    git clone https://github.com/pizlonator/fil-c.git

You can build just the base Fil-C (what comes in the binary release) by doing:

    ./build_all_fast.sh

In the `fil-c` directory. If you want to also build the Fil-C corpus, which includes a bunch of programs ported to Fil-C (like Python, zsh, and others)), then do:

    ./build_all.sh

---

[*Fil-C: Systems programming with confidence.*](index.html)

