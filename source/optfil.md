# `/opt/fil`

My favorite way to [install Fil-C is the `/opt/fil` distribution](install_optfil.html). This distribution's benefits are that it:

- Places a Fil-C slice into the `/opt/fil` prefix, allowing Fil-C to be used by **everyone on the system**. Just add `/opt/fil/bin` to your `$PATH` if you want to use the Fil-C versions of software.

- **Installs the compiler** as `filcc` (for C) and `fil++` (for C++), so there's no ambiguity between invoking your system compiler (`gcc` or `clang`) and the Fil-C compiler.

- Uses the Fil-C port of **glibc 2.40** as the C library. This gives you the **maximum compatibility** with modern Linux software.

- Comes with **a bunch useful programs and libraries** compiled with Fil-C so they are memory safe:
    - bash        
    - binutils    
    - bzip2       
    - coreutils   
    - **curl**
    - diff        
    - find        
    - flex        
    - gawk        
    - **git**       
    - grep        
    - gzip        
    - icu4c       
    - kerberos5 
    - keyutils    
    - less      
    - libaudit    
    - libevent    
    - libidn2     
    - libpsl      
    - libselinux  
    - libtasn1  
    - libuv
    - libxcrypt
    - lz4
    - m4
    - make        
    - mg          
    - nghttp2
    - **openssh**   
    - **openssl**     
    - p11-kit
    - **pam**         
    - patch     
    - pcre2       
    - pkgconf     
    - procps-ng   
    - psmisc      
    - sed         
    - **sudo**      
    - tar         
    - tmux        
    - unistring   
    - wget
    - xz        
    - zlib        
    - zstd        

`/opt/fil` is laid out as follows:

- The compiler is `/opt/fil/bin/filcc` and `/opt/fil/bin/fil++`. These are symlinks to `/opt/fil/bin/filcc-clang-20`.

- Fil-C system headers are in `/opt/fil/include`.

- All of the compiler's headers are in `/opt/fil/lib/clang/20/include`.

- Libraries built with Fil-C, as well as core Fil-C libraries (like `libpizlo.so`), are in `/opt/fil/lib`.

- Fil-C programs use `/etc` for configuration files. This means, for example, that the OpenSSH server tin `/opt/fil/sbin/sshd` will use your system's `sshd_config` and host keys. If that configuration calls for PAM or Kerberos V, then that should work: the `/opt/fil` distribution comes with PAM and Kerberos V libraries, and those will also search `/etc` for their configuration files.

- Programs compiled with Fil-C are in `/opt/fil/bin` and `/opt/fil/sbin`.

This allows Fil-C libraries and programs to coexist with non-Fil-C libraries and programs on any modern Linux distribution. Segregating Fil-C libraries and binaries into a separate directory structure avoids [ABI compatibility problems](runtime.html). The Fil-C compiler is smart enough to know that if it finds itself installed in `/opt/fil/bin`, then it should:

- Use `/opt/fil/include` and `/opt/fil/lib/clang/20/include` for headers.
- Use `/opt/fil/lib` for libraries and CRT object files.
- Use `/opt/fil/bin/ld` as its linker.

The alternatives to `/opt/fil` are the [pizfix slice](pizfix.html) and the [Pizlix Linux distribution](pizlix.html).
