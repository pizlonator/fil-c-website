# The Fil-C Optimized Calling Convention

Fil-C achieves memory safety even for programs that behave adversarially. That includes casting function pointers to the wrong signature and then calling them, exporting a function with one signature in one module and then importing it with a different signature in another, or even exporting a symbol as a function in one module and importing it as data in another (and vice-versa). Passing too few arguments, arguments of the wrong type, misusing `va_list` (including escaping it), expecting too many values to be returned - these are all things that the Fil-C calling convention either catches with a panic or ascribes safe behavior to.

But in the common case - like when the programmer is behaving themselves - Fil-C generates reasonably efficient code for the call. For example, a call like this:

    int x = 42;
    const char* y = "hello";
    int z = foo(x, y);

in one module (say `caller.c`) with `foo` defined in another module (say `foo.c`):

    int foo(int x, const char* y)
    {
        ... /* whatever */
    }

will be compiled at the callsite exactly as if you had done the following call in Yolo-C with an optimized arguments-in-registers ABI:

    foo(my_thread, x, y);

Where `my_thread` is a pointer to the current Fil-C thread, which Fil-C passes around as the first argument in all calls. So, `my_thread`, `x`, and `y` will be passed in registers. The implementation of `foo` will not check that `x` is an `int` and that `y` is a `const char*` (though if you use `y`, it will check that the pointer is in bounds of the capability and that the capability allows whatever kind of access you do). The return value will be passed in a register, too. In this regard, Fil-C is almost as efficient as Yolo-C!

And yet, if we changed `foo` to take extra arguments, we would get a panic. And if we changed the signature in any way (maybe `x` becomes a pointer and `y` becomes a `double`), we would either get a panic or a well-defined bitwise cast of the value to the other type.

This document explains how Fil-C manages to **avoid doing any safety checks for the common case of calls** while either *panicking* or strictly following well-defined [GIMSO semantics](gimso.html) in case calls are misused in some type-violating way.

First, the generic calling convention is explained. All optimizations obey identical semantics to the generic calling convention and the generic calling convention is the fallback when the optimizations would not be legal under those semantics. Second, the register calling convention optimization is described. This is what allows arguments and return values to be passed in registers in the common case. Finally, the direct call optimizations are described. These optimizations make it possible for the caller to avoid doing any checks about whether the callee agrees on the function signature.

## Generic Calling Convention

*This section is almost identical to the [call section in the GIMSO document](gimso.html#call), except it combines how to get the callee with executing the call.*

In the generic case, calls proceed as follows.

1. The callee is resolved. For indirect calls, the callee is a [flight pointer](invisicaps.html#flightptr) (tuple of capability pointer and pointer intval) we already have in hand, so this step is a no-op in that case. For direct calls, the callee is a symbol name. ELF linkers provide a built-in facility to automatically resolve symbol names to function pointers. But to support memory-safe linking and loading in Fil-C, we need symbol names to resolve to a flight pointer, so that we can then check that the thing that the pointer points at is suitable for whatever we want to do to it (the next step for calls is to check that we have a function capability; for global variable accesses we would check that the global is a data capability and that the access is in bounds). Hence, the Fil-C compiler lowers symbol resolution to a [getter call](runtime.html#linking). The getter returns the callee flight pointer.
2. The callee is checked. The following requirements must be met, or else a panic occurs:
    - Capability must not be null.
    - Capability must be a function capability.
    - The pointer's intval must match the capability's callable pointer value.
3. The size of the argument buffer is computed by rounding up each argument's size to 8. Additionally, argument type alignment is obeyed, which may mean adding padding. Note that `byref` arguments have their value copied into the argument buffer, so the argument's type for the purpose of the computation is the reference'd type, not `ptr`. Two thread-local CC (calling convention) buffers are allocated of that size. These buffers live only long enough for the callee to retrieve the arguments. One buffer is for the payload, and the other is for capabilities.
4. Each argument is copied into the CC buffers. For `byref` arguments, the pointed-at value is copied into the buffers.
5. Control is transferred to the callee's prologue and the callsite address is saved to a private callstack. The stack where the callsite address is stored is outside of Fil-C memory and cannot be accessed with any capability. The callee is told about the size of the arguments as well as the function capability. Passing the function capability is useful for `libffi` implementing closures, but is otherwise unused.
6. The callee's prologue heap-allocates (as if with `alloca`) any `byref` parameters.
7. All arguments are copied out of the CC buffers. For non-`byref` parameters, the arguments are copied into local data flow. For `byref` parameters, the arguments are copied into the allocations from step 6.
8. If the callee uses any argument introspection (like `va_arg` or `zargs`), then the CC buffers are copied into a newly created readonly heap object. At this point, the CC buffer is dead. In practice, the implementation may reuse the same CC buffer repeatedly.
9. **The callee executes.** If an exception throw happens, then we return to the callsite with a flag indicating that an exception is in flight.
10. When the callee returns normally, an almost identical process to argument passing happens, except for the return value. First the size of the return buffer is computed by rounding up the return type's size to 8. The CC buffer is allocated of that size. It will live until the callsite finishes retrieving the result.
11. The return value is copied into the CC buffers.
12. Control is transferred back to the callsite with a flag indicating that an exception is NOT in flight, as well as the size of the return value.
13. The callsite loads the return value from the CC buffers and produces it in local data flow.

If the callsite observes the exception flag being set, then the caller returns with the exception flag set.

Let's consider an example of an indirect call like:

    int arg1 = ...;
    char* arg2 = ...;
    double arg3 = ...;
    char* result = function_pointer(arg1, arg2, arg3);

The generic calling convention - before we did any of the optimizations in this document - would look like:

    check_function_call(function_pointer); /* all of the capability checks */
    (int*)(my_thread->cc_inline_buffer + 0) = arg1;
    (void**)(my_thread->cc_inline_aux_buffer + 0) = NULL;
    (void**)(my_thread->cc_inline_buffer + 8) = arg2.intval;
    (void**)(my_thread->cc_inline_aux_buffer + 8) = arg2.lower;
    (double*)(my_thread->cc_inline_buffer + 16) = arg3;
    (void**)(my_thread->cc_inline_aux_buffer + 16) = NULL;
    struct pizlonated_return_value {
        bool has_exception;
        size_t return_size;
    };
    struct pizlonated_return_value rv =
        ((pizlonated_function_type)function_pointer.intval)(
            my_thread, function_pointer.lower, 24);
    if (rv.has_exception)
        goto unwind_handler;
    if (rv.return_size < 8)
        goto panic;
    flight_ptr result;
    result.intval = *(void**)(my_thread->cc_inline_buffer + 0);
    result.lower = *(void**)(my_thread->cc_inline_aux_buffer + 0);

This calling convention is inefficient in three major ways:

1. Arguments and return values are passed using thread-local CC buffers rather than in registers.
2. The callee's capability must be checked.
3. Direct calls require [calling a getter](runtime.html#linking) to get a capability to the callee.

The next two sections describe the optimizations that eliminate this overhead in the common case. The section that immediately follows describes how to pass arguments and return values in registers in the common case. The section after that describes how to avoid checking the callee's capability or even calling the getter.

## Register Calling Convention Using Arithmetically Encoded Signatures And Generic Call Thunks

Fil-C function pointers are quite rich:

- The pointer value seen by the user (the *intval*) can be whatever we (the implementors of Fil-C) want it to be, so long as it's consistent. We can make it just be a pointer to the base of some kind of object rather than an actual code pointer, so long as the implementation of the LLVM call and invoke opcodes knows what to do with it.
- All pointers have an [invisible](invisicaps.html) *lower* pointer, which points to just above the capability object. For special objects like functions, *lower* pointer also points to the bottom of an internal object that Fil-C controls and the user is not allowed to edit (all reads and writes are disallowed because special objects have the upper bound set to exactly the lower bound).
- Fil-C supports [closures](stdfil.html#zclosure_new), which are function pointers that carry extra state that can be retrieved by the caller. Given any defined function, the user can create as many closure objects as they like, each with different data attached to them. This is necessary for supporting `libffi` closures without using JIT privileges. The presence of this feature means that when calling a Fil-C function, we are already passing it a pointer to the function object (aka the function capability) as one of the arguments.

This power gives us a lot of opportunities! This first optimization makes the function object have these fields. Remember - these fields cannot be accessed directly by the Fil-C program, so they can make use of raw pointers.

- `fast_entrypoint` - this is a raw pointer to a function entrypoint that uses a native, register-based calling convention for whatever signature the function was defined to use. The only ways that the calling convention differs from the Yolo-C one is that the first two arguments are the thread and the function object, the return value is a struct that includes a bit that tells if there was an exception, and pointers are passed as tuples of *lower* and *intval*.
- `generic_entrypoint` - this is a raw pointer to a function entrypoint that uses the generic calling convention based on thread-local CC buffers. Note that this entrypoint takes the function object as one of its arguments. We will use this fact!
- `signature` - a 64-bit **arithmetic encoding** of the function signature. Think of this as a perfect hash of the signature. If this value is 0 then it means that the function only has a generic entrypoint (so `fast_entrypoint` will be NULL).
- In case the function object is a closure, there's one more field: the `data_ptr`, which is a user-controlled [flight pointer](invisicaps.html#flightptr) (a tuple of *lower* and *intval*). We know that a function object is a closure if the `READONLY` object flag is not set.

Let's talk about this optimization as follows. First, what does the callsite do. Second, what thunks are emitted by the caller and callee to rescue cases where the signature doesn't match. Finally, how the arithmetic encoding of signatures works.

### The Callsite

We will consider calls to function pointers for now, since direct function calls require the linker resolution step that yields a function pointer. We'll optimize that out in a later optimization. So, given a source-level call like the one we saw before:

    int arg1 = ...;
    char* arg2 = ...;
    double arg3 = ...;
    char* result = function_pointer(arg1, arg2, arg3);

We now emit code like:

    check_function_call(function_pointer); /* all of the capability checks */
    filc_function* function_object = (filc_function*)function_pointer.lower;
    struct typed_return_value {
        bool has_exception;
        flight_ptr result;
    };
    struct typed_return_value (*fast_function_pointer)(
        filc_thread*, filc_function_object*, int, flight_ptr, double);
    if (LIKELY(function_object->signature == 60125))
        fast_function_pointer = function_object->fast_entrypoint;
    else
        fast_function_pointer = pizlonated1ET60125;
    struct typed_return_value rv = fast_function_pointer(
        my_thread, function_object, arg1, arg2, arg3);
    if (rv.has_exception)
        goto unwind;
    result = rv.result;

Let's dig into how this works!

The function call itself uses a native-ish calling convention and all of the arguments will get passed in registers. All of the return values will be passed in registers. The only differences from the actual native calling convention is that we have two additional arguments (the thread and the function object) and one additional return value (`has_exception`).

Prior to the function call, we have to check if the callee uses the calling convention that we expect. 60125 is the arithmetic encoding of the `char* (*)(int, char*, double)` signature. If that matches, we use the `fast_entrypoint` directly. If it does not match, we use a locally defined `pizlonated1ET60125` thunk. This thunk doesn't know anything about our callee and it doesn't have to, since the second argument to the call is the function object. The next section discusses how the thunks work.

Note that some callsites will choose to use the generic calling convention. In that case, they will call the `generic_entrypoint` directly and no caller entrypoint thunk is needed. This happens if the callsite function signature is not encodeable using our arithmetic encoding.

### The Thunks

In case the calling convention does not match, we use a pair of thunks to translate between the caller and callee:

- The caller entrypoint thunk (like `pizlonated1ET60125`), which takes arguments according to the fast calling convention and calls the function object's `generic_entrypoint` using the generic calling convention.
- The callee entrypoint thunk (would be called something like `pizlonated2ET60125`), which takes arguments according to the generic calling convention and calls the function object's `fast_entrypoint` using the fast calling convention.

Both thunks are generated as `linkonce_odr` in LLVM IR, which corresponds to being weak definitions in ELF. This means that if multiple modules define the same caller or callee entrypoint thunk, then the linker only picks one, based on the symbol name.

Some functions will choose to only have a generic entrypoint. This will happen if they use variadic arguments, [variadic returns](stdfil.html#zreturn), or if their signature is not encodeable using our arithmetic encoding. In that case, the callee will not generate an entrypoint thunk and the function object's generic entrypoint will point directly to the function implementation.

### Caller Entrypoint Thunk Example

The caller entrypoint thunk accepts a register-based fast call and calls the generic entrypoint. The caller entrypoint thunk for signature 60125 looks like this in x86 assembly:

    00000000000001d0 <pizlonated1ET60125>:
     1d0:	push   %rbx
     1d1:	mov    %rdi,%rbx
     1d4:	mov    %rdx,0x80(%rdi)
     1db:	mov    %rcx,0x88(%rdi)
     1e2:	movsd  %xmm0,0x90(%rdi)
     1ea:	movq   $0x0,0x180(%rdi)
     1f5:	mov    %r8,0x188(%rdi)
     1fc:	movq   $0x0,0x190(%rdi)
     207:	mov    $0x18,%edx
     20c:	call   *0x8(%rsi)
     20f:	test   $0x1,%al
     211:	jne    229 <pizlonated1ET60125+0x59>
     213:	cmp    $0x7,%rdx
     217:	jbe    22b <pizlonated1ET60125+0x5b>
     219:	mov    0x80(%rbx),%rdx
     220:	mov    0x180(%rbx),%rcx
     227:	pop    %rbx
     228:	ret    
     229:	pop    %rbx
     22a:	ret    
     22b:	mov    $0x8,%esi
     230:	mov    %rdx,%rdi
     233:	xor    %edx,%edx
     235:	call   23a <pizlonated1ET60125+0x6a>

Let's look at the key parts of this function. First, the arguments that were passed in registers are stored to the thread-local CC buffer:

     1d4:	mov    %rdx,0x80(%rdi)
     1db:	mov    %rcx,0x88(%rdi)
     1e2:	movsd  %xmm0,0x90(%rdi)
     1ea:	movq   $0x0,0x180(%rdi)
     1f5:	mov    %r8,0x188(%rdi)
     1fc:	movq   $0x0,0x190(%rdi)

Then we call the generic entrypoint of the function object, passing it 24 as the argument size:

     207:	mov    $0x18,%edx
     20c:	call   *0x8(%rsi)

Next we check for exceptions:

     20f:	test   $0x1,%al
     211:	jne    229 <pizlonated1ET60125+0x59>

And we check if the return value is at least 8 bytes:

     213:	cmp    $0x7,%rdx
     217:	jbe    22b <pizlonated1ET60125+0x5b>

Finally we load the return value into return value registers and return:

     219:	mov    0x80(%rbx),%rdx
     220:	mov    0x180(%rbx),%rcx
     227:	pop    %rbx
     228:	ret    

### Callee Entrypoint Thunk Example

The callee entrypoint thunk accepts a generic call and calls the fast entrypoint. The callee entrypoint thunk for signature 60125 looks like this in x86 assembly:

    0000000000000030 <pizlonated2ET60125>:
      30:	push   %rbx
      31:	cmp    $0x17,%rdx
      35:	jbe    74 <pizlonated2ET60125+0x44>
      37:	mov    %rdi,%rbx
      3a:	mov    0x80(%rdi),%rdx
      41:	mov    0x88(%rdi),%rcx
      48:	movsd  0x90(%rdi),%xmm0
      50:	mov    0x188(%rdi),%r8
      57:	call   *(%rsi)
      59:	test   $0x1,%al
      5b:	jne    72 <pizlonated2ET60125+0x42>
      5d:	mov    %rdx,0x80(%rbx)
      64:	mov    %rcx,0x180(%rbx)
      6b:	mov    $0x8,%edx
      70:	pop    %rbx
      71:	ret    
      72:	pop    %rbx
      73:	ret    
      74:	mov    $0x18,%esi
      79:	mov    %rdx,%rdi
      7c:	xor    %edx,%edx
      7e:	call   83 <pizlonated2ET60125+0x53>

Let's walk through this. First, the thunk checks that it was passed 24 bytes of arguments:

      31:	cmp    $0x17,%rdx
      35:	jbe    74 <pizlonated2ET60125+0x44>

Next, the arguments are loaded from the thread-local CC buffer into argument registers:

      3a:	mov    0x80(%rdi),%rdx
      41:	mov    0x88(%rdi),%rcx
      48:	movsd  0x90(%rdi),%xmm0
      50:	mov    0x188(%rdi),%r8

Then the fast entrypoint is called:

      57:	call   *(%rsi)

And we check for exceptions:

      59:	test   $0x1,%al
      5b:	jne    72 <pizlonated2ET60125+0x42>

Finally we store the returned value into thread-local CC buffers and return (indicating that we are returning 8 bytes of return value):

      5d:	mov    %rdx,0x80(%rbx)
      64:	mov    %rcx,0x180(%rbx)
      6b:	mov    $0x8,%edx
      70:	pop    %rbx

To summarize: in the common case, function calls use a register-based mostly-native calling convention where the only overhead is checking if the callee has the right signature. If it doesn't, a pair of thunks is used to translate between the caller's calling convention and the callee's calling convention. The translation relies on the generic calling convention Fil-C already had.

### The Arithmetic Encoding

In the running example, we represented the signature `char* (*)(int, char*, double)` as 60125. This section explains how we encode any function signature matching the following constraints into a 64-bit integer:

- Maximum of 16 arguments.
- Maximum of 2 return values *(in C/C++ on X86_64 if a struct with up to two fields is returned, then LLVM sees it as a 2-value return; returning larger structs means being passed a pointer to a return value)*.
- The arguments and return values are of the following types:
    - Any integer up to 64-bit
    - Float
    - Double
    - Long Double
    - 128-bit Vector
    - 256-bit Vector
    - 512-bit Vector
    - Any pointer

Additionally, the encoding has three reserved argument types. Hence, we have 11 types total. It's not an error if a function cannot be encoded using this encoding; functions with those signatures just fall back to the generic calling convention. Thanks to how permissive this is (up to 16 arguments!), the fall-back case is exceedingly rare. Most software packages I've tested don't even have a single function that exceeds these limits.

A key feature of the encoding is how to represent sequences of between 0 and N (inclusive) types. The simplest version of this is if we know ahead of time how many types are in the sequence. For example, say we have three types, A, B, C, each of which are integers from 0 to 10 (inclusive). We could represent the A, B, C sequence as A + 11 * B + 121 * C. But what if we want to represent both the sequence and the length of the sequence?

The sequence-of-types encoding we will use works like this:

- 0 means the sequence is empty.
- For a single type T, we use 1 + T.
- For two types, we use 1 + 11 + T1 + 11 * T2.
- For three types, we use 1 + 11 + 121 + T1 + 11 * T2 + 121 * T3.
- Etc.

For example, to represent return values (0, 1, or 2 types), we need a range of 1 + 11 + 121 = 133 values. Let's call the return value encoding Ret.

To represent arguments (0 to 16 types), we need a range of 50544702849929377 values. Let's call the arguments encoding Arg.

The encoding works as follows:

- 0 is the generic signature.
- For all other signatures, the encoding is 1 + Ret + Arg * 133

This still leaves 11724298594668944475 values in the int64 (almost 2/3 of the encoding space). So in addition to having 3 reserved types, we also have 2/3 of the encoding space left for any kind of fancy next-generation signature encoding we would like to use.

Let's dig into why `char* (*)(int, char*, double)` is 60125:

- `char*` is a pointer, which has value 7.
- `int` is 0.
- `double` is 2.

Hence Ret is 1 + 7 = 8.

And Arg is 1 + 11 + 121 + 0 + 7 * 11 + 2 * 121 = 452.

So the signature is 1 + 8 + 133 * 452 = 60125.

**The register calling convention optimization results in a >1% speed-up on PizBench9019.**

## Avoiding Direct Caller Resolution

The final optimization is how to avoid having to resolve direct callers using getter calls and capability checks. The intuition for this optimization is that:

- When a function is defined, then in addition to exporting an ELF symbol for the function's flight pointer getter, we can also export an ELF symbol for the implementation. That symbol can be mangled to include the signature.
- When a function is called directly, then call the function's signature-mangled implementation directly.
- To defend against cases where there is a mismatch in signature, locally define a weak callsite thunk with the same name as the implementation, which performs the full call sequence (calls the getter, checks the capability, attempts the fast call).

With this optimization, a direct call like:

    int arg1 = ...;
    char* arg2 = ...;
    double arg3 = ...;
    char* result = foo(arg1, arg2, arg3);

Gets emitted to:

    struct typed_return_value {
        bool has_exception;
        flight_ptr result;
    };
    struct typed_return_value rv = pizlonatedFI60125_foo(
        my_thread, undef, arg1, arg2, arg3);
    if (rv.has_exception)
        goto unwind;
    result = rv.result;

Where `pizlonatedFI60125_foo` is the signature-mangled implementation function name. Note that `undef` here is the LLVM `undef` value, which when used as a function argument means that the corresponding argument register is simply not set. **That's a huge improvement!** We have successfully eliminated the getter call for linker resolution, the function capability check, the signature check, the thread-local CC buffer accesses, and the argument/return value size checks!

The simplest case of this is if `foo` is defined in the same module and `foo`'s definition has a matching signature. In that case, the code above just works and we don't have to do anything else.

If `foo` is extern, or if it is defined locally with a different signature, or if the definition uses closure features like [`zcallee`](stdfil.html#zcallee) or [`zcallee_closure_data`](stdfil.html#zcallee_closure_data) (meaning that the second argument - the function capability - must really be passed), the module with this callsite will emit a weak `pizlonatedFI60125_foo` that performs the getter call. We call this the known target callsite thunk. It also inlines the caller entrypoint thunk to avoid having triple indirection in the slowest case. Let's take a look at the weak callsite thunk:

    00000000000011d0 <pizlonatedFI60125_foo>:
        11d0:	push   %r15
        11d2:	push   %r14
        11d4:	push   %r12
        11d6:	push   %rbx
        11d7:	push   %rax
        11d8:	movsd  %xmm0,(%rsp)
        11dd:	mov    %r8,%r14
        11e0:	mov    %rcx,%r15
        11e3:	mov    %rdx,%r12
        11e6:	mov    %rdi,%rbx
        11e9:	xor    %esi,%esi
        11eb:	call   1050 <pizlonated_foo@plt>
        11f0:	mov    %rdx,%rsi
        11f3:	test   %rdx,%rdx
        11f6:	je     12ca <pizlonatedFI60125_foo+0xfa>
        11fc:	mov    -0x8(%rsi),%rcx
        1200:	movabs $0x780000000000000,%rdx
        120a:	and    %rcx,%rdx
        120d:	movabs $0x80000000000000,%rdi
        1217:	cmp    %rdi,%rdx
        121a:	jne    12ca <pizlonatedFI60125_foo+0xfa>
        1220:	movabs $0xffffffffffff,%rdx
        122a:	and    %rdx,%rcx
        122d:	cmp    %rcx,%rax
        1230:	jne    12ca <pizlonatedFI60125_foo+0xfa>
        1236:	cmpq   $0xeadd,0x10(%rsi)
        123e:	jne    1261 <pizlonatedFI60125_foo+0x91>
        1240:	mov    (%rsi),%rax
        1243:	mov    %rbx,%rdi
        1246:	mov    %r12,%rdx
        1249:	mov    %r15,%rcx
        124c:	mov    %r14,%r8
        124f:	movsd  (%rsp),%xmm0
        1254:	add    $0x8,%rsp
        1258:	pop    %rbx
        1259:	pop    %r12
        125b:	pop    %r14
        125d:	pop    %r15
        125f:	jmp    *%rax
        1261:	mov    %r12,0x80(%rbx)
        1268:	mov    %r15,0x88(%rbx)
        126f:	movsd  (%rsp),%xmm0
        1274:	movsd  %xmm0,0x90(%rbx)
        127c:	movq   $0x0,0x180(%rbx)
        1287:	mov    %r14,0x188(%rbx)
        128e:	movq   $0x0,0x190(%rbx)
        1299:	mov    $0x18,%edx
        129e:	mov    %rbx,%rdi
        12a1:	call   *0x8(%rsi)
        12a4:	test   $0x1,%al
        12a6:	jne    12c8 <pizlonatedFI60125_foo+0xf8>
        12a8:	cmp    $0x7,%rdx
        12ac:	jbe    12d2 <pizlonatedFI60125_foo+0x102>
        12ae:	mov    0x80(%rbx),%rdx
        12b5:	mov    0x180(%rbx),%rcx
        12bc:	add    $0x8,%rsp
        12c0:	pop    %rbx
        12c1:	pop    %r12
        12c3:	pop    %r14
        12c5:	pop    %r15
        12c7:	ret    
        12c8:	jmp    12bc <pizlonatedFI60125_foo+0xec>
        12ca:	mov    %rax,%rdi
        12cd:	call   1030 <filc_check_function_call_fail@plt>
        12d2:	mov    $0x8,%esi
        12d7:	mov    %rdx,%rdi
        12da:	xor    %edx,%edx
        12dc:	call   1040 <filc_cc_rets_check_failure@plt>

This thunk performs the following work:

1. Calls the getter for `foo`.
2. Checks that the pointer returned by the getter is really a function.
3. Checks if the signature matches; if it does, then does the fast call. This includes passing the function object. If the signature does not match, this calls the generic entrypoint.

As gross as that is, this weak symbol only gets invoked in those cases where there was a signature mismatch. If there is no mismatch, the actual implementation of `foo` wins and the callsite calls that directly!

**This almost works!** The problems with this approach come down to ELF details, which I will try to share with you as best as I can:

1. This relies on strong symbols winning against weak ones. But that only works during linking. It doesn't work during loading. During loading, the first symbol encountered by the loader wins.
2. This doesn't work if the actual function definition is weak. There's no such thing as "weaker than weak", so we can't say that our known target callsite thunk should lose against the real weak definition.
3. A similar but more annoying version of the weak v. weak problem happens when we try to use this technique to optimize calls to C++ inline functions. These use `linkonce_odr` linking at the LLVM level, which translates to weak symbols in COMDATs at the ELF level.

Let's dwell a bit on the implication of the first and second problems. In both cases, the result is that the weakly defined known target callsite thunk will win against the actual function definition. So, all calls will go to the thunk. Then, when the thunk calls the getter, the getter will return a function object whose `fast_entrypoint` points at the known target callsite thunk! The reason for this is that the function object is just part of an ELF data section with a relocation asking the linker/loader to resolve the pointer to something called `pizlonatedFI60125_foo`. If the winner is the known target callsite thunk then this results in an infinite loop anytime we try to call the function.

The first problem is easy to solve: we always define the known target callsite thunk with hidden visibility. This ensures that the loader never sees them. The downside is that calls across dynamic library boundaries always have to go through the thunk, but we're counting on two things: (1) that's not much worse than what would have happened without this optimization and (2) calls within dynamic libraries are much more common than calls across the boundary.

The second is solved by emitting the implementation under the symbol `pizlonatedFIP60125_foo` instead of `pizlonatedFI60125_foo`. Then, only if the function is strongly defined, we define a strong alias from `pizlonatedFI60125_foo` to `pizlonatedFIP60125_foo`. The function object always asks for `pizlonatedFIP60125_foo`. This ensures that calls to weak definitions don't get stuck in infinite loops. It also means that calls to weak definitions always go through the thunk. That's fine, since calls to weak definitions are rare. Note that this same trick is used to handle closure features - even if the function is strongly defined, we do not create the strong alias if the function uses [`zcallee`](stdfil.html#zcallee) or [`zcallee_closure_data`](stdfil.html#zcallee_closure_data). We need to protect functions that use closure features in this way because the direct call optimization passes `undef` as the function object. On the other hand, the known target callsite thunk looks up the function object and always passes it to the function's entrypoint.

But this reveals the third problem: say we have a C++ header file called `header.h` like:

    inline int foo(int x) { /* lots of stuff */ }

For the purpose of this discussion, let's assume that `foo` is not inlineable - maybe because it's a very large function.

Then let's say we have a module that does:

    #include "header.h"

    void bar()
    {
        /* stuff */
        x = foo(x);
        /* more stuff */
    }

We'd sure like if `bar`'s call to `foo` benefited from the optimization. But what happens is that `foo` is a weak definition. Worse, it's a weak definition with a COMDAT.

*I wish I could just share a link to a good description of COMDAT, but sadly, I cannot because they all suck. So instead I'll write my own description, which hopefully sucks less than the other ones at least for the purposes of describing the problem we're facing.*

The thing that C++ wants to do for `foo` is:

- Every module that includes `header.h` will have `foo`'s machine code.
- But at link time, the linker keeps only one definition of `foo`.

This can *almost* be achieved with a weak symbol. But weak symbols have two shortcomings:

1. The linker won't actually drop the contents of the losing `foo`'s.
2. In both Yolo-C++ and Fil-C++, `foo` is not one symbol.
    - In Yolo-C++, there's `foo` plus extra symbols for things like `foo`'s unwind data. When one `foo` wins, we want to make sure that its unwind data wins along with it. This is because although C++ compilers are deterministic, we have to support the case where different modules including `header.h` are compiled with different compiler flags.
    - In Fil-C++, there's the `pizlonated_foo` getter, the implementation function, and the function object (at least). Again, we want to make sure that the loader never mixes-and-matches between different modules - it picks a winner from one module, and the whole constellation of `foo`-related symbols win or lose together.

COMDAT solves both problems. We put the whole constellation of `foo`-related things into a single COMDAT group. This tells the linker that these symbols are all-or-nothing and that it's fine to drop the contents of the losers.

Let's get back to why this is hard for the known target callsite thunks.

First problem: the inline `foo` will be a weak definition. Hence, according to the rules we spelled out above, all calls to `foo` will have to go through the known target callsite thunk. None of them can be direct, since weak definitions only define the `pizlonatedFIP` symbol, and callers always call the `pizlonatedFI` symbol.

We can solve this problem by adding this rule: *if we notice that the local module defines the `pizlonatedFIP` symbol for the function we're trying to call and the signature matches, then call that directly.*

But this produces a second problem: COMDAT resolution rules may cause the linker to drop the `pizlonatedFIP` function we tried to call! This is hard to achieve, since what Fil-C sees are symbols after C++ name mangling - so two C++ functions with the same name but different signatures will have different names from Fil-C's standpoint. But you can achieve it by putting C++ inline functions in `extern "C"`. So, we could have two modules that both COMDAT `foo` but with different Fil-C signatures, leading to one of the modules having a direct call to a function dropped by COMDAT resolution. Worse, calls to functions dropped by COMDAT don't result in linking or loading errors; the call just ends up calling NULL.

The way I solved this is by:

1. Changing LLVM to know that a global symbol that is locally defined, but not strongly, and that has a COMDAT may be NULL. Previously, LLVM always assumed that locally defined symbols can never be NULL. This required changes in two places (`ValueTracking.cpp` and `ConstantFold.cpp`).
2. Emitting a null check whenever we emit a direct call to a `pizlonatedFIP` that is locally defined but has a COMDAT.

The NULL check uses a different relocation than the call (it's a relocation that requests a pointer to the function to be materialized, rather than for the linker to patch a call). Amusingly, that relocation *does* cause linker errors in case COMDAT resolution drops the function we're calling. Hence, this unlikely safety issue is caught at link time rather than at run-time.

With all of this in place, we are able to mostly leverage the direct call optimization for C++ inline function calls; they are only slightly less efficient than static function calls or same-library calls in that they must do one null check.

**The direct call optimization results in another >1% speed-up on PizBench9019.**

## Conclusion

We started with direct calls having to call a getter, check the function's capability, store arguments to a buffer, have the callee check that they got enough arguments, have the caller check that they got enough return values, and load return values from a buffer.

With all of these optimizations, the common case for a direct call does none of that: we just directly call the implementation, exchanging arguments and return values in registers.

To get there, we had to employ some fancy ELF tricks and invent an arithmetic encoding for signatures so that signatures can fit into 64-bit integers.
