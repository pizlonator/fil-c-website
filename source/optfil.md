# `/opt/fil`

My favorite way to [install Fil-C is the `/opt/fil` distribution](install_optfil.html), which places a Fil-C slice into the `/opt/fil` prefix. This distribution comes with many useful programs and libraries that have been ported to Fil-C, so they are totally memory safe:

- bash        
- binutils    
- bzip2       
- coreutils   
- curl
- diff        
- find        
- flex        
- gawk        
- git       
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
- lz4         
- make        
- mg          
- nghttp2
- openssh   
- openssl     
- p11-kit
- pam         
- patch     
- pcre2       
- pkgconf     
- procps-ng   
- psmisc      
- sed         
- sudo      
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

- Fil-C libraries are in `/opt/fil/lib`.

- Fil-C programs use `/etc` for configuration files. This means, for example, that the OpenSSH server tin `/opt/fil/sbin/sshd` will use your system's `sshd_config` and host keys. If that configuration calls for PAM or Kerberos V, then that should work: the `/opt/fil` distribution comes with PAM and Kerberos V libraries, and those will also search `/etc` for their configuration files.

- Programs compiled with Fil-C are in `/opt/fil/bin` and `/opt/fil/sbin`.

This allows Fil-C libraries and programs to coexist with non-Fil-C libraries and programs on any modern Linux distribution. Segregating Fil-C libraries and binaries into a separate directory structure avoids [ABI compatibility problems](runtime.html). The Fil-C compiler is smart enough to know that if it finds itself installed in `/opt/fil/bin`, then it should:

- Use `/opt/fil/include` and `/opt/fil/lib/clang/20/include` for headers.
- Use `/opt/fil/lib` for libraries and CRT object files.
- Use `/opt/fil/bin/ld` as its linker.

The alternatives to `/opt/fil` are the [pizfix slice](pizfix.html) and the [Pizlix Linux distribution](pizlix.html).
