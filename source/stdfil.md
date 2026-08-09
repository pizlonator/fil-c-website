# `stdfil.h` Reference

Fil-C provides a bonus standard header called `stdfil.h`. It's in the default include path of the Fil-C clang compiler, so you can include it like so:

    #include <stdfil.h>

You do not have to include this header to get C code to work in Fil-C. The purpose of this header is to provide bonus functionality that only Fil-C can offer, as well as some helper functions to make it easier to port existing C code to Fil-C.

This header sits *below* libc. In fact, libc cannot be implemented without the functionality that this header provides. For example, `malloc` in the Fil-C libc is implemented as just a call to `zgc_alloc`. Similarly, `free` is just `zgc_free`.

This page provides a reference guide for functions in `stdfil.h`.

<a name="FILC_VERSION"></a>
## `FILC_VERSION`

    #define FILC_VERSION 683u

The Fil-C version. The convention is that the major version gets multiplied by 10000, and the low three digits are the minor version.

Examples:

- If the version was 0.666 then `FILC_VERSION` would be `666u`.

- If the version was 1.23, then `FILC_VERSION` would be `10023`.

<a name="zversion"></a>
## `zversion`

    unsigned zversion(void);

Returns the Fil-C version according to the runtime. May be different than `FILC_VERSION` if you build against one version of Fil-C and run against a different version.

<a name="zerror"></a>
## `zerror`

    void zerror(const char* str);

Prints the given error message and shuts the program down using the Fil-C panic mechanism (prints a stack trace, kills the program in a way that the program cannot intercept).

<a name="zerrorf"></a>
## `zerrorf`

    void zerrorf(const char* str, ...);

Prints the given formatted error message and shuts the program down using the Fil-C panic mechanism (prints a stack trace, kills the program in a way that the program cannot intercept).

The error message is formatted using the Fil-C runtime's internal snprintf implementation (the same one used for `zprintf`).

<a name="ZASSERT"></a>
## `ZASSERT`

    #define ZASSERT(exp) do { \
            if ((exp)) \
                break; \
            zerrorf("%s:%d: %s: assertion %s failed.", __FILE__, __LINE__, __PRETTY_FUNCTION__, #exp); \
        } while (0)

This is an *always on* assert macro. The `exp` is always executed, and its result is always checked. Use this assert macro if you want asserts that don't get disabled in any compilation mode (even if `NDEBUG` is set, even if optimizations are enabled).

<a name="zsafety_error"></a>
## `zsafety_error`

    void zsafety_error(const char* str);

Prints the given error message and shuts the program down using the Fil-C panic mechanism. Exactly like `zerror` except it uses exactly the same error message that Fil-C uses for memory safety violations. Use this instead of `zerror` if you want to emphasize that the error is memory safety related.

<a name="zsafety_errorf"></a>
## `zsafety_errorf`

    void zsafety_errorf(const char* str, ...);

Prints the given error message and shuts the program down using the Fil-C panic mechanism. Exactly like `zerrorf` except it uses exactly the same error message that Fil-C uses for memory safety violations. Use this instead of `zerrorf` if you want to emphasize that the error is memory safety related.

The error message is formatted using the Fil-C runtime's internal snprintf implementation (the same one used for `zprintf`).

<a name="ZSAFETY_CHECK"></a>
## `ZSAFETY_CHECK`

    #define ZSAFETY_CHECK(exp) do { \
            if ((exp)) \
                break; \
            zsafety_errorf("%s:%d: %s: safety check %s failed.", \
                           __FILE__, __LINE__, __PRETTY_FUNCTION__, #exp); \
        } while (0)

This is an *always on* assert macro. The `exp` is always executed, and its result is always checked. Use this assert macro if you want asserts that don't get disabled in any compilation mode (even if `NDEBUG` is set, even if optimizations are enabled).

This is exactly like `ZASSERT` except that failures use `zsafety_errorf`, so that the error message emphasizes that the failure has to do with memory safery violations.

<a name="zgc_alloc"></a>
## `zgc_alloc`

    void* zgc_alloc(__SIZE_TYPE__ count);

Allocate `count` bytes of zero-initialized memory. May allocate slightly more than `count`, based
on the runtime's minalign (which is currently 16).
   
This is a GC allocation, so freeing it is optional. Also, if you free it and then use it, your
program is guaranteed to panic.

libc's malloc just forwards to this. There is no difference between calling `malloc` and
`zgc_alloc`.

<a name="zgc_aligned_alloc"></a>
## `zgc_aligned_alloc`

    void* zgc_aligned_alloc(__SIZE_TYPE__ alignment, __SIZE_TYPE__ count);

Allocate `count` bytes of memory with the GC, aligned to `alignment`. Supports very large alignments,
up to at least 128k (may support even larger ones in the future). Like with `zgc_alloc`, the memory
is zero-initalized.

<a name="zgc_realloc"></a>
## `zgc_realloc`

    void* zgc_realloc(void* old_ptr, __SIZE_TYPE__ count);

Reallocates the object pointed at by `old_ptr` to now have `count` bytes, and returns the new
pointer. `old_ptr` must satisfy `old_ptr == zgetlower(old_ptr)`, otherwise the runtime panics your
process. If `count` is larger than the size of `old_ptr`'s allocation, then the new space is
zero initialized.

libc's realloc just forwards to this. There is no difference between calling `realloc` and
`zgc_realloc`.

<a name="zgc_aligned_realloc"></a>
## `zgc_aligned_realloc`

    void* zgc_aligned_realloc(void* old_ptr, __SIZE_TYPE__ alignment, __SIZE_TYPE__ count);

Just like `zgc_realloc`, but allows you to specify arbitrary alignment on the newly allocated
memory.

<a name="zgc_realloc_preserving_alignment"></a>
## `zgc_realloc_preserving_alignment`

    void* zgc_realloc_preserving_alignment(void* old_ptr, __SIZE_TYPE__ count);

Just like `zgc_realloc`, but allocated the reallocated memory using the same alignment constraint
that the original memory was allocated with.

It's valid to call this with NULL `old_ptr` (just like `realloc`), and then you get default alignment.

This is a useful function and it would be great if something like it was part of the C stdlib.
Note that you can call this even for memory returned from `malloc`, since `malloc` just forwards to
`zgc_alloc`.

<a name="zgc_free"></a>
## `zgc_free`

    void zgc_free(void* ptr);

Frees the object pointed to by `ptr`. `ptr` must satisfy `ptr == zgetlower(ptr)`, otherwise the
runtime panics your process. `ptr` must point to memory allocated by `zgc_alloc`,
`zgc_aligned_alloc`, `zgc_realloc`, or `zgc_aligned_realloc`, and that memory must not have been
freed yet.

Freeing objects is optional in Fil-C, since Fil-C is garbage collected.

Freeing an object in Fil-C does not cause memory to be reclaimed immediately. Instead, it changes
the upper bounds of the object to be the lower bounds and sets the free flag. This causes all
subsequent accesses to trap with a Fil-C panic. This has two GC implications:

- The GC doesn't have to scan any outgoing pointers from this object, since those pointers are not
  reachable to the program (all accesses to them now trap). Hence, freeing an object has the
  benefit that dangling pointers don't lead to memory leaks, as they would in GC'd systems that
  don't support freeing.
  
- The GC can replace all pointers to this object with pointers that still have the same integer
  address but use the free singleton as their capability. This allows the GC to reclaim memory for
  this object on the next cycle, even if there were still dangling pointers to this object. Those
  dangling pointers would already have trapped on access even before the next cycle. Switching to
  the free singleton is not user-visible, except via ptr introspection like `%P` or
  `zptr_to_new_string`.

libc's free just forwards to this. There is no difference between calling `free` and `zgc_free`.

<a name="zgc_finq_new"></a>
## `zgc_finq_new`

    zgc_finq* zgc_finq_new(void);

Creates a new finalizer queue. Finalizer queues can be used to implement Java-style object finalization. To allocate a finalizable object, call `zgc_finq_alloc`. When a finalizable object becomes unreachable, the `zgc_finq` that it was allocated from will wake up from calls to `zgc_finq_wait` or start to return non-NULL from ccalls to `zgc_finq_poll`. The object (and anything it transitively reaches) will only be reclaimed after the object is dequeued from its `zgc_finq` and the object is not otherwise reachable.

Finalizable objects get one shot at being on the finalizer queue. If the object ends up on the finalizer queue (because it dies), ends up on a queue, and gets removed from the queue, and then becomes unreachable again, then it will not end up on the finalizer queue a second time.

Objects that die and end up on the finalizer queue will be treated as dead for the purpose of any weak references or weak maps that were created before the object gets dequeued from the queue.

<a name="zgc_finq_poll"></a>
## `zgc_finq_poll`

    void* zgc_finq_poll(zgc_finq* finq);

Poll to see if an object allocated with the finalizer queue has died. This always returns immediately. If there are no dead objects on the queue, this returns NULL. It's safe to call this from multiple threads.

<a name="zgc_finq_wait"></a>
## `zgc_finq_wait`

    void* zgc_finq_wait(zgc_finq* finq);

Wait until an object appears on the finalizer queue, and return it. This never returns NULL. It's safe to call this from multiple threads.

<a name="zgc_finq_alloc"></a>
## `zgc_finq_alloc`

    void* zgc_finq_alloc(zgc_finq* finq, __SIZE_TYPE__ size);

Allocate a finalizable object using the given finalizer queue and `size`. This is equivalent to `zgc_alloc` except that the object is finalizable.

Finalizable objects aren't actually reclaimed until you dequeue them from the `zgc_finq` using `zgc_finq_poll` or `zgc_finq_wait`, or until the `zgc_finq` becomes unreachable. Crucially, finalizable objects hold a weak reference to their `zgc_finq`. This means that:

    /* Allocate using an immediately dead finalizer queue */
    zgc_finq_alloc(zgc_finq_new(), 666);

Is just an inefficient way of saying:

    zgc_alloc(666);

<a name="zgc_finq_aligned_alloc"></a>
## `zgc_finq_aligned_alloc`

    void* zgc_finq_aligned_alloc(zgc_finq* finq, __SIZE_TYPE__ alignment, __SIZE_TYPE__ size);

Allocate an aligned finalizable object.

<a name="zgetlower"></a>
## `zgetlower`

    void* zgetlower(void* ptr);

Return the lower bound of the capability associated with `ptr`. This will be NULL if the pointer has no capability. The returned lower bound has the capability of `ptr`.

<a name="zgetupper"></a>
## `zgetupper`

    void* zgetupper(void* ptr);

Return the upper bound of the capability associated with `ptr`. This will be NULL if the pointer has no capability. The returned upper bound has the capability of `ptr`.

<a name="zis_readonly"></a>
## `zis_readonly`

    filc_bool zis_readonly(void* ptr);

Returns true if this is a readonly object. This will return false for special objects or NULL.

The `filc_bool` type is `_Bool` in C and `bool` in C++.

<a name="zlength"></a>
## `zlength`

    #define zlength(ptr) ({ \
            __typeof__((ptr) + 0) __d_ptr = (ptr); \
            (__SIZE_TYPE__)((__typeof__((ptr) + 0))zgetupper(__d_ptr) - __d_ptr); \
        })

Returns the array length of `ptr` - that is, how many elements of type `typeof(*ptr)` fit into the memory that is between where `ptr` points and `ptr`'s upper bound.

<a name="zhasvalidcap"></a>
## `zhasvalidcap`

    filc_bool zhasvalidcap(void* ptr);

Returns whether the `ptr` has a valid capability (not a NULL one) and that capability is not free.

<a name="zinbounds"></a>
## `zinbounds`

    static inline __attribute__((__always_inline__))
    filc_bool zinbounds(void* ptr)
    {
        return ptr >= zgetlower(ptr) && ptr < zgetupper(ptr);
    }

Tells you if the `ptr` is in bounds of its capability.

<a name="zvalinbounds"></a>
## `zvalinbounds`

    static inline __attribute__((__always_inline__))
    filc_bool zvalinbounds(void* ptr, __SIZE_TYPE__ size)
    {
        if (!size)
            return 1;
        return zinbounds(ptr) && zinbounds((char*)ptr + size - 1);
    }

Tells you if a `size` byte value is in bounds at the location pointed to by `ptr`.

<a name="zmkptr"></a>
## `zmkptr`

    static inline __attribute__((__always_inline__))
    void* zmkptr(void* object, unsigned long address)
    {
        char* ptr = (char*)object;
        ptr -= (unsigned long)object;
        ptr += address;
        return ptr;
    }

Constructs a new pointer whose intval is `address` and whose capability comes from `object`. Note that this is not a magical function; you could get the same effect yourself by using the snippet of code from inside this function. Crucially:

    char* ptr = (char*)object;
    ptr -= (unsigned long)object;

Creates a NULL pointer that has the capability of `object`. And:

    ptr += address;

Adjusts that pointer to point at `address` while still having `object`'s capability.

This idiom and function are useful when doing pointer math that is best expressed as integers while being explicit about which pointer's capability the resulting pointer gets.

It's not possible to use this function unsafely in the sense that you can only get a capability that you already had access to (i.e. the one from `object`) and in the worst case you'll end up with an out-of-bounds pointer that traps on every access.

The Fil-C compiler will infer `zmkptr` in "obvious" (to the compiler) situations, like:

    int* get_ptr_to_even_array_element(int* ptr)
    {
        return (int*)((uintptr_t)ptr & -8);
    }

You do not need to use `zmkptr` here; the compiler's gotchu.

<a name="zorptr"></a>
## `zorptr`

    static inline __attribute__((__always_inline__))
    void* zorptr(void* ptr, unsigned long bits)
    {
        return zmkptr(ptr, (unsigned long)ptr | bits);
    }

Helper to bitwise or some bits into a pointer.

<a name="zandptr"></a>
## `zandptr`

    static inline __attribute__((__always_inline__))
    void* zandptr(void* ptr, unsigned long bits)
    {
        return zmkptr(ptr, (unsigned long)ptr & bits);
    }

Helper to bitwise and some bits with a pointer.

<a name="zxorptr"></a>
## `zxorptr`

    static inline __attribute__((__always_inline__))
    void* zxorptr(void* ptr, unsigned long bits)
    {
        return zmkptr(ptr, (unsigned long)ptr ^ bits);
    }

Helper to bitwise xor some bits with a pointer.

<a name="zretagptr"></a>
## `zretagptr`

    static inline __attribute__((__always_inline__))
    void* zretagptr(void* newptr, void* oldptr,
                    unsigned long mask)
    {
        ZASSERT(!((unsigned long)newptr & ~mask));
        return zorptr(newptr, (unsigned long)oldptr & ~mask);
    }

Returns a pointer that points to `newptr` masked by the `mask`, while preserving the
bits from `oldptr` masked by `~mask`. Also asserts that `newptr` has no bits in `~mask`.

Useful for situations where you want to reassign a pointer from `oldptr` to `newptr` but
you have some kind of tagging in `~mask`.

<a name="zmemset"></a>
## `zmemset`

    void zmemset(void* dst, unsigned value, __SIZE_TYPE__ count);

This is exactly like `memset` except that `zmemset` strongly guarantees that the compiler does not know what it is, and so the compiler will not optimize calls to it. The memory pointed to by `dst` will really be set.

Useful for debugging and testing the compiler. Also useful in security-critical situations (like if you want to clear a secret from memory).

<a name="zmemmove"></a>
## `zmemmove`

    void zmemmove(void* dst, void* src, __SIZE_TYPE__ count);

This is exactly like `memmove` except that `zmemmove` strongly guarantees that the compiler does not know what it is, and so the compiler will not optimize calls to it. The memory pointed to by `src` will really be read and whatever is read from there will really be stored to `dst`.

Useful for debugging and testing the compiler. It might also be useful in security-critical situations for similar reasons to why `zmemset` is useful.

<a name="zsetcap"></a>
## `zsetcap`

    void zsetcap(void* dst, void* object, __SIZE_TYPE__ size);

Set the capability of a range of memory, without altering the values in that memory.
 
`dst` must be pointer-aligned. `size` is in bytes, and must be pointer-aligned.

<a name="zptr_to_new_string"></a>
## `zptr_to_new_string`

    char* zptr_to_new_string(const void* ptr);

Allocates a new string (with `zgc_alloc(char, strlen+1)`) and prints a dump of the `ptr` (including its capability) to that string. Returns that string.

This is exposed as `%P` in the `zprintf` family of functions.

<a name="zptr_contents_to_new_string"></a>
## `zptr_contents_to_new_string`

    char* zptr_contents_to_new_string(const void* ptr);

Allocates a new string (with `zgc_alloc(char, strlen+1)`) and prints a dump of the `ptr` and the entire
object contents to that string. Returns that string.

This is exposed as `%O` in the `zprintf` family of functions.

<a name="zptrtable_new"></a>
## `zptrtable_new`

    zptrtable* zptrtable_new(void);

The `zptrtable` can be used to encode pointers as integers. The integers are `__SIZE_TYPE__` but
tend to be small; you can usually get away with storing them in 32 bits.

The `zptrtable` itself is garbage collected, so you don't have to free it (and attempting to
free it will kill your process).

You can have as many `zptrtable`s as you like.

Encoding a ptr is somewhat expensive. Currently, the `zptrtable` takes a per-`zptrtable` lock to
do it (so at least it's not a global lock).

Decoding a ptr is cheap. There is no locking.

The `zptrtable` automatically purges pointers to free objects and reuses their indices.
However, the table does keep a strong reference to objects. So, if you encode a ptr and then
never free it, then the `zptrtable` will keep it alive. But if you free it, the `zptrtable` will
autopurge it.

If you try to encode a ptr to a free object, you get 0. If you decode 0 or if the object that
would have been decoded is free, this returns NULL. Valid pointers encode to some non-zero
integer. You cannot rely on those integers to be sequential, but you can rely on them to:

- Stay out of the the "null page" (i.e. they are >=16384) just to avoid clashing with
  assumptions about pointers (even though the indices are totally no pointers).

- Fit in 32 bits unless you have hundreds of millions of objects in the table.

- Definitely fit in 64 bits in the general case.

- Be multiples of 16 to look even more ptr-like (and allow low bit tagging if you're into
  that sort of thing).

The `zptrtable` is useful if you're porting code that really needs to store pointers as integers somewhere.

<a name="zptrtable_encode"></a>
## `zptrtable_encode`

    __SIZE_TYPE__ zptrtable_encode(zptrtable* table, void* ptr);

Encode a `ptr` as an integer and return that integer. Subsequent calls to `zptrtable_decode` with the same table and that same integer will give you back `ptr` along with its capability, so long as `ptr` is not freed.

<a name="zptrtable_decode"></a>
## `zptrtable_decode`

    void* zptrtable_decode(zptrtable* table, __SIZE_TYPE__ encoded_ptr);

Decode an integer for a pointer previously encoded into the given table. Returns that pointer along with its capability, or NULL if the pointer got freed, or if the integer doesn't correspond to any pointer that had ever been encoded.

<a name="zexact_ptrtable_new"></a>
## `zexact_ptrtable_new`

    zexact_ptrtable* zexact_ptrtable_new(void);

The `zexact_ptrtable` is like `zptrtable`, but:

- The encoded ptr is always exactly the pointer's integer value.

- Decoding is slower and may have to grab a lock.

- Decoding a pointer to a freed object gives exactly the pointer's integer value but with a null
  capability (so you cannot dereference it).

<a name="zexact_ptrtable_new_weak"></a>
## `zexact_ptrtable_new_weak`

    zexact_ptrtable* zexact_ptrtable_new_weak(void);

Create a weak `zexact_ptrtable`. This weakly holds onto any encoded pointers and drops them if they
are either freed, or if the only references left to them are weak. So, for example, if the last
reference to a pointer is from the weak exact ptrtable, then the weak exact ptrtable will drop the
reference. Decoding that pointer will then give an invalid pointer.

<a name="zexact_ptrtable_is_weak"></a>
## `zexact_ptrtable_is_weak`

    filc_bool zexact_ptrtable_is_weak(zexact_ptrtable* table);

Tells you if this exact ptrtable is weak or not.

<a name="zexact_ptrtable_encode"></a>
## `zexact_ptrtable_encode`

    __SIZE_TYPE__ zexact_ptrtable_encode(zexact_ptrtable* table, void* ptr);

Returns the integer value of `ptr` after encoding it into the table. Pointers encoded into the table can be retrieved back from the table (including their full capability) by passing their integer value into `zexact_ptrtable_decode`.

Note that since this returns the `ptr`'s integer value, it's OK to ignore the return value and just cast the `ptr` to an integer after calling this function.

If the table is weak (allocated with `zexact_ptrtable_new_weak`), then the pointer will no longer be tracked by the table if it becomes otherwise unreachable, or if it is freed.

If the table is strong (allocated with `zexact_ptrtable_new`), then the pointer will no longer be tracked by the table if it is freed.

<a name="zexact_ptrtable_decode"></a>
## `zexact_ptrtable_decode`

    void* zexact_ptrtable_decode(zexact_ptrtable* table, __SIZE_TYPE__ encoded_ptr);

Given an integer value for a pointer encoded with `zexact_ptrtable_encode` in the given `table`, returns that pointer along with its capability.

<a name="zweak_new"></a>
## `zweak_new`

    zweak* zweak_new(void* ptr);

Create a new weak pointer. Weak pointers automatically become NULL if the GC was not able to
establish that the pointed-at object is live via any chain of non-weak pointers starting from GC
roots.

Weak pointers also become NULL if the pointed-at object is freed.

<a name="zweak_get"></a>
## `zweak_get`

    void* zweak_get(zweak* weak);

Get the value of the weak pointer. This returns exactly the pointer passed to `zweak_new`, or it
returns NULL, if the object was established to be dead by GC.

<a name="zweak_map_new"></a>
## `zweak_map_new`

    zweak_map* zweak_map_new(void);

Create a new weak_map. Weak maps maintain key-value pairs such that if the key is live during GC
then the value is marked, but otherwise it isn't.

<a name="zweak_map_set"></a>
## `zweak_map_set`

    void zweak_map_set(zweak_map* map, void* key, void* value);

Create or replace a mapping for a given key. The mapping will now refer to the given value.

If the key has an invalid capability, then this keeps the value alive forever. For example, it's
valid to use a NULL key.

Using a NULL value deletes the mapping.

Note that two keys that are `==` according to the C `==` operator may get different mappings if they
have different capabilities.

This is an atomic operation with respect to other calls to `zweak_map_set` and `zweak_map_get`.

<a name="zweak_map_get"></a>
## `zweak_map_get`

    void* zweak_map_get(zweak_map* map, void* key);

Given a key, returns the value.

This is an atomic operation with respect to other calls to `zweak_map_set` and `zweak_map_get`.

<a name="zweak_map_size"></a>
## `zweak_map_size`

    __SIZE_TYPE__ zweak_map_size(zweak_map* map);

Reports the number of entries currently in the weak map.

Note that the value returned by this function is sensitive to GC. For example, if the weak map contains mappings based on dead keys but the GC hasn't run yet, then this will count those keys.

<a name="zweak_map_get_iter"></a>
## `zweak_map_get_iter`

    zweak_map_iter* zweak_map_get_iter(zweak_map* map);

This allows you to commence iterating over a weak map. Correct iterator usage:
   
    zweak_map_iter* iter = zweak_map_get_iter(map);
    while (zweak_map_iter_next(iter)) {
        void* key = zweak_map_iter_key(iter);
        void* value = zweak_map_iter_value(iter);
        ... do stuff with key and value ...
    }

Note that you have to call `zweak_map_iter_next` to get to the first element.

It's possible that this will return keys that were otherwise dead because the GC hadn't run. If it does so, then those keys will become live, by virtue of `zweak_map_iter_key` returning them as ordinary (i.e. strong) references.

<a name="zweak_map_iter_next"></a>
## `zweak_map_iter_next`

    filc_bool zweak_map_iter_next(zweak_map_iter* iter);

Advance the iterator to the next element and return whether there is a next element. Note that an iterator freshly returned from `zweak_map_get_iter` is at a position "before" the first element, so you must call `zweak_map_iter_next` to get it to the first element.

<a name="zweak_map_iter_key"></a>
## `zweak_map_iter_key`

    void* zweak_map_iter_key(zweak_map_iter* iter);

Get the key of the iterator from the current position. Only valid to call if you have called `zweak_map_iter_next` and it returned true.

<a name="zweak_map_iter_value"></a>
## `zweak_map_iter_value`

    void* zweak_map_iter_value(zweak_map_iter* iter);

Get the value of the iterator from the current position. Only valid to call if you have called `zweak_map_iter_next` and it returned true.

<a name="zprint"></a>
## `zprint`

    void zprint(const char* str);

Low level printing function. This prints to `stderr` (i.e. FD 2). It prints directly, without logging, and it bypasses libc.

<a name="zprint_long"></a>
## `zprint_long`

    void zprint_long(long x);

Low level printing function that prints an integer. This prints to `stderr` (i.e. FD 2). It prints directly, without logging, and it bypasses libc. It uses the Yolo-libc's `snprintf` for formatting the integer, so it's suitable for debugging the Fil-C runtime's internal `snprintf`.

This function is barely used. It's useful for very low level bring-up of the Fil-C userland.

<a name="zprint_ptr"></a>
## `zprint_ptr`

    void zprint_ptr(const void* ptr);

Low level printing function that prints a pointer and its capability. This prints to `stderr` (i.e. FD 2). It prints directly, without logging, and it bypasses libc.

This function is barely used. It's useful for very low level bring-up of the Fil-C userland.

<a name="zstrlen"></a>
## `zstrlen`

    __SIZE_TYPE__ zstrlen(const char* str);

Low level string length function. This is not particularly efficient. This is useful for low level bring-up of the Fil-C userland.

<a name="zisdigit"></a>
## `zisdigit`

    int zisdigit(int chr);

Low level function that tells if the character is a digit. This is not particularly efficient. This is useful for low level bring-up of the Fil-C userland.

<a name="zvsprintf"></a>
## `zvsprintf`

    int zvsprintf(char* buf, const char* format, __builtin_va_list args);

This is almost like `vsprintf`, but because Fil-C knows the upper bounds of buf, this actually ends
up working exactly like `snprintf` where the size is upper-ptr. Hence, in Fil-C, it's preferable
to call `zsprintf` instead of `zsnprintf`.

In the Fil-C libc, `sprintf` (without the z) behaves kinda like `zsprintf`, but traps on OOB.

The main difference from the libc `sprintf` is that it uses a different implementation under the hood.
This is based on the samba `snprintf`, origindally by Patrick Powell, but it uses the `zstrlen`/`zisdigit`/etc functions rather than the libc ones, and it has one additional feature:

- `%P`, which prints the full Fil-C pointer (i.e. `0xptr,0xlower,0xupper,...type...`).

- `%O`, which prints the full Fil-C object contents.

It's not obvious that this code will do the right thing for floating point formats. But this code is
pizlonated, so if it goes wrong, at least it'll stop your program from causing any more damage.

<a name="zsprintf"></a>
## `zsprintf`

    int zsprintf(char* buf, const char* format, ...);

Like `zvsprintf`, but takes variadic arguments rather than the `va_list`.

<a name="zvsnprintf"></a>
## `zvsnprintf`

    int zvsnprintf(char* buf, __SIZE_TYPE__ size, const char* format, __builtin_va_list args);

Like `zvsprintf`, but takes the size explicitly.

<a name="zsnprintf"></a>
## `zsnprintf`

    int zsnprintf(char* buf, __SIZE_TYPE__ size, const char* format, ...);

Like `zsprintf`, but takes the size explicitly.

<a name="zvasprintf"></a>
## `zvasprintf`

    char* zvasprintf(const char* format, __builtin_va_list args);

Uses `zvsnprintf` to allocate a string and return it.

<a name="zasprintf"></a>
## `zasprintf`

    char* zasprintf(const char* format, ...);

Uses `zvsnprintf` to allocate a string and return it.

<a name="zvprintf"></a>
## `zvprintf`

    void zvprintf(const char* format, __builtin_va_list args);

Like `zvsprintf` but prints to FD 2 (stderr). The whole string gets printed in one syscall if possible but without any other buffering.

<a name="zprintf"></a>
## `zprintf`

    void zprintf(const char* format, ...);

Like `zvsprintf` but prints to FD 2 (stderr). The whole string gets printed in one syscall if possible but without any other buffering.

<a name="zargs"></a>
## `zargs`

    void* zargs(void);

Returns a readonly snapshot of the passed-in arguments object. The arguments are laid out as if you
had written a struct with the arguments as fields, provided that you padded those fields just like your platform's calling convention would (so for example, a function taking two `char` arguments would have 7 bytes of padding between them).

This is useful for implementing `libffi`. It's also appropriate to use directly, if you understand the calling convention.

<a name="zcall"></a>
## `zcall`

    void* zcall(void* callee, void* args);

Calls the `callee` with the arguments being a snapshot of the passed-in `args` object. The `args`
object does not have to be readonly, but can be.

Returns a readonly object containing the return value.

Beware that C/C++ functions declared to return structs really return void, and they have some
special parameter that is a pointer to the buffer where the return value is stored. Also beware of other calling convention requirements for padding.

<a name="zreturn"></a>
## `zreturn`

    void zreturn(void* rets);

Returns from the calling function, passing the contents of the rets object as the return value.

<a name="zunsafe_call"></a>
## `zunsafe_call`

    unsigned long zunsafe_call(const char* symbol_name, ...);

Performs an unsafe call to Yolo-land.

This barely works! It's not intended for full-blown interop with Yolo code. In particular, right
now Fil-C code expects to live in a Fil-C runtime, which precludes the use of a Yolo libc.

This function is mostly useful for implementing constant-time crypto libraries or other kernels
that need to be written in assembly. Currently the only user of this function is [OpenSSL if you
compile it with assembly enabled](constant_time_crypto.html).

The first argument is the Yolo symbol name of the function to be called. It must be a string
literal. The remaining arguments are passed along using Yolo C ABI conventions.

<a name="zunsafe_fast_call"></a>
## `zunsafe_fast_call`

    unsigned long zunsafe_fast_call(const char* symbol_name, ...);

Exactly like `zunsafe_call`, but for those cases where you know that the call will complete in a bounded (and sufficiently short) amount of time.

In the worst case, if you call this instead of `zunsafe_call`, then you're just delaying GC progress. It's not the end of the world. Maybe we're talking about denial of service, at worst.

Currently the only user of this function is [OpenSSL if you compile it with assembly
enabled](constant_time_crypto.html).

This only turns into a big problem if you use `zunsafe_fast_call` to do something that has truly unbounded execution time (like a syscall that blocks indefinitely, or an infinite loop). Otherwise it's a perf pathology that you may or may not care enough to fix.

<a name="zunsafe_buf_call"></a>
## `zunsafe_buf_call`

    unsigned long zunsafe_buf_call(__SIZE_TYPE__ size, const char* symbol_name, ...);

Performs either a `zunsafe_fast_call` or `zunsafe_call` depending on the `size`.

Currently the only user of this function is [OpenSSL if you compile it with assembly
enabled](constant_time_crypto.html).

<a name="zcheck"></a>
## `zcheck`

    void zcheck(void* ptr, __SIZE_TYPE__ size);

Checks that you can read and write `size` bytes at `ptr` using a similar kind of safety check that Fil-C would use if you accessed a `size` byte struct at `ptr`.

<a name="zcheck_readonly"></a>
## `zcheck_readonly`

    void zcheck_readonly(void* ptr, __SIZE_TYPE__ size);

Checks that you can *read* `size` bytes at `ptr` using a similar kind of safety check that Fil-C would use if you read a `size` byte struct at `ptr`.

<a name="zchecked_add"></a>
## `zchecked_add`

    static inline __SIZE_TYPE__ zchecked_add(__SIZE_TYPE__ a, __SIZE_TYPE__ b)
    {
        __SIZE_TYPE__ result;
        if (__builtin_add_overflow(a, b, &result))
            zsafety_errorf("%zu + %zu overflowed.", a, b);
        return result;
    }

Overflow-checked addition of `size_t` integers. If the overflow check fails, the process panics like it would from a Fil-C safety check.

<a name="zchecked_mul"></a>
## `zchecked_mul`

    static inline __SIZE_TYPE__ zchecked_mul(__SIZE_TYPE__ a, __SIZE_TYPE__ b)
    {
        __SIZE_TYPE__ result;
        if (__builtin_mul_overflow(a, b, &result))
            zsafety_errorf("%zu * %zu overflowed.", a, b);
        return result;
    }

Overflow-checked multiplication of `size_t` integers. If the overflow check fails, the process panics like it would from a Fil-C safety check.

<a name="zcan_va_arg"></a>
## `zcan_va_arg`

    static inline filc_bool
    zcan_va_arg(__builtin_va_list list)
    {
        return zvalinbounds(*(void**)list, 8);
    }

Tells you if a `va_list` has another argument available.

<a name="zget_jmp_buf_impl_frame"></a>
## `zget_jmp_buf_impl_frame`

    void* zget_jmp_buf_impl_frame(zjmp_buf* jmp_buf_impl);

Given the internal jmp_buf object, return the frame that it jumps to. This is the `__builtin_frame_address()` or `_Unwind_GetCFA()` value for that frame. Note that this is a pointer that has no capability (it might as well be an integer).

<a name="zget_jmp_buf_frame"></a>
## `zget_jmp_buf_frame`

    void* zget_jmp_buf_frame(void* jmp_buf);

Call this with a `jmp_buf`. Returns the frame that you would have gotten from `__builtin_frame_address` of the frame that this `jmp_buf` jumps to.

<a name="zfence"></a>
## `zfence`

    static inline void zfence(void)
    {
        __c11_atomic_thread_fence(__ATOMIC_SEQ_CST);
    }

Full memory fence (sequentially consistent).

<a name="zstore_store_fence"></a>
## `zstore_store_fence`

    static inline void zstore_store_fence(void)
    {
    #if defined(__x86_64__) || defined(__x86__)
        __c11_atomic_signal_fence(__ATOMIC_SEQ_CST);
    #else
        __c11_atomic_thread_fence(__ATOMIC_SEQ_CST);
    #endif
    }

Store-store fence. On x86/x86_64 this is just a compiler fence. On other architectures, this may be a full memory fence.

<a name="zcompiler_fence"></a>
## `zcompiler_fence`

    static inline void zcompiler_fence(void)
    {
        __c11_atomic_signal_fence(__ATOMIC_SEQ_CST);
    }

Compiler fence only - prevents compiler reordering but emits no instructions on most architectures.

<a name="zcallee"></a>
## `zcallee`

    void* zcallee(void);

Gets the function pointer of the currently called function. Note that if the function is doing closure tricks, then this function pointer will have a the closure as part of its capability.

<a name="zclosure_new"></a>
## `zclosure_new`

    void* zclosure_new(void* function, void* data);

Create a closure out of the given function.

Example:

    static void foo(void)
    {
        ZASSERT(!strcmp(zcallee_closure_data(), "hello"));
    }

    static void bar(void)
    {
        void (*foo_closure)(void) = zclosure_new(foo, "hello");
        foo_closure();
    }

This API can be used directly, but is mostly here to support libffi's closure API.

Note that the Fil-C implementation of closures does not rely on JIT permissions.

<a name="zclosure_get_data"></a>
## `zclosure_get_data`

    void* zclosure_get_data(void* closure);

Get the data for the given closure. If the passed-in pointer is not a closure pointer, then this
panics.

<a name="zclosure_set_data"></a>
## `zclosure_set_data`

    void zclosure_set_data(void* closure, void* data);

Set the data for the given closure. If the passed-in pointer is not a closure pointer, then this
panics.

<a name="zcallee_closure_data"></a>
## `zcallee_closure_data`

    void* zcallee_closure_data(void);

Get the data for the currently called closure. If the callee is not a closure, then this panics.

This is a fast shorthand for `zclosure_get_data(zcallee())`.

<a name="zgc_request_and_wait"></a>
## `zgc_request_and_wait`

    void zgc_request_and_wait(void);

Request and wait for a fresh garbage collection cycle. If a GC cycle is already happening, then this
will cause another one to happen after that one finishes, and will wait for that one.

GCing doesn't automatically decommit the freed memory. If you want that to also happen, then call
zscavenge_synchronously() after this returns.

If the GC is running concurrently (the default), then other threads do not wait. Only the calling
thread waits.

If the GC is running in stop-the-world mode (not the default, also not recommended), then this will
stop all threads to do the GC.

This is equivalent to `zgc_wait(zgc_request_fresh())`.

<a name="zgc_completed_cycle"></a>
## `zgc_completed_cycle`

    zgc_cycle_number zgc_completed_cycle(void);

Get the last completed GC cycle number. If this number increments, it means that the GC
finished.

This function is useful for determining if it's a good time to remove dead weak references from
whatever data structures you have that hold onto them (like if you have an array of weak refs). If
this number is greater than the last time you swept weak references, then you should probably do it
again.

<a name="zgc_requested_cycle"></a>
## `zgc_requested_cycle`

    zgc_cycle_number zgc_requested_cycle(void);

Get the last requested GC cycle number. If this number is greater than the last completed cycle,
then it means that the GC is either running right now or is about to be running.

<a name="zgc_try_request"></a>
## `zgc_try_request`

    zgc_cycle_number zgc_try_request(void);

Request that the GC starts if it hasn't already. Returns the requested cycle number.

If you know that you've created garbage and you want it cleaned up, then this function is probably
not what you want, since it does nothing during already running cycles, and already running cycles
will "float" (i.e. won't collect) garbage created during those cycles.

Usually you want `zgc_request_fresh()`.

This returns immediately, since the GC is concurrent.

<a name="zgc_request_fresh"></a>
## `zgc_request_fresh`

    zgc_cycle_number zgc_request_fresh(void);

Request a fresh GC cycle. If the GC is running right now, then this requests another cycle after
this one. Returns the requested cycle number.

Call this if you know you created garbage, and you want it cleaned up.

<a name="zgc_wait"></a>
## `zgc_wait`

    void zgc_wait(zgc_cycle_number cycle);

Wait for the given GC cycle to finish.

<a name="zscavenge_synchronously"></a>
## `zscavenge_synchronously`

    void zscavenge_synchronously(void);

Request a synchronous scavenge. This decommits all memory that can be decommitted.

If you want to free all memory that can possibly be freed and you're happy to wait, then you should
first `zgc_request_and_wait()` and then `zscavenge_synchronously()`.

Note that it's fine to call this whether the scavenger is suspended or not. Even if the scavenger is
suspended, this will scavenge synchronously. If the scavenger is not suspended, then this will at worst
contend on some locks with the scavenger thread (and at best cause the scavenge to happen faster due to
parallelism).

<a name="zscavenger_suspend"></a>
## `zscavenger_suspend`

    void zscavenger_suspend(void);

Suspend the scavenger. The scavenger is a thread that returns memory to the OS.

Suspending the scavenger might be a small speed-up but at the cost of never returning memory to the OS.

Suspending the scavenger does not suspend the GC.

You can call this function multiple times. Then, to resume the scavenger, you'd have to call `zscavenger_resume()` the same number of times.

<a name="zscavenger_resume"></a>
## `zscavenger_resume`

    void zscavenger_resume(void);

Resume the scavenger, if it was suspended by a prior `zscavenger_suspend()`.

<a name="zlock_runtime_threads"></a>
## `zlock_runtime_threads`

    void zlock_runtime_threads(void);

Forces the runtime to immediately create whatever threads it needs, and to disable shutting them down on demand.

This is useful if you're about to install a seccomp filter that prevents thread creation.

<a name="zdump_stack"></a>
## `zdump_stack`

    void zdump_stack(void);

Dumps a Fil-C stack trace to stderr (FD 2).

<a name="zstack_scan"></a>
## `zstack_scan`

    typedef struct zstack_frame_description zstack_frame_description;
    
    struct zstack_frame_description {
        const char* function_name;
        const char* filename;
        unsigned line;
        unsigned column;
    
        /* Whether the frame supports throwing (i.e. the llvm::Function did not have the nounwind
           attribute set).
        
           C code by default does not support throwing, but you can enable it with -fexceptions. 
        
           Supporting throwing doesn't mean that there's a personality function. It's totally unrelated
           For example, a C++ function may have a personality function, but since it's throw(), it's got
           nounwind set, and so it doesn't supporting throwing.
        
           By convention, this is always false for inline frames (is_inline == true). */
        filc_bool can_throw;
    
        /* Whether the frame supports catching. Only frames that support catching can have personality
           functions. But not all of them do.
        
           By convention, this is always false for inline frames (is_inline == true). */
        filc_bool can_catch;
    
        /* Tells if this frame description corresponds to an inline frame. */
        filc_bool is_inline;
    
        /* personality_function and eh_data are set for frames that can catch exceptions. The eh_data is
           NULL if the personality_function is NULL. If the personality_function is not NULL, then the
           eh_data's meaning is up to that function. The signature of the personality_function is up to the
           compiler. The signature of the eh_data is up to the compiler. When unwinding, you can call the
           personality_function, or not - up to you. If you call it, you have to know what the signature
           is. It's expected that only the libunwind implementation calls personality_function, since
           that's what knows what its signature is supposed to be.
        
           By convention, these are always NULL for inline frames (is_inline == true). */
        void* personality_function;
        void* eh_data;
    };
    
    /* Walks the Fil-C stack and calls callback for every frame found. Continues walking so long as the
       callback returns true. Guaranteed to skip the zstack_scan frame. */
    void zstack_scan(filc_bool (*callback)(
                         const zstack_frame_description* description,
                         void* arg),
                     void* arg);

Walk the Fil-C stack and get a bunch of internal data about each frame.

<a name="zthread_self_id"></a>
## `zthread_self_id`

    unsigned zthread_self_id(void);

Return an integer identifying the current thread. This is equivalent to Linux `gettid(2)`. Note that this value will change after `fork(2)`. Unlike `gettid(2)`, this is not a system call. It's very fast.

<a name="zstack_pointer"></a>
## `zstack_pointer`

    void* zstack_pointer(void);

Returns the current stack pointer.

<a name="zstack_limit"></a>
## `zstack_limit`

    void* zstack_limit(void);

Returns the stack limit (the lowest address of the stack).

<a name="zstack_top"></a>
## `zstack_top`

    void* zstack_top(void);

Returns the top of the stack (the highest address).

<a name="zxgetbv"></a>
## `zxgetbv`

    unsigned long zxgetbv(void);

X86 xgetbv intrinsic. Reads XCR0. May trap if the CPU doesn't support the xsave feature.

<a name="zdump_heap"></a>
## `zdump_heap`

    void zdump_heap(int fd);

Dumps the heap to the given file descriptor.

<a name="zdump_stacks"></a>
## `zdump_stacks`

    void zdump_stacks(void);

Dumps all stacks to stderr (FD 2).

<a name="zis_unsafe_signal_for_kill"></a>
## `zis_unsafe_signal_for_kill`

    filc_bool zis_unsafe_signal_for_kill(int signo);

Returns if the signal is unsafe for raising according to Fil-C rules. You will get `ENOSYS` if you try to raise one of these signals.

Signals used internally by the libc are flagged as being unsafe for kill.

<a name="zis_unsafe_signal_for_handlers"></a>
## `zis_unsafe_signal_for_handlers`

    filc_bool zis_unsafe_signal_for_handlers(int signo);

Returns if the signal is unsafe for handlers according to Fil-C rules. You will get `ENOSYS` if you try to register a handler for one of these signals.

Signals like SIGILL, SIGSEGV, SIGTRAP, and SIGBUS are flagged as being unsafe for handlers in Fil-C.

<a name="zset_quiet_panic"></a>
## `zset_quiet_panic`

    void zset_quiet_panic(filc_bool value);

If you pass true, this enables quiet panics, where the Fil-C runtime does not print any output in case of a Fil-C panic.

<a name="zget_quiet_panic"></a>
## `zget_quiet_panic`

    filc_bool zget_quiet_panic(void);

Tells if quiet panic mode is enabled.

<a name="zsetproctitle"></a>
## `zsetproctitle`

    void zsetproctitle(const char* title);

Set the process title. `title` must be a null-terminated string (otherwise you may get a panic). The title may be truncated.
