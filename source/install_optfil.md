# Installing The `/opt/fil` Distribution

My favorite way to demonstrate is using a [`/opt/fil`](optfil.html) binary release.

Fil-C currently only supports Linux/X86_64.

## Binary Release

You can [download binary releases from the Fil-C GitHub](https://github.com/pizlonator/fil-c/releases). The `/opt/fil` binary releases are named `optfil-0.673-linux-x86_64.tar.xz`.

Once you download a release and unpack it, simply run:

    sudo ./setup.sh

Assuming the script finds no issues, it will prompt you if you really want to unpack the `/opt/fil`. Type `YES` (in all caps).

This style of Fil-C installation places all Fil-C headers, libraries, and tools in the [`/opt/fil` slice](optfil.html). The compiler automatically knows how to find those headers and libraries and will link programs in such a way that they will look for their dependent shared libraries there.

# Try It Out

First, add `/opt/fil/bin` to your `$PATH`:

    export PATH=/opt/fil/bin:$PATH

Then assuming you have this simple C program called `hello.c`:

    #include <stdio.h>
    
    int main() {
        printf("Hello from Fil-C!\n");
        return 0;
    }

You can compile it using the Fil-C compiler like so:

    filcc -O2 -g -o hello hello.c

Note that this is also using Fil-C since `filcc` is invoking a memory-safe build of the GNU linker (`/opt/fil/bin/ld`).

Similarly C++ just works:

    #include <iostream>

    using namespace std;

    int main() {
        cout << "Hello!" << endl;
        return 0;
    }

This builds with `clang++` like so:

    fil++ -O2 -g -o hello hello.cpp

The `/opt/fil` distribution also includes useful programs, like `ssh`, `mg`, and `bash`. You can even launch a memory-safe OpenSSH server using `/opt/fil/sbin/sshd`!

