# Garbage In, Memory Safety Out!

Fil-C achieves memory safety by introducing a *garbage in, memory safety out* (GIMSO) [pass to LLVM](compiler.html). This pass ascribes a memory safe semantics to the incoming LLVM IR so that given any possible LLVM module (including one created adversarially), the resulting module will obey Fil-C pointer capability rules.

But what are those rules, and what are the semantics that Fil-C's pass ascribes to LLVM IR? This document describes these GIMSO semantics.

[I've also written about how these semantics are implemented](invisicaps.html), [shown examples of how the semantics catch issues](invisicaps_by_example.html), and [described the disassembly of a program compiled under these rules](compiler_example.html).

# Pointers In Flight 

We say that a value is "in flight" when it is carried in LLVM data flow rather than when it is stored in memory. For example, if a `call` instruction's first argument operand uses a `load` instruction of `ptr` type, then this data flow edge has a "pointer in flight".

Under GIMSO, pointers in flight carry two separate pieces of information:

- The pointer's integer value (intval). Under normal LLVM semantics, this is *all* that the a pointer in flight would carry. This could be any integer value whose bit width matches the module data layout's pointer size. *We do not trust this value and it may be garbage or adversarial.*

- The pointer's capability. This is a pointer as well, but it is not forgeable by the the LLVM IR that uses pointers. The capability pointer points to a garbage collected object. Three kinds of capabilities are possible: the null capability is for pointers that cannot be dereferenced at all, plain capabilities have a lower and upper bounds that tell the range of addresses that can be accessed using that capability, and special capabilities are for things like function pointers (though other special types are also recognized, and more may be added in the future). Plain capabilities may monotonically transition from having their original bounds to having lower = upper; this happens when objects get freed. Other than the free operation, there's no operation that can change the lower or upper bounds. Capabilities must be pointers to objects, as opposed to being carried around "in place" to enable aliasing of the capability between all pointers that use that capability. If two pointers have the same capability and one of them is passed to the `free()` function, then both pointers will now see a freed capability (lower and upper bounds will be equal). The capability objects are not visible to LLVM IR. One way that capabilities might be implementated is if there was a totally separate address space in which the capability objects are allocated. But a simpler option exists (and what Fil-C actually does): the capability objects are at addresses that are outside of any capability's lower/upper bounds. So, it's never possible for LLVM IR to load or store to the capability objects.

It's possible to change the pointer's integer value using a variety of LLVM IR operations. On the other hand, capabilities may be created at allocation time, or they may be freed, but otherwise they just travel with pointers.

It's legal to access N bytes (with a load, store, or atomic operation) in a flight pointer P if:

- `P.intval >= P.capability->lower`

- `P.intval < P.capabiltiy->upper`

- `P.intval + N <= P.capability->upper`

Illegal accesses are guaranteed to cause a Fil-C safety error. Legal accesses are guaranteed to succeed.

Accesses that LLVM claims to be aligned are either checked for alignment, or have their alignment
annotation dropped. On X86-64, it's common for C programs to perform integer and float accesses that
are not aligned, so Fil-C drops the alignment annotation for those. But vector and pointer accesses have their alignment preserved. For those accesses where alignment is preserved, Fil-C checks that the alignment holds: the access is only legal if `P mod A = 0`.

# Capability Allocation

Capabilities can only be created by allocation. Allocations happen via libc, such as by calling `malloc`, via the LLVM IR `alloca` instruction, and LLVM global variables.

Creating a capability allocates both the capability object itself and the *payload* object. The payload is the memory that the user code gets to see with loads and stores. The capability's lower/upper bounds tell where the payload object is and how large it is.

New capabilities will choose a range of memory for the capability itself and for the payload that is free according to the garbage collector. So, a newly created capability never overlaps with any reachable capability.

New capabilities have their payload initialized to zero.

# Pointers At Rest

We say that a value is "at rest" when it is stored in memory.

Under GIMSO, pointers at rest use an *invisible capability* (InvisiCap). The pointer's intval is stored within the object's payload, while the capability pointer is stored at an invisible location.

It's easiest to understand the semantics by thinking of the capability pointers of pointers at rest living in a shadow address space. That's not how Fil-C implements it because Fil-C's OS interface does not rely on large memory reservations and the implementation does not require support for overcommit. However, the semantics are "as if" there is a shadow address space. So for the purpose of this document, the abstract machine has a primary address space and a shadow address space. All non-pointer-type accesses operate only on the primary address space. Pointer-type accesses (i.e. memory accesses whose access type is `ptr`) operate on both address spaces at once.

New capabilities initialize the corresponding shadow addresses to the null capability.

Non-pointer accesses operate only on the primary address space.

Pointer-type accesses are required to have pointer alignment, so 8 on 64-bit platforms, 4 on 32-bit platforms, and so forth. **For the rest of this document, we'll assume 64-bit systems, without loss of generality.** For example, rather than explaining that something is 8 bytes on 64-bit systems but 4 bytes on 32-bit systems, we'll just assume consider the 8 byte case.

## Simplified Rules, Ignoring Atomics

If we ignore the need for pointer atomics, pointers at rest are quite simple. Pointers at rest have their intval stored in the primary address space and their capability pointer stored in the secondary address space. We do not allow any other user-defined or hardware-defined address spaces (the address space number on all pointers must be 0; note that we could devise a Fil-C semantics for safe pointers to other address spaces, but I haven't done that, because I haven't found a need for it yet).

This permits pointer-integer aliasing as follows. Storing a pointer to a location and then loading it as an integer is like a `ptrtoint` cast. Storing a pointer to a location and then storing an integer to that same location, and then loading a pointer, yields a pointer with the capability of the pointer store and an intval from the integer store. Loading a pointer from a location that never had a pointer stored to it yields a pointer with a null capability.

This arrangement also prevents races from ever corrupting the capability. The capability pointer stores and loads always happen using LLVM `monotonic` atomic ordering. Hence, although the intval and capability may tear in a race (you may get an intval from one pointer and a capability from another), the result is a pointer that is illegal to access and always traps. No memory-unsafe outcome is possible from racing on non-atomic pointers.

## Complete Rules, Including Atomics

Fil-C allows atomic pointer accesses, where the intval and capability do not tear. This is achieved by giving the secondary address space an extra power: locations in the shadow address space may be in *non-atomic* or *atomic* mode. The *non-atomic* mode is the default. Upon allocation, the entire payload's shadow memory is put in *non-atomic* mode. Performing an atomic store of pointer type switches the shadow location to *atomic* mode.

If the shadow location is in *non-atomic* mode, then the pointer stored at that address has its intval stored in the primary address space and its capability stored in the shadow address space (as described in the previous section). This means that it's possible to alias pointers and integers, and it's possible to have intval-capability tearing.

If the shadow location is in *atomic* mode, then the pointer stored at that address has its intval and capability stored atomically in the shadow address space and the intval is replicated to the primary address space. In other words, the shadow address space behaves as if it has twice as many bits as the primary one, so that for any pointer address, it's possible to store both the intval and the capability at that location in the shadow space.

The behavior of the *atomic* mode is strange, but preserves pointer atomicity for atomic pointer accesses, preserves memory safety for non-atomic pointer accesses, allows aliasing between pointers and integers so long as the accesses are not atomic, and guarantees lock-freedom of atomic pointer accesses. An example of how a program might observe the strangeness is the following sequence:

1. Atomically store pointer V to the address P.

2. Store integer W to the address P.

3. Load a pointer from P.

4. Load an integer from P.

In this case, the load in (3) will see the value V and the load in (4) will see the value W. Note that if the store in (1) had not been atomic, then the load in (3) would see a pointer with V's capability but W as the intval.

# Basic Operations

Let's first consider these basic operations: load, store, gep (aka getelementptr), ptrtoint, inttoptr, and alloca.

## Load

The LLVM `load` operation has the following two syntaxes:

    <result> = load [volatile] <ty>, ptr <pointer>[, align <alignment>]
    <result> = load atomic [volatile] <ty>, ptr <pointer> [syncscope("<target-scope>")] <ordering>, align <alignment>

Note that the `<ty>` can be a compound type, like a struct that has both pointers and non-pointers. Compound types are only possible for non-atomic loads. The first step to understanding GIMSO `load` semantics is to decompose compound type loads *where the compound type has pointers* into loads of each individual element of the compound value, and then reconstruct the compount value after doing all of the loads. For example, this:

    %val = load {i32, ptr}, ptr %ptr

becomes:

    %elem1 = load i32, ptr %ptr
    %ptr2 = getelementptr {i32, ptr}, %ptr, i32 0, i32 1
    %elem2 = load ptr, ptr %ptr2
    %agg1 = insertvalue {i32, ptr} zeroinitializer, %elem1, 0
    %val = insertvalue {i32, ptr} %agg1, %elem2, 1

On the other hand, we don't do this decomposition for compound types that don't have pointers. For example:

    %val = load {i32, i32}, ptr %ptr

is kept as-is.

Once all loads are decomposed (possibly recursively, if the compound type is deep), then each load is implemented as follows. In this description, we use P to refer to the pointer being loaded from and N is the size of the type being loaded. All loads start with mandatory checks. Check failure leads to a Fil-C safety error.

1. If the access type requires alignment according to Fil-C's rules for that target, then we check that `P.intval mod A = 0`, where A is the alignment requirement of the load. Pointers and vectors require an alignment check. Integers and floats don't on X86, but may require alignment on other platforms. A compound type requires alignment if any member requires alignment.

2. `P.capability` must be a plain capability (cannot be a null or special capability).

3. `P.intval >= P.capability->lower`

4. `P.intval < P.capabiltiy->upper`

5. `P.intval + N <= P.capability->upper`

Then the load is executed; this is a bit different depending on the type.

### Int Loads

*For simplicity, we refer to all non-pointer types as "ints". This includes floats, vectors and arrays of ints and floats, structs of ints and floats, etc.*

Int loads simpliy load using `P.intval` as the address to load from, while keeping the original LLVM flags on the load (atomic/volatile/ordering/etc). If the load was checked for alignment, then the alignment annotation is preserved; otherwise the alignment annotation is set to 1. 

### Non-Atomic Ptr Loads

Non-atomic ptr loads access the capability from the shadow space or the atomic box and the intval from the primary space.

Pseudocode:

    CapabilityOrAtomicBox = LoadFromShadowSpace(P.intval)
    Intval = LoadFromPrimarySpace(P.intval)
    if (CapabilityOrAtomicBox is AtomicBox)
        return MakePointer(capability = LoadCapabilityFromAtomicBox(CapabilityOrAtomicBox),
                           intval = Intval)
    return MakePointer(capability = CapabilityOrAtomicBox, intval = Intval)

Note that `LoadFromShadowSpace` uses the LLVM `monotonic` atomic ordering.

### Atomic Ptr Loads

If an atomic ptr load encounters a capability in the shadow space, then the loaded pointer uses the capability from shadow space and the intval from the primary space.

If an atomic ptr load encounters an atomic box in the shadow space, then the loaded pointer uses the capability and intval from the atomic box.

Pseudocode:

    CapabilityOrAtomicBox = LoadFromShadowSpace(P.intval)
    if (CapabilityOrAtomicBox is AtomicBox)
        return LoadPointerFromAtomixBox(CapabilityOrAtomicBox)
    return MakePointer(capability = CapabilityOrAtomicBox,
                       intval = LoadFromPrimarySpace(P.intval))

Note that the atomic versus non-atomic behavior of shadow space depends on whether the location in shadow space contains a capability or an atomic box.

<a name="store"></a>
## Store

The LLVM `store` operation has the following two syntaxes:

    store [volatile] <ty> <value>, ptr <pointer>[, align <alignment>]
    store atomic [volatile] <ty> <value>, ptr <pointer> [syncscope("<target-scope>")] <ordering>, align <alignment>

Note that the `<ty>` can be a compound type, like a struct that has both pointers and non-pointers. Compound types are only possible for non-atomic stores. The first step to understanding GIMSO `store` semantics is to decompose compound type stores *where the compound type has pointers* into stores of each individual element of the compound value. For example, this:

    store {i32, ptr} %val, ptr %ptr

becomes:

    %elem1 = extractvalue {i32, ptr} %val, 0
    store i32 %elem1, ptr %ptr
    %elem2 = extractvalue {i32, ptr} %val, 1
    %ptr2 = getelementptr {i32, ptr}, %ptr, i32 0, i32 1
    store ptr %elem2, ptr %ptr2

On the other hand, we don'd do this decomposition for compound types that don't have pointers. For example:

    store {i32, i32} %val, ptr %ptr

is kept as-is.

Once all stores are decomposed (possibly recursively, if the compound type is deep), then each store is implemented as follows. In this description, we use P to refer to the pointer being stored to, V to refer to the value being stored, and N is the size of the type being stored. All stores start with mandatory checks. Check failure leads to a Fil-C safety error.

1. If the access type requires alignment according to Fil-C's rules for that target, then we check that `P.intval mod A = 0`, where A is the alignment requirement of the store. Pointers and vectors require an alignment check. Integers and floats don't on X86, but may require alignment on other platforms. A compound type requires alignment if any member requires alignment.

2. `P.capability` must be a plain capability (cannot be a null or special capability).

3. `P.intval >= P.capability->lower`

4. `P.intval < P.capabiltiy->upper`

5. `P.intval + N <= P.capability->upper`

Then the store is executed; this is a bit different depending on the type.

### Int Stores

Int stores simply store using `P.intval` as the address to store to, while keeping the original LLVM flags on the store (atomic/volatile/ordering/etc). If the store was checked for alignment, then the alignment annotation is preserved; otherwise the alignment annotation is set to 1.

### Non-Atomic Ptr Stores

Non-atomic ptr stores put the intval into the primary space and the capability in the shadow space.

Pseudocode:

    StoreToPrimarySpace(P.intval, V.intval)
    StoreToShadowSpace(P.intval, V.capability)

Note that this makes the shadow space location have non-atomic mode, since future loads will see a capability at that location rather than an atomic box.

Note that `StoreToShadowSpace` uses the LLVM `monotonic` atomic ordering.

### Atomic Ptr Stores

Atomic ptr stores use an atomic box to store both intval and capability atomically. Semantically, this is as if a new atomic box was created on each atomic ptr store; however, it's possible to optimize this to reuse atomic boxes on repeated accesses to the same location.

Additionally, the intval is replicated to the primary space for the benefit of non-atomic loads.

Pseudocode:

    StoreToShadowSpace(P.intval, MakeAtomicBox(capability = V.capability, intval = V.intval))
    StoreToPrimarySpace(P.intval, V.intval)

Note that this makes the shadow space location have atomic mode, since future laods will see an atomic box at that location rather than a capability.

## Gep

The LLVM `getelementptr` instruction, or *gep* for short, has the following syntax:

    <result> = getelementptr [UB flags] <ty>, ptr <ptrval>{, <ty> <idx>}*

GIMSO means dropping any UB flags from the gep (so inbounds, nusw, nuw, and inrange are all deleted).

The gep is really just pointer arithmetic; the effect of all of the indices passed to the gep is that a DataLayout-dependent integer value is computed, which we will call the `addend`. Then the `addend` is added to the incoming `ptrval`. The pseudocode for GIMSO semantics are:

    result = MakePointer(capability = ptrval.capability,
                         intval = ptrval.intval + addend)

Hence, the `result` retains exactly the same capability as `ptrval`, but the intval is is changed.

<a name="ptrtoint"></a>
## Ptrtoint

The LLVM `ptrtoint` instruction returns a pointer's integer value. The syntax is:

    <result> = ptrtoint <ty> <value> to <ty2>

Where `ty` has to be `ptr` and `ty2` has to be some integer type (we'll ignore vectors of pointers for now, but without loss of generality). Note that `ty2` may have more or less bits than the pointer (so the bits are either truncated or extended). Let's define `IntCast<t>(X)` to mean either zero extending or truncating X depending on whether `t` is larger or smaller (respectively) than X. Then the semantics in pseudocode are just:

    result = IntCast<ty2>(value.intval)

<a name="inttoptr"></a>
## Inttoptr

The LLVM `inttoptr` instruction creates a pointer from an integer value. This is super unsafe! Fil-C has to do special things for this instruction. The syntax is:

    <result> = inttoptr <ty> <value> to <ty2>

Where `ty` has to be an integer type and `ty2` has to be `ptr`. Then *an approximation of* the semantics in pseudocode are just:

    result = MakePointer(capability = null,
                         intval = IntCast<intptr>(value))

This means that you get a pointer, but it lacks a capability, and so cannot be accessed. The only valid operations on it are comparisons and casting back to int. But, these aren't the complete semantics. Fil-C goes to great length to make code like this work:

    int* p = ...;
    p = (int*)(((uintptr_t)p & MASK) + (stuff() ? get_offset() : 0));

Here, a pointer is cast to integer (`ptrtoint`), that integer goes through some math (which includes both control flow and effects), and then the resulting integer gets cast back to a pointer. The Fil-C compiler includes an abstract interpreter (with very simple rules) that checks if the integer being cast to a pointer came from exactly one pointer via `ptrtoint`. I'll describe it here.

The abstract domain is a mapping from SSA instructions that produce integers to inferred capabilities.

An inferred capability is either BOTTOM, Definite(C), or TOP. The Definite(C) case points to an SSA value of `ptr` type and indicates that we've inferred that to be the capability we should use for an integer.

The start state of the interpreter has:

- all `ptrtoint` instructions initialize their inferred capability to Definite(X), where X is their input operand.

- all calls, loads, atomics, comparisons, vaargs, extracts, landing pads, and FP casts that return int have their inferred capapability set to BOTTOM.

- all other integer instructions are handed off to the interpreter. The interpreter only interprets these instructions.

Then the interpreter executes all of the instructions it knows about using the following rule:

- for each input operand that is an instruction:

    - If the current instruction is a `phi` or `select`:

        - if the input's inferred capability is not bottom, and the current instruction's inferred capability is bottom, then create a `phi` or `select` right next to the current instruction that picks the capability. the current instruction's inferred capability is set to Definite(P), where P is the new `phi` or `select` that we created. Note that this means that `phi` and `select` never go to TOP.

        - else, *merge* the input's inferred capability into the current instruction's inferred capability.

The interpreter stops when none of these rules changes any inferred capabilities.

The merge rule (merge X into Y) is:

   1. if X is BOTTOM, do nothing.

   2. if X == Y, do nothing.

   3. if Y is BOTTOM, set Y to X.

   4. if Y is Definite(C), set it to TOP. (Note that this rule rules after the *if X == &, do nothing* rule, hence merging Definite(C) into Definite(C) results in Definite(C).)

   5. if Y is TOP, do nothing.

After running this interpreter, any `inttoptr`'s whose input `value` has an inferred capability Definite(`cap`) get executed with the following pseudocode

    result = MakePointer(capability = cap.capability,
                         intval = IntCast<intptr>(value))

Note that BOTTOM or TOP inferred capabilities still get the original treatment (i.e. a pointer with a null capability).

## Alloca

The LLVM `alloca` instruction has this syntax:

    <result> = alloca [inalloca] <type> [, <ty> <NumElements>] [, align <alignment>] [, addrspace(<num>)]

We disallow `inalloca` for now, since this is only necessary for Windows, and Fil-C does not target Windows yet.

This instruction allocates a `<NumElements>` array of type `<type>`, or just a single `<type>` if `<NumElements>` is not specifies. For the purpose of Fil-C, all that matters is the total size of the allocation and its alignment (which is derived from the maximum of the `<alignment>` argument and the type's alignment).

Fil-C allocates enough memory for the payload, the capability object, and the shadow storage. The payload and shadow storage are zero-initialized. There is no such thing as uninitialized memory in Fil-C. The capability object's lower/upper bounds are initialized according to the size allocated.

Fil-C allocations and lower/upper bounds are always at least 8-byte aligned. For example, a one byte object will always have at least 8 bytes. The current Fil-C implementation will use 16-byte alignment for any allocation that ends up in the heap.

`alloca` returns a flight pointer with the newly allocated capability and the intval initialized to the lower bounds.

Note that in practice, `alloca`s may be allocated on the stack, if the compiler can prove that they do not escape.

# Calls

In LLVM IR, calling a function means calling a pointer to a function. If the function call is direct, then semantically we are still calling a pointer to a function; it's just that the pointer is a link-time constant. This section discusses the semantics of calling a pointer to a function. The next section is about linking.

Function pointers in Fil-C have a capability that specifies that the pointer is callable, and indicates what pointer value can be used for calling (the callable pointer value). The pointer's intval is untrusted (like with any other Fil-C pointer). For the call to succeed, the called capability must be a function capabilirty, and the intval must match the capability's callable pointer value.

Function pointer capabilities have null bounds for the purpose of loads and stores. So, it is not possible to perform loads and stores on function pointer capabilities.

Function calls in Fil-C have arguments and return values that contain both intvals and capabilities.

- Each function requires some number of bytes of arguments. The argument byte count must be a multiple of 8. For each 8-byte word, the caller passes both an intval and a capability; the capability may be null (as with any flight pointer). If the caller produces at least that many bytes of arguments, then the call succeeds. If the caller produces fewer bytes of arguments, then the call panics. Using Fil-C builtins, functions are allowed to introspect the full arguments array (that includes all of the arguments passed, not just the ones that the function declared as parameters; this works even if the function is not variadic).

- Each function produces some number of bytes of returns. The return byte count must be a multiple of 8 and each 8-byte word contains both an intval and a capability. Each callsite has a required number of bytes that it expects from the callee. Returning from a function succeeds if the function returns at least as many return bytes as the callsite expects. Using Fil-C builtins, functions may return variadically (may return a dynamically allocated return buffer).

Fil-C also provides a fully variadic call builtin, which takes a variable-sized argument buffer, and returns a variable-sized return buffer.

This approach to calls allows Fil-C to provide well-defined, memory-safe outcomes even when function pointer casts are taking place. Function pointer casts are common in C and C++

Fil-C functions may also throw exceptions. Fil-C supports C++ two-phase exception unwinding semantics and the `libunwind` core functionality is provided by the Fil-C runtime. As such, Fil-C functions may have an associated *personality function* that is invoked by the unwinder. The personality function is itself a Fil-C function and so it's completely memory safe (errors in the personality function may lead to unusual behavior, but that behavior stays within the bounds of GIMSO at the LLVM IR level). Additionally, function calls exhibit the following two properties:

- It's always possible to walk the call stack. With debugging disabled, call frames that were inlined may disappear from the trace. But, enough information is always preserved to allow invoking personality functions and for identifying frames that have no personality function.

- As an alternative to returning a value, functions may return an exception. From Fil-C's standpoint, "returning an exception" just means that the caller should proceed with phase 2 unwinding rather than continuing normally.

Now let's discuss the semantics of all call-related opcodes in LLVM IR under GIMSO.

<a name="call"></a>
## Call

The LLVM IR call instructions has the following syntax:

    <result> = [tail | musttail | notail ] call [fast-math flags] [cconv] [ret attrs] [addrspace(<num>)]
           <ty>|<fnty> <fnptrval>(<function args>) [fn attrs] [ operand bundles ]

Under GIMSO, we drop the `tail` flags, the fast-math flags, and we only ignore the `cconv` (only the Fil-C calling convention is allows). Most `fn attrs` are ignored.

The `call` instruction may be used to invoke a LLVM intrinsic, a Fil-C builtin, or inline assembly. Intrinsics, builtins, and inline assembly are destribed in another section. This section just describes the semantics of a call to a normal function pointer that is not an intrinsic, builtin, or inline asm.

Calls proceed as follows.

1. The `<fnptrval>` is checked. The following requirements must be met, or else a panic occurs:
    - Capability must not be null.
    - Capability must be a function capability.
    - The pointer's intval must match the capability's callable pointer value.
2. The size of the argument buffer is computed by rounding up each argument's size to 8. Additionally, argument type alignment is obeyed, which may mean adding padding. Note that `byref` arguments have their value copied into the argument buffer, so the argument's type for the purpose of the computation is the reference'd type, not `ptr`. Two thread-local CC (calling convention) buffers are allocated of that size. This buffers live only long enough for the callee to retrieve the arguments. One buffer is for the payload, and the other is for capabilities.
3. Each argument is copied into the CC buffers. For `byref` arguments, the pointed-at value is copied into the buffers.
4. Control is transferred to the callee's prologue and the callsite address is saved to a private callstack. The stack where the callsite address is stored is outside of Fil-C memory and cannot be accessed with any capability. The callee is told about the size of the arguments as well as the function capability. Passing the function capability is useful for `libffi` implementing closures, but is otherwise unused.
5. The callee's prologue heap-allocates (as if with `alloca`) any `byref` parameters.
6. All arguments are copied out of the CC buffers. For non-`byref` parameters, the arguments are copied into local data flow. For `byref` parameters, the arguments are copied into the allocations from step 5.
7. If the callee uses any argument introspection (like `va_arg` or `zargs`), then the CC buffers are copied into a newly created readonly heap object. At this point, the CC buffer is dead. In practice, the implementation may reuse the same CC buffer repeatedly.
8. **The callee executes.** If an exception throw happens, then we return to the callsite with a flag indicating that an exception is in flight.
9. When the callee returns normally, an almost identical process to argument passing happens, except for the return value. First the size of the return buffer is computed by rounding up the return type's size to 8. The CC buffer is allocated of that size. It will live until the callsite 
10. The return value is copied into the CC buffers.
11. Control is transferred back to the callsite with a flag indicating that an exception is NOT in flight, as well as the size of the return value.
12. The callsite loads the return value from the CC buffers and produces it in local data flow (i.e. the `<result>`).

If the callsite observes the exception flag being set, then the caller returns with the exception flag set.

## Invoke

In LLVM IR, `invoke` is exactly like `call` except that it allows for exception handling. This is accomplished by making `invoke` a block terminator, so it can have a normal return destination block, and an unwind destination block.

    <result> = invoke [cconv] [ret attrs] [addrspace(<num>)] <ty>|<fnty> <fnptrval>(<function args>) [fn attrs]
              [operand bundles] to label <normal label> unwind label <exception label>

`invoke` works exactly like `call` in Fil-C, except that:

- If the exception flag is not set when the callee returns, then control proceeds to the `<normal label>`.

- If the exception flag is set when the callee returns, then control proceeds to the `<exception label>`.

Fil-C currently only supports Itanium C++ exception handling ABI. In fact, because Fil-C's ABI for exceptions is implemented on top of Fil-C's own call ABI, it is the plan to use Itanium C++ exception handling *even on ARM and Windows*, which normally have their own ABIs. As such, the GIMSO semantics of LLVM IR only have a story for `invoke, `landingpad`, and `resume`. Instructions like `catchswitch` are statically rejected by the compiler.

## Landing Pad

The LLVM IR `landingpad` is a special instruction for describing what a callsite may catch. The `landingpad` instruction must appear at the top of any block that is used as the exceptional destination of an `invoke`. Its syntax is as follows:

    <resultval> = landingpad <resultty> <clause>+
    <resultval> = landingpad <resultty> cleanup <clause>*
    
    <clause> := catch <type> <value>
    <clause> := filter <array constant type> <array constant>

The `<resultty>` type is constrained under GIMSO to be a struct with two elements. Each element must either be an integer type no bigger than `i64` or the `ptr` type.

These two values may be set using the `_Unwind_SetGR` function in [`unwind.h`](https://github.com/pizlonator/fil-c/blob/deluge/filc/include/unwind.h). The personality function will use this to pass data back to the `landingpad`. This works as follows:

- The `_Unwind_Context` stores enough room for two pointer-sized *unwind registers*, which may be set with `_Unwind_SetGR` and `_Unwind_GetGR`. In Fil-C, the type of these registers is `void*`.
- During phase 2 unwinding, the `_Unwind_Context` is remembered by the Fil-C runtime as a thread-local value.
- When a `landingpad` executes, the values of the unwind registers are loaded from the current `_Unwind_Context` and returned from the `landingpad` as a struct. If the struct elements are integers, then the `void*` is cast to an integer according to `ptrtoint` rules. If the integer is smaller than `i64`, then the value is truncated (as if with `trunc`).

The `landingpad`'s clauses are saved by the compiler using a Fil-C format for exception handling data. That format is opaque, but an API is proved for retrieving it. The unwinder can vend it with `_Unwind_GetLanguageSpecificData`. It can be parsed with the [`pizlonated_eh_landing_pad`](https://github.com/pizlonator/fil-c/blob/deluge/filc/include/pizlonated_eh_landing_pad.h) API.

## Resume

Some landing pads are used for catching an exception (as in a C++ `catch` block), while others are used for executing deferred work during the phase 2 unwind (as in a C++ local variable destructor, or a C `__attribute__((cleanup))`). If the purpose of the landing pad was the latter, then it will want to resume exception handling. This is what the `resume` instruction is for. The syntax is:

    resume <type> <value>

In conventional LLVM IR, the `resume` instruction must take the value returned by the corresponding `landingpad`. In Fil-C, the value (and type) passed to `resume` is ignored, and the function simply returns with the exception flag set.

## Other Call-Related Instructions

The following call-related instructions in LLVM IR cause a compilatin failure in Fil-C: `callbr`, `catchswitch`, `cleanuppad`, `catchpad`, `catchreturn`, and `cleanupreturn`.

`callbr` is not supported because it's only used for inline assembly that can branch. Fil-C has very restricted inline assembly support, and doesn't support the branching kind at all.

The other instructions are for exception handling ABIs that are different from the Itanium C++ one.

# Constants And Linking

GIMSO extends to linking, loading, and all constants.

Special UB-related constants like `undef` are converted to the zero value for the given type. Together with the rule that `alloca` zero-initializes memory, this means that there is no uninitialized data in GIMSO.

Global values - i.e. pointer values whose value is resolved by linking and loading - are resolved according to the following rules:

- All ODR (one definition rule) flags are dropped (so for example `linkonce_odr` becomes `linkonce_any`), so the compiler cannot assume that an ODR value will be replaced with a compatible value.

- Available linkage is replaced with normal extern linkage. This prevents the compiler from making assumptions about what the linked-against value ends up being.

- Global values produce a flight pointer and all uses of that pointer are checked under the GIMSO rules we've already described.

This means, for example, that if one module defines `x` to be a function and another module declares an `extern char x[]`, then any uses of `x` as a readable/writable value will result in panics at time of use.

# Other Instructions

Now let's consider the rest of the LLVM IR instruction set. Most of these instructions have either totally uninteresting semantics in GIMSO (i.e. they just do the same thing they would have done in LLVM IR) or they have semantics that are easy to understand if you understand the discussion in previous sections. Hence, this section will proceed through the remaining instructions quickly.

## Control Flow

The `ret` instruction returns a value to the caller. See [`call`](#call) for more information.

The `br` instruction branches either conditionally (with two destinations) or unconditionally. GIMSO has no effect on this instruction.

The `switch` instruction branches based on matching an integer value against some possibilities, and has a mandatory default destination. GIMSO has no effect on this instruction.

The `indirectbr` instruction is for implementing the computed goto extension supported by GCC and clang. GIMSO converts all block labels to integers and treats the `indirectbr` as a switch on those labels.

## Math

The `fneg`, `add`, `fadd`, `sub`, `fsub`, `mul`, `fmul`, `udiv`, `sdiv`, `fdiv`, `urem`, `srem`, `frem`, `shl`, `lshr`, `ashr`, `and`, `or`, and `xor` instructions have UB-free semantics under GIMSO. I.e. all LLVM IR UB flags and metadata are dropped.

## Aggregates

The `extractelement`, `insertelement`, `shufflevector`, `extractvalue`, and `insertvalue` instructions have the usual semantics under GIMSO. Note that structs, arrays, and vectors that contain `ptr` type are really containing both the intval and capability of each of those pointers.

## Conversions

The [`inttoptr`](#inttoptr) and [`ptrtoint`](#ptrtoint) conversion instructions were discussed already.

GIMSO has no opinion on the behavior of `trunc`, `zext`, `sext`, `fptrunc`, `fpext`, `fptoui`, `fptosi`, `uitofp`, and `sitofp` other than dropping UB flags.

`addrspacecast` is accepted, though GIMSO rejects LLVM IR that uses any pointers not in addrspace 0.

`bitcast` between pointer types is accepted, is treated as an identity, and it is meaningless ever since LLVM moved to opaque pointer types. Note that `bitcast` cannot be used for `inttoptr` or `ptrtoint` (hence why those are separate instructions).

## Comparisons

GIMSO has no opinion on `icmp`, `fcmp`, or `select` instructions.

## Atomics

The `cmpxchg` and `atomicrmw` instructions with non-`ptr` type are implemented by doing all of the checks that a [`store`](#store) would have done, and then executing the atomic.

For `ptr` type atomics, the memory location is placed in atomic mode so that the pointer can be atomically operated on in the shadow address space.

## Data Movement

GIMSO has no opinion on the `phi` instruction.

GIMSO turns `freeze` into an identity, since GIMSO replaces all `undef`/`poison` with zero.

# Intrinsics

*FIXME: This needs to be expanded upon.*

GIMSO supports almost all LLVM intrinsics, which means that Fil-C supports almost all clang and GCC builtins.

The rules are simple:

- If the intrinsic does not access memory, then it is allowed.

- If the intrinsic does access memory, then either the intrinsic is disallowed entirely, or is allowlisted in Fil-C because the GIMSO rules are applied to that intrinsic (i.e. all of the safety checks necessary are inserted before the intrinsic executes).

Additionally, `memcpy`, `memmove`, and `memset` are supported with special Fil-C rules.

## Memcpy

GIMSO says that every `memcpy` is a `memmove` to avoid any undefined behavior in case of overlapping copies.

## Memmove

Before any data is moved, both the source and destination are bounds-checked.

Moving data from one allocation to another using `memmove` means that:

- If the two pointers are in phase (i.e. `dst % 8 == src % 8`) then:
    - All pointer-sized words that fit within the copied range are copied along with their capabilities.
    - If there is a pointer at the beginning or end of the range that is partially copied over, then the capability is reset to null.
- Otherwise, the capabilities for the entire range in the destination are reset to null.

## Memset

Before any data is set, the destination is bounds-checked.

All capabilities that overlap the destination range are reset to null.

# Builtins

*FIXME: This needs to be expanded upon.*

Fil-C supports a large set of builtins, many of which are [documented in `stdfil.h`](stdfil.html).

# Inline Assembly

GIMSO recognizes all safe inline assembly.

Currently, that means only accepting blank inline assembly, like:

    asm volatile ("" : : : "memory");

And:

    asm ("" : "+r"(value));

