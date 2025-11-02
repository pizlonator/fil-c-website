# `/opt/fil`

My favorite way to [install Fil-C is the `/opt/fil` distribution](install_optfil.html), which places a Fil-C slice into the `/opt/filc` prefix. **This includes a memory-safe OpenSSH client and server** as well as many other useful programs compiled with Fil-C. In this world:

- The compiler is `/opt/fil/bin/filcc` and `/opt/fil/bin/fil++`. These are symlinks to `/opt/fil/bin/filcc-clang-20`.

- Fil-C system headers are in `/opt/fil/include`.

- All of the compiler's headers are in `/opt/fil/lib/clang/20/include`.

- Fil-C libraries are in `/opt/fil/lib`.

- Fil-C programs use `/etc` for configuration files. This means, for example, that the OpenSSH server tin `/opt/fil/sbin/sshd` will use your system's `sshd_config` and host keys. If that configuration calls for PAM or Kerberos V, then that should work: the `/opt/fil` distribution comes with PAM and Kerberos V libraries, and those will also search `/etc` for their configuration files.

- Programs compiled with Fil-C are in `/opt/fil/bin` and `/opt/fil/sbin`. This includes:
    - GNU bash
    - GNU coreutils
    - GNU binutils
    - Mg text editor
    - Compression utilities
    - OpenSSL library
    - OpenSSH client and server.
    - PAM
    - keyutils
    - audit
    - Kerberos V
    - PCRE2

Additionally, `/opt/fil/bin/pkgconf` knows about the packages available in `/opt/fil`.

This allows Fil-C libraries and programs to coexist with non-Fil-C libraries and programs on any modern Linux distribution. Segregating Fil-C libraries and binaries into a separate directory structure avoids [ABI compatibility problems](runtime.html). The Fil-C compiler is smart enough to know that if it finds itself installed in `/opt/fil/bin`, then it should:

- Use `/opt/fil/include` and `/opt/fil/lib/clang/20/include` for headers.
- Use `/opt/fil/lib` for libraries and CRT object files.
- Use `/opt/fil/bin/ld` as its linker.

The alternatives to `/opt/fil` are the [pizfix slice](pizfix.html) and the [Pizlix Linux distribution](pizlix.html).
