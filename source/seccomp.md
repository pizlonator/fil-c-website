# Linux Sandboxes And Fil-C

Memory safety and sandboxing are two different things. It's reasonable to think of them as orthogonal: you could have memory safety but not be sandboxed, or you could be sandboxed but not memory safe.

- Example of **memory safe** *but not* **sandboxed**: a pure Java program that opens files on the filesystem for reading and writing and accepts filenames from the user. The OS will allow this program to overwrite any file that the user has access to. This program can be quite dangerous even if it is memory safe. Worse, imagine that the program didn't have any code to open files for reading and writing, but also had no sandbox to prevent those syscalls from working. If there was a bug in the memory safety enforcement of this program (say, because of a bug in the Java implementation), then an attacker could cause this program to overwrite any file if they succeeded at [achieving code execution via weird state](https://en.wikipedia.org/wiki/Weird_machine).

- Example of **sandboxed** *but not* **memory safe**: a program written in assembly that starts by requesting that the OS revoke all of its capabilities beyond just pure compute. If the program did want to open a file or write to it, then the kernel will kill the process, based on the earlier request to have this capability revoked. This program could have lots of memory safety bugs (because it's written in assembly), but even if it did, then the attacker cannot make this program overwrite any file unless they find some way to bypass the sandbox.

In practice, sandboxes have holes by design. A typical sandbox allows the program to send and receive messages to broker processes that have higher privileges. So, an attacker may first use a memory safety bug to make the sandboxed process send malicious messages, and then use those malicious messages to break into the brokers.

**The best kind of defense is to have both a sandbox and memory safety.** This document describes how to combine sandboxing and Fil-C's memory safety by explaining what it takes to port OpenSSH's seccomp-based Linux sandbox code to Fil-C.

## Background

[Fil-C is a memory safe implementation of C and C++](how.html) and this site [has a lot of documentation about it](documentation.html). Unlike most memory safe languages, Fil-C enforces safety down to where your code meets Linux syscalls and the [Fil-C runtime](runtime.html) is robust enough that it's possible to use it in [low-level system components like `init` and `udevd`](pizlix.html). [Lots of programs work in Fil-C](programs_that_work.html), including OpenSSH, which makes use of seccomp-BPF sandboxing.

This document focuses on how OpenSSH uses seccomp and other technologies on Linux to build a sandbox around its [unprivileged `sshd-session` process](http://www.citi.umich.edu/u/provos/ssh/privsep.html). Let's review what tools Linux gives us that OpenSSH uses:

- `chroot` to restrict the process's view of the filesystem.

- Running the process with the `sshd` user and group, and giving that user/group no privileges.

- `setrlimit` to prevent opening files, starting processes, or writing to files.

- seccomp-BPF syscall filter to reduce the attack surface by allowlisting only the set of syscalls that are legitimate for the unprivileged process. Syscalls not in the allowlist will crash the process with `SIGSYS`.

[The Chromium developers](https://chromium.googlesource.com/chromium/src/+/0e94f26e8/docs/linux_sandboxing.md) and [the Mozilla developers](https://wiki.mozilla.org/Security/Sandbox/Seccomp) both have excellent notes about how to do sandboxing on Linux using seccomp. [Seccomp-BPF is a well-documented kernel feature](https://www.kernel.org/doc/html/v4.19/userspace-api/seccomp_filter.html) that can be used as part of a larger sandboxing story.

Fil-C makes it easy to use `chroot` and different users and groups. The syscalls that are used for that part of the sandbox are trivially allowed by Fil-C and no special care is required to use them.

Both `setrlimit` and seccomp-BPF require special care because the Fil-C runtime starts threads, allocates memory, and performs synchronization. This document describes what you need to know to make effective use of those sandboxing technologies in Fil-C. First, I describe how to build a sandbox that prevents thread creation without breaking Fil-C's use of threads. Then, I describe what tweaks I had to make to OpenSSH's seccomp filter. Finally, I describe how the Fil-C runtime implements the syscalls used to install seccomp filters.

## Preventing Thread Creation Without Breaking The Fil-C Runtime

The Fil-C runtime uses [multiple background threads for garbage collection](fugc.html) and has the ability to automatically shut those threads down when they are not in use. If the program wakes up and starts allocating memory again, then those threads are automatically restarted.

Starting threads violates the "no new processes" rule that OpenSSH's `setrlimit` sandbox tries to achieve (since threads are just lightweight processes on Linux). It also relies on syscalls like `clone3` that are not part of OpenSSH's seccomp filter allowlist.

It would be a regression to the sandbox to allow process creation just because the Fil-C runtime relies on it. Instead, I added a new API to [`<stdfil.h>`](stdfil.html):

    void zlock_runtime_threads(void);

This forces the runtime to immediately create whatever threads it needs, and to disable shutting them down on demand. Then, I added a call to `zlock_runtime_threads()` in OpenSSH's `ssh_sandbox_child` function before either the `setrlimit` or seccomp-BPF sandbox calls happen.

## Tweaks To The OpenSSH Sandbox

Because the use of `zlock_runtime_threads()` prevents subsequent thread creation from happening, most of the OpenSSH sandbox just works. I did not have to change how OpenSSH uses `setrlimit`. I did change the following about the seccomp filter:

- Failure results in `SECCOMP_RET_KILL_PROCESS` rather than `SECCOMP_RET_KILL`. This ensures that Fil-C's background threads are also killed if a sandbox violation occurs.

- `MAP_NORESERVE` is added to the `mmap` allowlist, since the Fil-C allocator uses it. This is not a meaningful regression to the filter, since `MAP_NORESERVE` is not a meaningful capability for an attacker to have.

- `sched_yield` is allowed. This is not a dangerous syscall (it's semantically a no-op). The Fil-C runtime uses it as part of its lock implementation.

Nothing else had to change, since the filter already allowed all of the `futex` syscalls that Fil-C uses for synchronization.

## How Fil-C Implements `prctl`

The OpenSSH seccomp filter is installed using two `prctl` calls. First, we `PR_SET_NO_NEW_PRIVS`:

    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == -1) {
            debug("%s: prctl(PR_SET_NO_NEW_PRIVS): %s",
                __func__, strerror(errno));
            nnp_failed = 1;
    }

This prevents additional privileges from being acquired via `execve`. It's required that unprivileged processes that install seccomp filters first set the `no_new_privs` bit.

Next, we `PR_SET_SECCOMP, SECCOMP_MODE_FILTER`:

    if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &preauth_program) == -1)
            debug("%s: prctl(PR_SET_SECCOMP): %s",
                __func__, strerror(errno));
    else if (nnp_failed)
            fatal("%s: SECCOMP_MODE_FILTER activated but "
                "PR_SET_NO_NEW_PRIVS failed", __func__);

This installs the seccomp filter in `preauth_program`. Note that this will fail in the kernel if the `no_new_privs` bit is not set, so the fact that OpenSSH reports a fatal error if the filter is installed without `no_new_privs` is just healthy paranoia on the part of the OpenSSH authors.

The trouble with both syscalls is that they affect the calling *thread*, not all threads in the process. Without special care, Fil-C runtime's background threads would not have the `no_new_privs` bit set and would not have the filter installed. This would mean that if an attacker busted through Fil-C's memory safety protections (in the unlikely event that they found a bug in Fil-C itself!), then they could use those other threads to execute syscalls that bypass the filter!

To prevent even this unlikely escape, the Fil-C runtime's wrapper for `prctl` implements `PR_SET_NO_NEW_PRIVS` and `PR_SET_SECCOMP` by *handshaking* all runtime threads using this internal API:

    /* Calls the callback from every runtime thread. */
    PAS_API void filc_runtime_threads_handshake(void (*callback)(void* arg), void* arg);

The callback performs the requested `prctl` from each runtime thread. This ensures that the `no_new_privs` bit and the filter are installed on all threads in the Fil-C process.

Additionally, because of ambiguity about what to do if the process has multiple user threads, these two `prctl` commands will trigger a Fil-C safety error if the program has multiple user threads.

## Conclusion

The best kind of protection if you're serious about security is to combine memory safety with sandboxing. This document shows how to achieve this using Fil-C and the sandbox technologies available on Linux, all without regressing the level of protection that those sandboxes enforce or the memory safety guarantees of Fil-C.
