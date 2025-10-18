# `/opt/fil`

My favorite way to [install Fil-C is the `/opt/fil` distribution](install_optfil.html), which places a Fil-C slice into the `/opt/filc` prefix. In this world:

- The compiler is `/opt/fil/bin/filcc` and `/opt/fil/bin/fil++`.

- All of the compiler's headers are in `/opt/fil/lib/clang/20/include`.

- Fil-C system headers are in `/opt/fil/include`.

- Fil-C libraries are in `/opt/fil/lib`.

- Programs compiled with Fil-C are in `/opt/fil/bin` and `/opt/fil/sbin`.

Additionally, `/opt/fil/bin/pkgconf` knows about the packages available in `/opt/fil`.

This allows Fil-C libraries and programs to coexist with non-Fil-C libraries and programs on any modern Linux distribution.

The alternatives to `/opt/fil` are the [pizfix slice](pizfix.html) and the [Pizlix Linux distribution](pizlix.html).
