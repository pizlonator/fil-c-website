# Installing

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

To build Fil-C from source, first clone the repository:

    git clone --depth 1 https://github.com/pizlonator/fil-c.git

Parameter `--depth 1` creates a shallow clone, which is faster and uses less disk space. This is recommended for most users.

Change into the `fil-c` directory:

    cd fil-c

### Building Fil-C

To build the base Fil-C compiler and libraries (same as the binary release):

    ./build_all_fast.sh

To build the full Fil-C corpus (includes ported programs like Python, zsh, etc.):

    ./build_all.sh

After building, you will find:

- The compiler in `build/bin`
- Libraries in `pizfix/lib`
- Ported programs in `pizfix/bin`

### Building Environment Setup

#### Arch Linux

Install dependencies:

    sudo pacman -S base-devel cmake ninja ruby patchelf clang

Install the required Ruby gem:

    gem install getoptlong

Build Fil-C as described above.

#### Ubuntu (25.04)

Install dependencies:

    sudo apt install build-essential cmake ninja-build ruby patchelf clang

Build Fil-C as described above.

#### Fedora (Workstation 42)

Install dependencies:

    sudo dnf group install development-tools
    sudo dnf install cmake ninja-build ruby patchelf clang

Install the required Ruby gem:

    gem install getoptlong

Build Fil-C as described above.

### Container (Docker/Podman)

A `Dockerfile` is provided to set up a build environment for Fil-C:

Build the image:

    docker build -t fil-c .

Run a container interactively:

    docker run -it --rm \
      --mount type=bind,source="${HOME}/projects/fil-c",target="/opt/fil-c" \
      fil-c

This command assumes you cloned the Fil-C repository into `${HOME}/projects/fil-c`, adjust the `source` path as needed. Inside the container, build Fil-C as described above.

Dockerfile Reference:

    FROM ubuntu:25.04

    # Prevent tzdata interactive prompts during install
    ENV DEBIAN_FRONTEND=noninteractive

    # Update system packages
    RUN apt update && apt upgrade -y

    # Install essential build tools
    RUN apt install -y build-essential

    # Install required development dependencies
    RUN apt install -y \
        pkg-config autotools-dev automake autoconf libtool \
        clang cmake ninja-build ruby patchelf

    # Install basic utilities
    RUN apt install -y vim git

    # Create project source directory
    RUN mkdir -p /opt/fil-c

    # Set working directory
    WORKDIR /opt/fil-c

    # Start an interactive shell by default
    CMD /usr/bin/bash

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

For examples of Fil-C catching memory safety issues, see
[InvisiCaps By Example](invisicaps_by_example.html). For a list of programs that have been ported to
Fil-C, see [Programs That Work](programs_that_work.html).

