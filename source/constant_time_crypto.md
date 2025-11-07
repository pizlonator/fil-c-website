# Constant-Time Crypto

Cryptographic libraries like OpenSSL are engineered to ensure that timing side channels cannot be used to extract secrets. For example, it should not be possible to guess the key used to encrypt data based on how long the encryption took. It's hard to guarantee the lack of timing side channels! The tradecraft used to maintain this guarantee is called *constant-time crypto*. Note that this does not mean that the crypto has running time that is constant in input size (encrypting a larger data set is expected to take longer and that's not a problem). It just means that time does not vary based on secrets.

Writing crypto that has the constant time property is hard because:

- Some CPU instructions will take longer for some inputs.

- Tempting optimizations that are sensible in normal code break constant time crypto (like returning `false` early from a failing string comparison).

- Compilers are not engineered to avoid transformations that would break constant time crypto.

The last problem is the trickiest. Compilers are engineered as a large combination of compiler passes that interoperate under a simple contract: the *behavior* of the code that was an input to a pass is identical to the behavior of the output code. By *behavior* we just mean what side effects the code produces and what value it returns. Timing is not part of the contract! At best, end-to-end average performance on benchmarks is part of the contract, but even that is secondary to whether the code "behaved" the same. That is to say, *it is not a bug for a compiler to transform constant-time code into variable-time code*. Simple cases where this might happen is if the compiler identifies a fast-path/slow-path opportunity in some arithmetic, and introduces a branch, not knowing that it's branching on a secret. But because of the sheer sophistication of compilers ([check out the Fil-C compiler LLVM pass pipeline](compiler.html)), proving that there does not exist a pass (or an emergent behavior between passes) that breaks constant-time crypto is impractical.

For this reason, **the safest way to write constant time crypto is to write it in assembly**.

This presents a challege for Fil-C! Fil-C currently does not have a story for making assembly memory safe. Also, Fil-C does not have a good story for linking Yolo-C libraries with Fil-C libraries. Hence, our options are:

- Compile crypto libraries like OpenSSL with assembly turned off. This is what I used to do with OpenSSL for Fil-C. Unfortunately, this is a net security regression. Although we might be fixing possible memory safety issues in assembly code, we are more likely to be introducing timing side channels that users of Yolo-OpenSSL don't have to worry about.

- **Find a way to link OpenSSL's assembly code into OpenSSL compiled with Fil-C!**

This document goes into the gory details of how I linked OpenSSL's assembly code into OpenSSL compiled with Fil-C. This required a ~90KB change to OpenSSL 3.3.1. I have confirmed that this change passes all of OpenSSL's tests. I have also confirmed that SSH, curl, and other clients of OpenSSL work fine with this change.

The discussion is organized as follows. First I introduce new Fil-C API, which gives us a minimal FFI that is just enough for calling out to assembly code that quacks according to Yolo-C ABI. Then I go through the changes to OpenSSL, file by file, and show you the full diff with explanations of every change.

## Limited FFI To Yolo-Land

OpenSSL's interop between C and assembly is confined to the following:

- C code calls assembly code. Never the other way around. Except for one case that I chose not to support, those calls are direct calls (the C code is calling a function by name, not by function pointer). Almost all of these calls involve passing pointers from C code to assembly code. The reverse almost never happens (in the one case where assembly returns a pointer, it's just offset from a pointer that was passed to assembly).

- C code and assembly code share a global variable. In the case where this happens, the global happens to be defined in assembly, but it would make not difference to have it be defined in C code.

So, I added three features to Fil-C: an unsafe call mechanism that uses Yolo-C ABI, a way to request pointer safety checks from Fil-C, and a way to share globals using Yolo-C ABI.

### Unsafe Call Using Yolo-C ABI

I introduced the following new intrinsic functions to [`<stdfil.h>`](stdfil.html).

    /* Performs an unsafe call to Yolo-land.
       
       This barely works! It's not intended for full-blown interop with Yolo code. In particular, right
       now Fil-C code expects to live in a Fil-C runtime, which precludes the use of a Yolo libc.
       
       This function is mostly useful for implementing constant-time crypto libraries or other kernels
       that need to be written in assembly.
    
       The first argument is the Yolo symbol name of the function to be called. It must be a string
       literal. The remaining arguments are passed along using Yolo C ABI conventions. */
    unsigned long zunsafe_call(const char* symbol_name, ...);
    
    /* Exactly like `zunsafe_call`, but for those cases where you know that the call will complete in a
       bounded (and sufficiently short) amount of time.
    
       In the worst case, if you call this instead of zunsafe_call, then you're just delaying GC progress.
       It's not the end of the world. Maybe we're talking about denial of service, at worst.
    
       This only turns into a big problem if you use zunsafe_fast_call to do something that has truly
       unbounded execution time (like a syscall that blocks indefinitely, or an infinite loop). Otherwise
       it's a perf pathology that you may or may not care enough to fix. */
    unsigned long zunsafe_fast_call(const char* symbol_name, ...);
    
    /* Performs either a `zunsafe_fast_call` or `zunsafe_call` depending on the `size`. */
    unsigned long zunsafe_buf_call(__SIZE_TYPE__ size, const char* symbol_name, ...);

Let's talk about `zunsafe_call` in detail first. The `symbol_name` argument is special; it must be a string constant or else the compiler will give an error (an ICE currently). Then the compiler emits a function call to `symbol_name` (without any mangling!) with the arguments passed using Yolo-C ABI (which is what OpenSSL's assembly code expects). Currently this only supports returning `unsigned long` (i.e. a 64-bit integer). Note that if the function really returns a smaller integer, then this still works, but you can't place too many expectations on the upper bits of the integer (though in practice it will be zero-extended).

There's one quirk here that requires more than just one function. The [Fil-C compiler](compiler.html) normally emits [pollchecks](safepoints.html#pollchecks) in the code it generates to allow for low-overhead synchronization with the [garbage collector](fugc.html). We can't expect the assembly code to know how to do that. So, `zunsafe_call` performs an [exit](safepoints.html#native) around the native call. This is sound, but carries significant performance downside: each exit is at least an atomic compare-and-swap, and then requires a subsequent enter, which is another atomic compare-and-swap. Currently, the Fil-C implementation of exit/enter is not optimized, so it's really a function call for exit and for enter.

Luckily, we do not need to exit/enter if the assembly code has short running time. So, this API comes with two additional functions:

- `zunsafe_fast_call`, which is just like `zunsafe_call` but does not exit or enter. The worst case of calling `zunsafe_fast_call` instead of `zunsafe_call` is that if the native function blocks, then the GC blocks, too. Then you might run out of memory.

- `zunsafe_buf_call`, which decides whether to `zunsafe_fast_call` or `zunsafe_call` based on the `size` argument. Note that this is just heuristic-based, so we don't have to trip about whether `size` should be measured in bits, bytes, words, or blocks.

### Manual Safety Checks

Anytime we use `zunsafe_call` and friends to pass pointers to assembly code, we should check that those pointers point at the kind of data that the assembly code will want to access. Writing checks by hand is never going to be as good having the compiler insert checks, but it is better than not having any checks at all.

As a foundation for manual checking, I first added API to [`<stdfil.h>`](stdfil.html) that allows a Fil-C program to trigger a Fil-C memory safety error.

    void zsafety_error(const char* str);
    void zsafety_errorf(const char* str, ...);
    
    #define ZSAFETY_CHECK(exp) do { \
            if ((exp)) \
                break; \
            zsafety_errorf("%s:%d: %s: safety check %s failed.", \
                           __FILE__, __LINE__, __PRETTY_FUNCTION__, #exp); \
        } while (0)

Then, based on this API, I added the following checking functions in [`<stdfil.h>`](stdfil.html).

    static inline void zcheck(void* ptr, __SIZE_TYPE__ size)
    {
        if (!size)
            return;
        if (!zvalinbounds(ptr, size))
            zsafety_errorf("%zu bytes are not in bounds of %P.", size, ptr);
        if (zis_readonly(ptr))
            zsafety_errorf("%P is readonly.", ptr);
    }
    
    static inline void zcheck_readonly(const void* ptr, __SIZE_TYPE__ size)
    {
        if (!size)
            return;
        if (!zvalinbounds((void*)ptr, size))
            zsafety_errorf("%zu bytes are not in bounds of %P.", size, ptr);
    }
    
    static inline __SIZE_TYPE__ zchecked_add(__SIZE_TYPE__ a, __SIZE_TYPE__ b)
    {
        __SIZE_TYPE__ result;
        if (__builtin_add_overflow(a, b, &result))
            zsafety_errorf("%zu + %zu overflowed.", a, b);
        return result;
    }
    
    static inline __SIZE_TYPE__ zchecked_mul(__SIZE_TYPE__ a, __SIZE_TYPE__ b)
    {
        __SIZE_TYPE__ result;
        if (__builtin_mul_overflow(a, b, &result))
            zsafety_errorf("%zu * %zu overflowed.", a, b);
        return result;
    }

This allows Fil-C code to easily do safety checks and have the failures reported as Fil-C memory safety errors. My changes to OpenSSL use these functions a lot.

### Sharing Globals With Yolo-Land

OpenSSL has a global variable that is shared between C and assembly for tracking the set of capabilities that the CPU has. The variable is defined in assembly, initialized in C, and read from both C and assembly.

In order for the variable to be accessible from Fil-C, it needs to have a [Fil-C capability](invisicaps.html) and it needs to be tracked by the [GC](fugc.html). So, it's most natural to define the variable in C. It's easy to change OpenSSL to define the variable in C rather than assembly.

But then we still need to have a way to expose the variable to assembly using Yolo-C ABI (i.e. via an unmangled name). Normally, Fil-C mangles all symbol names and in the case of globals, those mangled names do not point to the actual global variable the way that the symbol name would in Yolo-C ABI. So, I added a compiler directive called `.filc_unsafe_export`. Here's an example of how to use it:

    int global;
    asm(".filc_unsafe_export global");

This has no effect on how `global` appears to the Fil-C program. But it does create a Yolo-C ABI symbol called `global` that aliases the payload of the `global` variable. Assembly code that expects to access `global` can do it just as if `global` had been defined by Yolo-C.

## The OpenSSL 3.3.1 Change

Now let's go through the whole 90KB change to OpenSSL 3.3.1 to make it compile with Fil-C while leveraging assembly for much of the crypto engine implementation.

With this change, we can build OpenSSL with these settings:

    CC=<path to Fil-C clang> ./Configure zlib

The change I'm describing here landed in the following GitHub commits:

- [`9323262`](https://github.com/pizlonator/fil-c/commit/9323262508f5f03da40ca6122b1e6faa7c27e610)
- [`8f7f8cd`](https://github.com/pizlonator/fil-c/commit/8f7f8cd72fa77c33cdd803fa4b0f7210233dce9e)
- [`dfb7383`](https://github.com/pizlonator/fil-c/commit/dfb7383fe959451aa9c7a526b7ca08cb70a6e07a)
- [`76f9fca`](https://github.com/pizlonator/fil-c/commit/76f9fca0dbe3fc36eb2e24c84b0199a7d2c7ca33)

Note that the follow-on fixes are thanks to me writing this document, which forced me to review what I had done and rationalize it. One of the goals of publishing this document is the hope that others might also find more issues and [tell me about them](https://github.com/pizlonator/fil-c/issues).

### New File: `crypto/aes/aes_asm_forward.c`

This new file provides forwarding functions from Fil-C to assembly for the basic AES (Advanced Encryption Standard) implementation. Normally, if OpenSSL called `AES_set_encrypt_key` (for example), then the call would directly go to the assembly implementation of that function. But in Fil-C, such a call goes to the Fil-C ABI variant of that function, which has a different mangling and different calling convention.

So, for every function implemented in assembly, we introduce a C function of the same name that wraps a call to `zunsafe_call` or one of its variants.

    #include "internal/deprecated.h"
    
    #include <assert.h>
    
    #include <stdlib.h>
    #include <openssl/crypto.h>
    #include <openssl/aes.h>
    #include "aes_local.h"
    #include <stdfil.h>

We start by including the same headers the other AES files in OpenSSL include.

    int AES_set_encrypt_key(const unsigned char *userKey, const int bits,
                            AES_KEY *key)
    {
        zcheck_readonly(userKey, zchecked_add(bits, 7) / 8);
        zcheck(key, sizeof(AES_KEY));
        return zunsafe_buf_call(bits, "AES_set_encrypt_key", userKey, bits, key);
    }

In a perfect world, OpenSSL would validate everything about the buffers being passed to assembly. But in our changes to OpenSSL, we make no such assumptions. So, we check that the `userKey` really has the bits that are being asked for, and that the `key` is really an `AES_KEY` struct by emitting our own checks. This protects the memory safety of the process in case the `bits` object was not big enough, or if the `key` pointer was pointing at something smaller than an `AES_KEY`.

    int AES_set_decrypt_key(const unsigned char *userKey, const int bits,
                            AES_KEY *key)
    {
        zcheck_readonly(userKey, zchecked_add(bits, 7) / 8);
        zcheck(key, sizeof(AES_KEY));
        return zunsafe_buf_call(bits, "AES_set_decrypt_key", userKey, bits, key);
    }

Same as `AES_set_encrypt_key`.

    void AES_encrypt(const unsigned char *in, unsigned char *out,
                     const AES_KEY *key)
    {
        zcheck_readonly(in, 16);
        zcheck(out, 16);
        zcheck_readonly(key, sizeof(AES_KEY));
        zunsafe_fast_call("AES_encrypt", in, out, key);
    }

This encrypts a single block, which is 16 bytes (128 bits). It's common practice in OpenSSL to use magical constants for cases where it's standardizes (the AES standard fixes the block size at 128 bits/16 bytes). We use `zunsafe_fast_call` because this is a constant-time operation.

    void AES_decrypt(const unsigned char *in, unsigned char *out,
                     const AES_KEY *key)
    {
        zcheck_readonly(in, 16);
        zcheck(out, 16);
        zcheck_readonly(key, sizeof(AES_KEY));
        zunsafe_fast_call("AES_decrypt", in, out, key);
    }

Same as `AES_encrypt`.

    void AES_cbc_encrypt(const unsigned char *in, unsigned char *out,
                         size_t length, const AES_KEY *key,
                         unsigned char *ivp, const int enc)
    {
        zcheck_readonly(in, length);
        zcheck(out, length);
        zcheck_readonly(key, sizeof(AES_KEY));
        zcheck(ivp, 16);
        zunsafe_buf_call(length, "AES_cbc_encrypt", in, out, length, key, ivp, enc);
    }

This implements the cipher block chaining (CBC) mode for AES. Here, an initial block is given (the intial block for CBC is called the IV or ivec, here it's in the `ivp` variable) and must be 16 bytes (the AES block size). The input/output must have `length` bytes.

### New File: `crypto/aes/aes_asm_forward.c`

This file provides forwarding functions to the assembly implementation of AES using the Intel AES-NI extension.

    #include "internal/deprecated.h"
    
    #include <assert.h>
    
    #include <stdlib.h>
    #include <openssl/crypto.h>
    #include <openssl/aes.h>
    #include "crypto/modes.h"
    #include "crypto/aes_platform.h"
    #include <stdfil.h>

First we include the headers that other AES files include.

    int aesni_set_encrypt_key(const unsigned char *userKey, int bits,
                              AES_KEY *key)
    {
        zcheck_readonly(userKey, zchecked_add(bits, 7) / 8);
        zcheck(key, sizeof(AES_KEY));
        return zunsafe_buf_call(bits, "aesni_set_encrypt_key", userKey, bits, key);
    }

Just like `AES_set_encrypt_key`, this takes a user key whose length is specified by `bits` and converts it to the internal `AES_KEY` struct.

    int aesni_set_decrypt_key(const unsigned char *userKey, int bits,
                              AES_KEY *key)
    {
        zcheck_readonly(userKey, zchecked_add(bits, 7) / 8);
        zcheck(key, sizeof(AES_KEY));
        return zunsafe_buf_call(bits, "aesni_set_decrypt_key", userKey, bits, key);
    }

Same as `AES_set_encrypt_key` but for decryption.

    void aesni_encrypt(const unsigned char *in, unsigned char *out,
                       const AES_KEY *key)
    {
        zcheck_readonly(in, 16);
        zcheck(out, 16);
        zcheck_readonly(key, sizeof(AES_KEY));
        zunsafe_fast_call("aesni_encrypt", in, out, key);
    }

This does one block (16 bytes) of AES encryption.

    void aesni_decrypt(const unsigned char *in, unsigned char *out,
                       const AES_KEY *key)
    {
        zcheck_readonly(in, 16);
        zcheck(out, 16);
        zcheck_readonly(key, sizeof(AES_KEY));
        zunsafe_fast_call("aesni_decrypt", in, out, key);
    }

This does one block (16 bytes) of AES decryption.

    void aesni_ecb_encrypt(const unsigned char *in,
                           unsigned char *out,
                           size_t length, const AES_KEY *key, int enc)
    {
        zcheck_readonly(in, length);
        zcheck(out, length);
        zcheck_readonly(key, sizeof(AES_KEY));
        zunsafe_buf_call(length, "aesni_ecb_encrypt", in, out, length, key, enc);
    }

This does `length` bytes of AES ECB encryption or decryption (based on the value of `enc`).

    void aesni_cbc_encrypt(const unsigned char *in,
                           unsigned char *out,
                           size_t length,
                           const AES_KEY *key, unsigned char *ivec, int enc)
    {
        zcheck_readonly(in, length);
        zcheck(out, length);
        zcheck_readonly(key, sizeof(AES_KEY));
        zcheck(ivec, 16);
        zunsafe_buf_call(length, "aesni_cbc_encrypt", in, out, length, key, ivec, enc);
    }

This does `length` bytes of AES CBC encryption or decryption (based on the value of `enc`). Since it's CBC mode, an initial block is required (the `ivec`, which points at 16 bytes).

    #  ifndef OPENSSL_NO_OCB

The AES-NI implementation comes with offset codebook mode (OCB). This mode is enabled in the default build (i.e. `OPENSSL_NO_OCB` is not set).

    static size_t l_size(size_t blocks, size_t start_block_num)
    {
        size_t blocks_processed = start_block_num - 1;
        size_t all_num_blocks = zchecked_add(blocks, blocks_processed);
        size_t result = 0;
        while (all_num_blocks >>= 1)
            result = zchecked_add(result, 1);
        return result;
    }

OCB mode involves a lookup table whose size is logarithmic in the number of blocks previously processed (i.e. `blocks_processed` and the number of new blocks (i.e. `blocks`). This helper computes the expected size of that lookup table.

    void aesni_ocb_encrypt(const unsigned char *in, unsigned char *out,
                           size_t blocks, const void *key,
                           size_t start_block_num,
                           unsigned char offset_i[16],
                           const unsigned char L_[][16],
                           unsigned char checksum[16])
    {
        zcheck_readonly(in, zchecked_mul(blocks, 16));
        zcheck(out, zchecked_mul(blocks, 16));
        zcheck_readonly(key, sizeof(AES_KEY));
        zcheck(offset_i, 16);
        zcheck_readonly(L_, zchecked_mul(16, l_size(blocks, start_block_num)));
        zcheck(checksum, 16);
        zunsafe_buf_call(blocks, "aesni_ocb_encrypt", in, out, blocks, key, start_block_num, offset_i, L_, checksum);
    }

This function implements OCB encryption. `blocks` tells us the number of blocks in `in` and `out`. Blocks are 16 bytes like in any other AES mode. `start_block_num` affects the required size of the lookup table (see `l_size` above).

Note that I'm using `zchecked_mul` to find out the byte size to check. This protects the safety checks from integer overflow attacks.

    void aesni_ocb_decrypt(const unsigned char *in, unsigned char *out,
                           size_t blocks, const void *key,
                           size_t start_block_num,
                           unsigned char offset_i[16],
                           const unsigned char L_[][16],
                           unsigned char checksum[16])
    {
        zcheck_readonly(in, zchecked_mul(blocks, 16));
        zcheck(out, zchecked_mul(blocks, 16));
        zcheck_readonly(key, sizeof(AES_KEY));
        zcheck(offset_i, 16);
        zcheck_readonly(L_, zchecked_mul(16, l_size(blocks, start_block_num)));
        zcheck(checksum, 16);
        zunsafe_buf_call(blocks, "aesni_ocb_decrypt", in, out, blocks, key, start_block_num, offset_i, L_, checksum);
    }

Same as `aesni_ocb_encrypt` but for decryption.

    #  endif /* OPENSSL_NO_OCB */
    
    void aesni_ctr32_encrypt_blocks(const unsigned char *in,
                                    unsigned char *out,
                                    size_t blocks,
                                    const void *key, const unsigned char *ivec)
    {
        zcheck_readonly(in, zchecked_mul(blocks, 16));
        zcheck(out, zchecked_mul(blocks, 16));
        zcheck_readonly(key, sizeof(AES_KEY));
        zcheck_readonly(ivec, 16);
        zunsafe_buf_call(blocks, "aesni_ctr32_encrypt_blocks", in, out, blocks, key, ivec);
    }

This runs CTR (counter) encryption (and decryption, if I understand it correctly). As with the other AES modes, the block size is 16 bytes. Like CBC mode, this requires an initial block (the `ivec`).

    void aesni_xts_encrypt(const unsigned char *in,
                           unsigned char *out,
                           size_t length,
                           const AES_KEY *key1, const AES_KEY *key2,
                           const unsigned char iv[16])
    {
        zcheck_readonly(in, length);
        zcheck(out, length);
        zcheck_readonly(key1, sizeof(AES_KEY));
        zcheck_readonly(key2, sizeof(AES_KEY));
        zcheck_readonly(iv, 16);
        zunsafe_buf_call(length, "aesni_xts_encrypt", in, out, length, key1, key2, iv);
    }

This implements a disk encryption scheme called XTS, which involves encrypting the `iv` with a different key than what is used for encrypting subsequent blocks. From a safety checking standpoint, this is like CBC but with two keys.

    void aesni_xts_decrypt(const unsigned char *in,
                           unsigned char *out,
                           size_t length,
                           const AES_KEY *key1, const AES_KEY *key2,
                           const unsigned char iv[16])
    {
        zcheck_readonly(in, length);
        zcheck(out, length);
        zcheck_readonly(key1, sizeof(AES_KEY));
        zcheck_readonly(key2, sizeof(AES_KEY));
        zcheck_readonly(iv, 16);
        zunsafe_buf_call(length, "aesni_xts_decrypt", in, out, length, key1, key2, iv);
    }

Same as `aesni_xts_encrypt` but for decryption.

    void aesni_ccm64_encrypt_blocks(const unsigned char *in,
                                    unsigned char *out,
                                    size_t blocks,
                                    const void *key,
                                    const unsigned char ivec[16],
                                    unsigned char cmac[16])
    {
        zcheck_readonly(in, zchecked_mul(blocks, 16));
        zcheck(out, zchecked_mul(blocks, 16));
        zcheck_readonly(key, sizeof(AES_KEY));
        zcheck_readonly(ivec, 16);
        zcheck(cmac, 16);
        zunsafe_buf_call(blocks, "aesni_ccm64_encrypt_blocks", in, out, blocks, key, ivec, cmac);
    }

This does a combination of CTR encryption and CBC-MAC authentication. The `ivec` is used to kick-start encryption and the MAC is returneed in `cmac`.

    void aesni_ccm64_decrypt_blocks(const unsigned char *in,
                                    unsigned char *out,
                                    size_t blocks,
                                    const void *key,
                                    const unsigned char ivec[16],
                                    unsigned char cmac[16])
    {
        zcheck_readonly(in, zchecked_mul(blocks, 16));
        zcheck(out, zchecked_mul(blocks, 16));
        zcheck_readonly(key, sizeof(AES_KEY));
        zcheck_readonly(ivec, 16);
        zcheck(cmac, 16);
        zunsafe_buf_call(blocks, "aesni_ccm64_decrypt_blocks", in, out, blocks, key, ivec, cmac);
    }

Like `aesni_ccm64_encrypt_block` but for decryption.

### New File: `crypto/aes/aesni_mb_asm_forward.c`

This file provides a forwarding function for multi-buffer encryption. The idea is to produce a speed-up when encrypting by interleaving independent instructions for the encryption of multiple buffers.

    #include "internal/deprecated.h"
    
    #include <assert.h>
    
    #include <stdlib.h>
    #include <openssl/crypto.h>
    #include <openssl/aes.h>
    #include "crypto/modes.h"
    #include "crypto/aes_platform.h"
    #include <stdfil.h>
    
    typedef struct {
        const unsigned char *inp;
        unsigned char *out;
        int blocks;
        u64 iv[2];
    } CIPH_DESC;
    
    void aesni_multi_cbc_encrypt(CIPH_DESC *desc, void *key, int n4x)
    {
        ZSAFETY_CHECK(n4x == 1 || n4x == 2);
        unsigned n = n4x * 4;
        zcheck(desc, zchecked_mul(sizeof(CIPH_DESC), n));
        unsigned i;
        unsigned total = 0;
        for (i = n; i--;) {
            zcheck_readonly(desc[i].inp, zchecked_mul(desc[i].blocks, 16));
            zcheck(desc[i].out, zchecked_mul(desc[i].blocks, 16));
            total += zchecked_mul(desc[i].blocks, 16);
        }
        zcheck(key, sizeof(AES_KEY));
        zunsafe_buf_call(total, "aesni_multi_cbc_encrypt", desc, key, n4x);
    }

This encryption mode only works for 4 or 8 buffers. This is specified by the `n4x` argument, which is either 1 (indicating 4 buffers) or 2 (indicating 8 buffers).

This function would be arguably safer if we passed a copy of `desc` to assembly, since that would avoid time-of-check-to-time-of-use vulnerabilities. However, the `desc` is always stack-allocated and local to the caller, so the additional protection of making a copy would be overkill.

### New File: `crypto/aes/aesni_sha1_asm_forward.c`

OpenSSL contains multiple "stitched" crypto implementations where two different things (in this case AES CBC encryption and SHA1 encoding) are done in tandem to maximize instruction level parallelism.

    #include "internal/deprecated.h"
    
    #include <assert.h>
    
    #include <stdlib.h>
    #include <openssl/crypto.h>
    #include <openssl/aes.h>
    #include <openssl/sha.h>
    #include "crypto/modes.h"
    #include "crypto/aes_platform.h"
    #include <stdfil.h>
    
    void aesni_cbc_sha1_enc(const void *inp, void *out, size_t blocks,
                            const AES_KEY *key, unsigned char iv[16],
                            SHA_CTX *ctx, const void *in0)
    {
        zcheck_readonly(inp, zchecked_mul(blocks, 64));
        zcheck(out, zchecked_mul(blocks, 64));
        zcheck_readonly(key, sizeof(AES_KEY));
        zcheck(iv, 16);
        zcheck(ctx, sizeof(SHA_CTX));
        zcheck_readonly(in0, zchecked_mul(blocks, 64));
        zunsafe_call("aesni_cbc_sha1_enc", inp, out, blocks, key, iv, ctx, in0);
    }

This is a tricky function that I initially got subtly wrong. Although AES uses 16 byte blocks, the `blocks` argument is in units of 64 bytes, since that is the SHA1 block size. I confirmed that multiplying by anything larger than 64 results in the OpenSSL test suite failing, and I double-checked the assembly code (which shifts the `blocks` argument by 6, indicating a multiplication by 64).

    /* The stitched decrypt thing seems to be implemented by disabled. */
    #if 0
    void aesni256_cbc_sha1_dec(const void *inp, void *out, size_t blocks,
                               const AES_KEY *key, unsigned char iv[16],
                               SHA_CTX *ctx, const void *in0)
    {
        zcheck_readonly(inp, zchecked_mul(blocks, 64));
        zcheck(out, zchecked_mul(blocks, 64));
        zcheck_readonly(key, sizeof(AES_KEY));
        zcheck(iv, 16);
        zcheck(ctx, sizeof(SHA_CTX));
        zcheck_readonly(in0, zchecked_mul(blocks, 64));
        zunsafe_call("aesni256_cbc_sha1_dec", inp, out, blocks, key, iv, ctx, in0);
    }
    #endif

OpenSSL contains an implementation of the stiched decryption, but disables it.

### New File: `crypto/aes/aesni_sha256_asm_forward.c`

This is AES CBC stitched with SHA256.

    #include "internal/deprecated.h"
    
    #include <assert.h>
    
    #include <stdlib.h>
    #include <openssl/crypto.h>
    #include <openssl/aes.h>
    #include <openssl/sha.h>
    #include "crypto/modes.h"
    #include "crypto/aes_platform.h"
    #include <stdfil.h>
    
    int aesni_cbc_sha256_enc(const void *inp, void *out, size_t blocks,
                             const AES_KEY *key, unsigned char iv[16],
                             SHA256_CTX *ctx, const void *in0)
    {
        zcheck_readonly(inp, zchecked_mul(blocks, 64));
        zcheck(out, zchecked_mul(blocks, 64));
        if (key)
            zcheck_readonly(key, sizeof(AES_KEY));
        if (iv)
            zcheck(iv, 16);
        if (ctx)
            zcheck(ctx, sizeof(SHA_CTX));
        zcheck_readonly(in0, zchecked_mul(blocks, 64));
        return zunsafe_call("aesni_cbc_sha256_enc", inp, out, blocks, key, iv, ctx, in0);
    }

As with the AES-SHA1 stitching, I originally made the mistake of assuming that `blocks` was referring to AES blocks, i.e. 16 bytes. It's not - this uses SHA256 blocks, which are 64 bytes, even when measuring the size of the AES input/output.

Also, this function is called with all-`NULL` arguments because it returns whether or not the implementation is available. So, I have guarded the checks to work fine for NULL inputs.

### New File: `crypto/aes/bsaes_asm_forward.c`

This is the "bitsliced" AES implementation for CPUs that don't support the Intel AES-NI instructions.

    #include "internal/deprecated.h"
    
    #include <assert.h>
    
    #include <stdlib.h>
    #include <openssl/crypto.h>
    #include <openssl/aes.h>
    #include "crypto/modes.h"
    #include "crypto/aes_platform.h"
    #include <stdfil.h>
    
    void ossl_bsaes_cbc_encrypt(const unsigned char *in, unsigned char *out,
                                size_t length, const AES_KEY *key,
                                unsigned char ivec[16], int enc)
    {
        zcheck_readonly(in, length);
        zcheck(out, length);
        zcheck_readonly(key, sizeof(AES_KEY));
        zcheck(ivec, 16);
        zunsafe_buf_call(length, "ossl_bsaes_cbc_encrypt", in, out, length, key, ivec, enc);
    }

This provides the CBC encryption/decryption mode, so it requires a 16 byte (one block) `ivec`. All other sizes are measured in bytes.

    void ossl_bsaes_ctr32_encrypt_blocks(const unsigned char *in,
                                         unsigned char *out, size_t len,
                                         const AES_KEY *key,
                                         const unsigned char ivec[16])
    {
        zcheck_readonly(in, zchecked_mul(len, 16));
        zcheck(out, zchecked_mul(len, 16));
        zcheck_readonly(key, sizeof(AES_KEY));
        zcheck_readonly(ivec, 16);
        zunsafe_buf_call(len, "ossl_bsaes_ctr32_encrypt_blocks", in, out, len, key, ivec);
    }

This provides the CTR (counter) encryption/decryption mode. Similarly to CBC, it requires a 16 byte initial block. Unlike CBC, the `len` argument is in blocks, so it needs to be multiplied by 16. I got this wrong in my initial implementation!

    void ossl_bsaes_xts_encrypt(const unsigned char *inp, unsigned char *out,
                                size_t len, const AES_KEY *key1,
                                const AES_KEY *key2, const unsigned char iv[16])
    {
        zcheck_readonly(inp, len);
        zcheck(out, len);
        zcheck_readonly(key1, sizeof(AES_KEY));
        zcheck_readonly(key2, sizeof(AES_KEY));
        zcheck_readonly(iv, 16);
        zunsafe_buf_call(len, "ossl_bsaes_xts_encrypt", inp, out, len, key1, key2, iv);
    }

This implements the XTS disk encryption scheme, which requires two keys, but is otherwise similar to CBC (length is measured in bytes, requires a 16-byte `iv`).

    void ossl_bsaes_xts_decrypt(const unsigned char *inp, unsigned char *out,
                                size_t len, const AES_KEY *key1,
                                const AES_KEY *key2, const unsigned char iv[16])
    {
        zcheck_readonly(inp, len);
        zcheck(out, len);
        zcheck_readonly(key1, sizeof(AES_KEY));
        zcheck_readonly(key2, sizeof(AES_KEY));
        zcheck_readonly(iv, 16);
        zunsafe_buf_call(len, "ossl_bsaes_xts_decrypt", inp, out, len, key1, key2, iv);
    }

Like `ossl_bsaes_xts_encrypt`, but for decryption.

### Changes To `crypto/aes/build.info`

    @@ -8,8 +8,11 @@ IF[{- !$disabled{asm} -}]
       $AESDEF_x86_sse2=VPAES_ASM OPENSSL_IA32_SSE2
     
       $AESASM_x86_64=\
    -        aes-x86_64.s vpaes-x86_64.s bsaes-x86_64.s aesni-x86_64.s \
    -        aesni-sha1-x86_64.s aesni-sha256-x86_64.s aesni-mb-x86_64.s
    +        aes_asm_forward.c aes-x86_64.s vpaes_asm_forward.c vpaes-x86_64.s \
    +        bsaes_asm_forward.c bsaes-x86_64.s aesni_asm_forward.c aesni-x86_64.s \
    +        aesni_sha1_asm_forward.c aesni-sha1-x86_64.s \
    +        aesni_sha256_asm_forward.c aesni-sha256-x86_64.s \
    +        aesni_mb_asm_forward.c aesni-mb-x86_64.s
       $AESDEF_x86_64=AES_ASM VPAES_ASM BSAES_ASM
     
       $AESASM_ia64=aes_core.c aes_cbc.c aes-ia64.s

OpenSSL uses its own kind of build system where `builf.info` files do some logic to select what is included in the build. Normally when OpenSSL builds on X86\_64 with assembly enabled, it just includes a bunch of `.s` files. But since we have to provide Fil-C forwarding functions, and we have those in their own files, we need to add those files to the build also.

### New File: `crypto/aes/vpaes_asm_forward.c`

OpenSSL also includes a Vector Permutation constant-time AES implementation called `vpaes`.

    #include "internal/deprecated.h"
    
    #include <assert.h>
    
    #include <stdlib.h>
    #include <openssl/crypto.h>
    #include <openssl/aes.h>
    #include "crypto/modes.h"
    #include "crypto/aes_platform.h"
    #include <stdfil.h>
    
    int vpaes_set_encrypt_key(const unsigned char *userKey, const int bits,
                              AES_KEY *key)
    {
        zcheck_readonly(userKey, zchecked_add(bits, 7) / 8);
        zcheck(key, sizeof(AES_KEY));
        return zunsafe_buf_call(bits, "vpaes_set_encrypt_key", userKey, bits, key);
    }

This is the key initialization function for encryption. As before, this measures the key size in bits.

    int vpaes_set_decrypt_key(const unsigned char *userKey, const int bits,
                              AES_KEY *key)
    {
        zcheck_readonly(userKey, zchecked_add(bits, 7) / 8);
        zcheck(key, sizeof(AES_KEY));
        return zunsafe_buf_call(bits, "vpaes_set_decrypt_key", userKey, bits, key);
    }

Same as `vpaes_set_encrypt_key` but for decryption.

    void vpaes_encrypt(const unsigned char *in, unsigned char *out,
                       const AES_KEY *key)
    {
        zcheck_readonly(in, 16);
        zcheck(out, 16);
        zcheck_readonly(key, sizeof(AES_KEY));
        zunsafe_fast_call("vpaes_encrypt", in, out, key);
    }

This encrypts a single block (16 bytes).

    void vpaes_decrypt(const unsigned char *in, unsigned char *out,
                       const AES_KEY *key)
    {
        zcheck_readonly(in, 16);
        zcheck(out, 16);
        zcheck_readonly(key, sizeof(AES_KEY));
        zunsafe_fast_call("vpaes_decrypt", in, out, key);
    }

This decrypts a single block (16 bytes).

    void vpaes_cbc_encrypt(const unsigned char *in, unsigned char *out,
                           size_t length, const AES_KEY *key,
                           unsigned char *ivp, const int enc)
    {
        zcheck_readonly(in, length);
        zcheck(out, length);
        zcheck_readonly(key, sizeof(AES_KEY));
        zcheck(ivp, 16);
        zunsafe_buf_call(length, "vpaes_cbc_encrypt", in, out, length, key, ivp, enc);
    }

This is the CBC encryption function, so it has a `length` in bytes and requires a 16 byte initial block (`ivp`).

### Changes To `crypto/bn/bn_asm.c`

`bn` stands for big number, and is used for RSA.

    @@ -11,6 +11,7 @@
     #include <openssl/crypto.h>
     #include "internal/cryptlib.h"
     #include "bn_local.h"
    +#include <stdfil.h>
     
     #if defined(BN_LLONG) || defined(BN_UMULT_HIGH)
     
    @@ -1040,3 +1041,16 @@ int bn_mul_mont(BN_ULONG *rp, const BN_ULONG *ap, const BN_ULONG *bp,
     # endif
     
     #endif                          /* !BN_MUL_COMBA */
    +
    +#ifndef OPENSSL_NO_ASM
    +int bn_mul_mont(BN_ULONG *rp, const BN_ULONG *ap, const BN_ULONG *bp,
    +                const BN_ULONG *np, const BN_ULONG *n0, int num)
    +{
    +    zcheck(rp, zchecked_mul(num, sizeof(BN_ULONG)));
    +    zcheck_readonly(ap, zchecked_mul(num, sizeof(BN_ULONG)));
    +    zcheck_readonly(bp, zchecked_mul(num, sizeof(BN_ULONG)));
    +    zcheck_readonly(np, zchecked_mul(num, sizeof(BN_ULONG)));
    +    zcheck_readonly(n0, sizeof(BN_ULONG));
    +    return zunsafe_buf_call(num, "bn_mul_mont", rp, ap, bp, np, n0, num);
    +}
    +#endif

One of the toughest parts of big numbers is *montgomery multiplication*, and as far as I can tell, you need that to be written in assembly to avoid timing side channels. This provides the forwarding function to the assembly routine for montgomery multiplication.

### Changes To `crypto/bn/bn_div.c`

    @@ -159,7 +159,7 @@ static int bn_left_align(BIGNUM *num)
     }
     
     # if !defined(OPENSSL_NO_ASM) && !defined(OPENSSL_NO_INLINE_ASM) \
    -    && !defined(PEDANTIC) && !defined(BN_DIV3W)
    +    && !defined(PEDANTIC) && !defined(BN_DIV3W) && !defined(__FILC__)
     #  if defined(__GNUC__) && __GNUC__>=2
     #   if defined(__i386) || defined (__i386__)
        /*-

This disables an X86-specific optimization using inline assembly that relies on the fact that the X86 `div` instruction returns both the quotient and remainder.

Fil-C only supports trivial inline assembly where the instruction sequence is blank. This kind of "assembly" is used to inhibit compiler optimizations. In the future, Fil-C will support inline assembly with simple instructions (like `div`), but today that does not work. Based on reading this code, I believe that the inline assembly is only there as an optimization rather than the ensure constant time execution, so it's safe to just disable it.

### Changes To `crypto/bn/build.info`

    @@ -22,15 +22,18 @@ IF[{- !$disabled{asm} -}]
       $BNDEF_x86=OPENSSL_BN_ASM_PART_WORDS OPENSSL_BN_ASM_MONT OPENSSL_BN_ASM_GF2m
       $BNDEF_x86_sse2=OPENSSL_IA32_SSE2
     
    -  $BNASM_x86_64=\
    -          x86_64-mont.s x86_64-mont5.s x86_64-gf2m.s rsaz_exp.c rsaz-x86_64.s \
    -          rsaz-avx2.s rsaz_exp_x2.c rsaz-2k-avx512.s rsaz-3k-avx512.s rsaz-4k-avx512.s
    -  IF[{- $config{target} !~ /^VC/ -}]
    -    $BNASM_x86_64=asm/x86_64-gcc.c $BNASM_x86_64
    -  ELSE
    -    $BNASM_x86_64=bn_asm.c $BNASM_x86_64
    -  ENDIF
    -  $BNDEF_x86_64=OPENSSL_BN_ASM_MONT OPENSSL_BN_ASM_MONT5 OPENSSL_BN_ASM_GF2m
    +  # Only enable the bare minimum of assembly support needed to get to constant time crypto.
    +  $BNASM_x86_64=bn_asm.c x86_64-mont.s x86_64-mont5.s
    +  $BNDEF_x86_64=OPENSSL_BN_ASM_MONT
    +  # $BNASM_x86_64=\
    +  #         x86_64-mont.s x86_64-mont5.s x86_64-gf2m.s rsaz_exp.c rsaz-x86_64.s \
    +  #         rsaz-avx2.s rsaz_exp_x2.c rsaz-2k-avx512.s rsaz-3k-avx512.s rsaz-4k-avx512.s
    +  # IF[{- $config{target} !~ /^VC/ -}]
    +  #   $BNASM_x86_64=asm/x86_64-gcc.c $BNASM_x86_64
    +  # ELSE
    +  #   $BNASM_x86_64=bn_asm.c $BNASM_x86_64
    +  # ENDIF
    +  # $BNDEF_x86_64=OPENSSL_BN_ASM_MONT OPENSSL_BN_ASM_MONT5 OPENSSL_BN_ASM_GF2m
       $BNDEF_x86_64_sse2=OPENSSL_IA32_SSE2
     
       IF[{- $config{target} !~ /^VC/ -}]

The big number implementation for X86\_64 contains a lot of extra stuff, which all looks like optimizations for CPUs that have more advanced features. Because I wanted to keep the first pass at this simple, I only enabled the assembly paths that I believed are necessary to have constant time crypto. This means just the montgomery multiplication. Because `x86_64-mont.s` uses a function defined in `x86_64-mont5.s`, I also include that file. However, I don't provide wrappers for mont5, so I pretend that mont5 is disabled (`OPENSSL_BN_ASM_MONT5` is excluded from `$BNDEF_x86_64`).

### Changes To `crypto/bn/rsaz_exp.h`

    @@ -16,7 +16,9 @@
     # define OSSL_CRYPTO_BN_RSAZ_EXP_H
     
     # undef RSAZ_ENABLED
    -# if defined(OPENSSL_BN_ASM_MONT) && \
    +/* FIXME: No reason why we can't enable these for Fil-C at some point. My understanding is that these
    +   code paths are just an optimization and they're not meant to be anything but that. */
    +# if !defined(__FILC__) && defined(OPENSSL_BN_ASM_MONT) &&  \
             (defined(__x86_64) || defined(__x86_64__) || \
              defined(_M_AMD64) || defined(_M_X64))
     #  define RSAZ_ENABLED

Because I excluded the `rsaz` x86-specific assembly files, I have to disable these code paths as well.

### Changes To `crypto/camellia/build.info`

The Camellia cipher was developed by Mitsubishi Electric and NTT, Inc. Similarly to AES, OpenSSL has assembly implementations of Camellia, though the Camellia ones aren't quite as extensive (there is only one variant for X86\_64).

    @@ -3,7 +3,7 @@ LIBS=../../libcrypto
     $CMLLASM=camellia.c cmll_misc.c cmll_cbc.c
     IF[{- !$disabled{asm} -}]
       $CMLLASM_x86=cmll-x86.S
    -  $CMLLASM_x86_64=cmll-x86_64.s cmll_misc.c
    +  $CMLLASM_x86_64=camellia_asm_forward.c cmll-x86_64.s cmll_misc.c
       $CMLLASM_sparcv9=camellia.c cmll_misc.c cmll_cbc.c cmllt4-sparcv9.S
     
       # Now that we have defined all the arch specific variables, use the

Similarly to how we have `.c` files for forwarding functions for AES, we have a `camellia_asm_forward.c` for forwarding functions for Camellia.

### New File: `crypto/camellia/camellia_asm_forward.c`

    #include "internal/deprecated.h"
    
    #include <openssl/camellia.h>
    #include "cmll_local.h"
    #include <string.h>
    #include <stdlib.h>
    
    #include <stdfil.h>
    
    int Camellia_Ekeygen(int keyBitLength, const u8* rawKey, KEY_TABLE_TYPE k)
    {
        ZSAFETY_CHECK(keyBitLength == 128 || keyBitLength == 192 || keyBitLength == 256);
        zcheck_readonly(rawKey, (keyBitLength + 7) / 8);
        zcheck(k, sizeof(KEY_TABLE_TYPE));
        return zunsafe_fast_call("Camellia_Ekeygen", keyBitLength, rawKey, k);
    }

This runs the Camellia key generation. Callers already guarantee that `keyBitLength` has to be 128, 192, or 256, but I assert this because I am that paranoid.

    void Camellia_EncryptBlock_Rounds(int grandRounds, const u8 plaintext[],
                                      const KEY_TABLE_TYPE keyTable,
                                      u8 ciphertext[])
    {
        zcheck_readonly(plaintext, 16);
        zcheck_readonly(keyTable, sizeof(KEY_TABLE_TYPE));
        zcheck(ciphertext, 16);
        zunsafe_fast_call("Camellia_EncryptBlock_Rounds", grandRounds, plaintext, keyTable, ciphertext);
    }

This does one block of encryption. Like AES, Camellia uses 128 bit (16 byte) blocks. The `grandRounds` is determined by the key length.

    void Camellia_EncryptBlock(int keyBitLength, const u8 plaintext[],
                               const KEY_TABLE_TYPE keyTable, u8 ciphertext[])
    {
        ZSAFETY_CHECK(keyBitLength == 128 || keyBitLength == 192 || keyBitLength == 256);
        zcheck_readonly(plaintext, 16);
        zcheck_readonly(keyTable, sizeof(KEY_TABLE_TYPE));
        zcheck(ciphertext, 16);
        zunsafe_fast_call("Camellia_EncryptBlock", keyBitLength, plaintext, keyTable, ciphertext);
    }

This does one block of encryption, but takes the key length, rather than rounds, as an argument.

    void Camellia_DecryptBlock_Rounds(int grandRounds, const u8 ciphertext[],
                                      const KEY_TABLE_TYPE keyTable,
                                      u8 plaintext[])
    {
        zcheck_readonly(ciphertext, 16);
        zcheck_readonly(keyTable, sizeof(KEY_TABLE_TYPE));
        zcheck(plaintext, 16);
        zunsafe_fast_call("Camellia_DecryptBlock_Rounds", grandRounds, ciphertext, keyTable, plaintext);
    }

Like `Camellia_EncryptBlock_Rounds`, but for decryption.

    void Camellia_DecryptBlock(int keyBitLength, const u8 ciphertext[],
                               const KEY_TABLE_TYPE keyTable, u8 plaintext[])
    {
        ZSAFETY_CHECK(keyBitLength == 128 || keyBitLength == 192 || keyBitLength == 256);
        zcheck_readonly(ciphertext, 16);
        zcheck_readonly(keyTable, sizeof(KEY_TABLE_TYPE));
        zcheck(plaintext, 16);
        zunsafe_fast_call("Camellia_DecryptBlock", keyBitLength, ciphertext, keyTable, plaintext);
    }

Like `Camellia_EncryptBlock`, but for decryption.

    void Camellia_cbc_encrypt(const unsigned char *in, unsigned char *out,
                              size_t len, const CAMELLIA_KEY *key,
                              unsigned char *ivec, const int enc)
    {
        zcheck_readonly(in, len);
        zcheck(out, len);
        zcheck_readonly(key, sizeof(CAMELLIA_KEY));
        zcheck(ivec, 16);
        zunsafe_buf_call(len, "Camellia_cbc_encrypt", in, out, len, key, ivec, enc);
    }

This is the CBC mode of Camellia, so `len` is in bytes, and `ivec` has the initial 16 byte block.

### Changes To `crypto/chacha/build.info`

OpenSSL includes assembly implementations of the ChaCha20 stream cipher. They are exposed as one function, that internally selects between SSE, SSE3, AVX512F, and AVX512VL variants. As with AES and Camellia, I introduce a new file for the forwarding function from Fil-C to assembly.

    @@ -3,7 +3,7 @@ LIBS=../../libcrypto
     $CHACHAASM=chacha_enc.c
     IF[{- !$disabled{asm} -}]
       $CHACHAASM_x86=chacha-x86.S
    -  $CHACHAASM_x86_64=chacha-x86_64.s
    +  $CHACHAASM_x86_64=chacha_asm_forward.c chacha-x86_64.s
     
       $CHACHAASM_ia64=chacha-ia64.s
 
### New File: `crypto/chacha/chacha_asm_forward.c`

    +#include <string.h>
    +
    +#include "internal/endian.h"
    +#include "crypto/chacha.h"
    +#include "crypto/ctype.h"
    +#include <stdfil.h>
    +
    +void ChaCha20_ctr32(unsigned char *out, const unsigned char *inp, size_t len,
    +                    const unsigned int key[8], const unsigned int counter[4])
    +{
    +    zcheck(out, len);
    +    zcheck_readonly(inp, len);
    +    zcheck_readonly(key, 8 * sizeof(unsigned int));
    +    zcheck_readonly(counter, 4 * sizeof(unsigned int));
    +    zunsafe_buf_call(len, "ChaCha20_ctr32", out, inp, len, key, counter);
    +}

Because ChaCha20 is a stream cipher, it only exposes a single function for both encryption and decryption. Unlike the `ctr32` functions AES, this function uses `len` to mean bytes, not blocks.

### Changes To `crypto/cpuid.c`

The OpenSSL `cpuid` module includes both CPU capability detection and miscellaneous functions implemented in assembly that don't fit cleanly into any other module.

    @@ -9,6 +9,7 @@
     
     #include "internal/e_os.h"
     #include "crypto/cryptlib.h"
    +#include <stdfil.h>
     
     #if     defined(__i386)   || defined(__i386__)   || defined(_M_IX86) || \
             defined(__x86_64) || defined(__x86_64__) || \

We need the `<stdfil.h>` header for things like `zunsafe_fast_call`.

    @@ -92,10 +93,18 @@ static variant_char *ossl_strchr(const variant_char *str, char srch)
     #  define OPENSSL_CPUID_SETUP
     typedef uint64_t IA32CAP;
     
    +unsigned int OPENSSL_ia32cap_P[4];
    +asm(".filc_unsafe_export OPENSSL_ia32cap_P");
    +
    +static IA32CAP OPENSSL_ia32_cpuid(unsigned int *ptr)
    +{
    +    zcheck(ptr, sizeof(unsigned int) * 4);
    +    return zunsafe_fast_call("OPENSSL_ia32_cpuid", ptr);
    +}
    +
     void OPENSSL_cpuid_setup(void)
     {
         static int trigger = 0;
    -    IA32CAP OPENSSL_ia32_cpuid(unsigned int *);
         IA32CAP vec;
         const variant_char *env;

Normally, OpenSSL defines `OPENSSL_ia32cap_P` in assembly and then imports it in C code. But the Fil-C mechanism for sharing a global between C and assembly requires the global to be defined in Fil-C and then exported using `.filc_unsafe_export`, so that's what this does.

Additionally, this part of the patch provides a wrapper for the `OPENSSL_ia32_cpuid` assembly function, which days a 4-integer vector corresponding to the 4 arguments to the `cpuid` instruction.

    @@ -155,6 +164,39 @@ void OPENSSL_cpuid_setup(void)
         OPENSSL_ia32cap_P[0] = (unsigned int)vec | (1 << 10);
         OPENSSL_ia32cap_P[1] = (unsigned int)(vec >> 32);
     }
    +static void init(void) __attribute__((constructor));
    +static void init(void)
    +{
    +    OPENSSL_cpuid_setup();
    +}
    +
    +void OPENSSL_cleanse(void *ptr, size_t len)
    +{
    +    zmemset(ptr, 0, len);
    +}
    +
    +int CRYPTO_memcmp(const void *a, const void *b, size_t len)
    +{
    +    zcheck_readonly(a, len);
    +    zcheck_readonly(b, len);
    +    return zunsafe_buf_call(len, "CRYPTO_memcmp", a, b, len);
    +}
    +
    +uint32_t OPENSSL_rdtsc(void)
    +{
    +    return zunsafe_fast_call("OPENSSL_rdtsc");
    +}
    +
    +size_t OPENSSL_ia32_rdseed_bytes(unsigned char *buf, size_t len)
    +{
    +    zcheck(buf, len);
    +    return zunsafe_buf_call(len, "OPENSSL_ia32_rdseed_bytes", buf, len);
    +}
    +size_t OPENSSL_ia32_rdrand_bytes(unsigned char *buf, size_t len)
    +{
    +    zcheck(buf, len);
    +    return zunsafe_buf_call(len, "OPENSSL_ia32_rdrand_bytes", buf, len);
    +}
     # else
     unsigned int OPENSSL_ia32cap_P[4];
     # endif

The first part of this change is about how `OPENSSL_cpuid_setup` is called. Normally, OpenSSL uses assembly code to register a global constructor to call this function, but that requires having assembly code calling C code, which Fil-C doesn't support. Luckily, we can register global constructors from C, so that's what we do with the `init` function.

Then, we provide an implementation of `OPENSSL_cleanse`, which is basically a secure `bzero`. Normally, OpenSSL implements this in assembly, to be extra super sure that:

- It's constant time (does not depend on the contents of the buffer being cleansed).

- Definitely zeroes the memory no matter what kinds of opinions the compiler may have.

We could just forward to this function from Fil-C, but that would result in the capabilities associated with the memory not being zeroed. Maybe that would be OK from a security standpoint, but it feels shady enough that I'd rather we zero the capabilities. Also, the Fil-C `zmemset` function is specifically designed to *not* be something the compiler optimizes. It's a hard guarantee in Fil-C that the compiler will always view `zmemset` as an opaque function call, and never inline it or optimize it in any way.

And, `zmemset` does zero the capability, and neither the musl nor glibc `memset` implementations that this uses have any dependency on the contents of the buffer.

For `CRYPTO_memcmp` however, we forward to the assembly implementation, because there is no guarantee that the libc implementations are sufficiently constant time.

We also provide forwarding functions `OPENSSL_rdtsc` (read timestamp counter, used for performance measurement), `OPENSSL_ia32_rdseed_bytes`, and `OPENSSL_ia32_rdrand_bytes` (used for RNG).

### Changes To `crypto/des/des_local.h`

The only change needed to the Digital Encryption Standard (DES) is to not use the `ror` instructions on x86_64 via inline assembly. I don't believe that implementing `ROTATE` using shifts breaks any constant time guarantees.

    @@ -85,7 +85,7 @@
     #  define ROTATE(a,n)     (_lrotr(a,n))
     # elif defined(__ICC)
     #  define ROTATE(a,n)     (_rotr(a,n))
    -# elif defined(__GNUC__) && __GNUC__>=2 && !defined(__STRICT_ANSI__) && !defined(OPENSSL_NO_ASM) && !defined(OPENSSL_NO_INLINE_ASM) && !defined(PEDANTIC)
    +# elif defined(__GNUC__) && __GNUC__>=2 && !defined(__STRICT_ANSI__) && !defined(OPENSSL_NO_ASM) && !defined(OPENSSL_NO_INLINE_ASM) && !defined(PEDANTIC) && !defined(__FILC__)
     #  if defined(__i386) || defined(__i386__) || defined(__x86_64) || defined(__x86_64__)
     #   define ROTATE(a,n)   ({ register unsigned int ret;   \
                                     asm ("rorl %1,%0"       \

### Changes To `crypto/ec/asm/ecp_nistz256-x86_64.pl`

At last, we can get to some of my favorite code in OpenSSL, namely *perlasm*. OpenSSL supports different assembly dialects, and for x86, it supports different calling conventions (Microsoft versus everyone else's). To simplify this, assembly code in OpenSSL is written as perl code that generates the assembly. What fun!

    @@ -4706,35 +4706,35 @@ $code.=<<___ if ($addx);
     ___
     }
     
    -########################################################################
    -# Convert ecp_nistz256_table.c to layout expected by ecp_nistz_gather_w7
    -#
    -open TABLE,"<ecp_nistz256_table.c"		or
    -open TABLE,"<${dir}../ecp_nistz256_table.c"	or
    -die "failed to open ecp_nistz256_table.c:",$!;
    -
    -use integer;
    -
    -foreach(<TABLE>) {
    -	s/TOBN\(\s*(0x[0-9a-f]+),\s*(0x[0-9a-f]+)\s*\)/push @arr,hex($2),hex($1)/geo;
    -}
    -close TABLE;
    -
    -die "insane number of elements" if ($#arr != 64*16*37-1);
    -
    -print <<___;
    -.text
    -.globl	ecp_nistz256_precomputed
    -.type	ecp_nistz256_precomputed,\@object
    -.align	4096
    -ecp_nistz256_precomputed:
    -___
    -while (@line=splice(@arr,0,16)) {
    -	print ".long\t",join(',',map { sprintf "0x%08x",$_} @line),"\n";
    -}
    -print <<___;
    -.size	ecp_nistz256_precomputed,.-ecp_nistz256_precomputed
    -___
    +# ########################################################################
    +# # Convert ecp_nistz256_table.c to layout expected by ecp_nistz_gather_w7
    +# #
    +# open TABLE,"<ecp_nistz256_table.c"		or
    +# open TABLE,"<${dir}../ecp_nistz256_table.c"	or
    +# die "failed to open ecp_nistz256_table.c:",$!;
    +# 
    +# use integer;
    +# 
    +# foreach(<TABLE>) {
    +# 	s/TOBN\(\s*(0x[0-9a-f]+),\s*(0x[0-9a-f]+)\s*\)/push @arr,hex($2),hex($1)/geo;
    +# }
    +# close TABLE;
    +# 
    +# die "insane number of elements" if ($#arr != 64*16*37-1);
    +# 
    +# print <<___;
    +# .text
    +# .globl	ecp_nistz256_precomputed
    +# .type	ecp_nistz256_precomputed,\@object
    +# .align	4096
    +# ecp_nistz256_precomputed:
    +# ___
    +# while (@line=splice(@arr,0,16)) {
    +# 	print ".long\t",join(',',map { sprintf "0x%08x",$_} @line),"\n";
    +# }
    +# print <<___;
    +# .size	ecp_nistz256_precomputed,.-ecp_nistz256_precomputed
    +# ___
     
     $code =~ s/\`([^\`]*)\`/eval $1/gem;
     print $code;

This disables a compile-time optimization where OpenSSL compiles C code to assembly using 29 lines of perl code. It only works for the C code in `ecp_nistz256_table.c`, which defines a giant table. Presumably, this is done to avoid overloading the compiler with a lot of work, since the table is quite large.

Since the table is meant to be used from C code, it's easier for Fil-C to just compile `ecp_nistz256_table.c` with the Fil-C compiler. So, we disable this part of the perlasm.

### Changes To `crypto/ec/build.info`

    @@ -3,7 +3,7 @@ IF[{- !$disabled{asm} -}]
       $ECASM_x86=ecp_nistz256.c ecp_nistz256-x86.S
       $ECDEF_x86=ECP_NISTZ256_ASM
     
    -  $ECASM_x86_64=ecp_nistz256.c ecp_nistz256-x86_64.s
    +  $ECASM_x86_64=ecp_nistz256.c ecp_nistz256_table.c ecp_nistz256-x86_64.s
       $ECDEF_x86_64=ECP_NISTZ256_ASM
       IF[{- !$disabled{'ecx'} -}]
         $ECASM_x86_64=$ECASM_x86_64 x25519-x86_64.s

As mentioned in the previous section, we turn off OpenSSL's bespoke 29-line C compiler and let the Fil-C compiler handle `ecp_nistz256_table.c`.

### Changes To `crypto/ec/curve25519.c`

Curve 25519 is a very common asymmetric crypto implementation. It's my personal favorite for SSH keys!

    @@ -20,6 +20,7 @@
     #include <openssl/sha.h>
     
     #include "internal/numbers.h"
    +#include <stdfil.h>
     
     #if defined(X25519_ASM) && (defined(__x86_64) || defined(__x86_64__) || \
                                 defined(_M_AMD64) || defined(_M_X64))

We start by including `<stdfil.h>`.

    @@ -28,7 +29,10 @@
     
     typedef uint64_t fe64[4];
     
    -int x25519_fe64_eligible(void);
    +static int x25519_fe64_eligible(void)
    +{
    +    return zunsafe_fast_call("x25519_fe64_eligible");
    +}
     
     /*
      * Following subroutines perform corresponding operations modulo

This wraps the super simple `x25519_fe64_eligible` function, that just detects if the `fe64` codepath is available in assembly.

    @@ -39,12 +43,45 @@ int x25519_fe64_eligible(void);
      *
      * There are no reference C implementations for these.
      */
    -void x25519_fe64_mul(fe64 h, const fe64 f, const fe64 g);
    -void x25519_fe64_sqr(fe64 h, const fe64 f);
    -void x25519_fe64_mul121666(fe64 h, fe64 f);
    -void x25519_fe64_add(fe64 h, const fe64 f, const fe64 g);
    -void x25519_fe64_sub(fe64 h, const fe64 f, const fe64 g);
    -void x25519_fe64_tobytes(uint8_t *s, const fe64 f);
    +static void x25519_fe64_mul(fe64 h, const fe64 f, const fe64 g)
    +{
    +    zcheck(h, sizeof(fe64));
    +    zcheck_readonly(f, sizeof(fe64));
    +    zcheck_readonly(g, sizeof(fe64));
    +    zunsafe_fast_call("x25519_fe64_mul", h, f, g);
    +}
    +static void x25519_fe64_sqr(fe64 h, const fe64 f)
    +{
    +    zcheck(h, sizeof(fe64));
    +    zcheck_readonly(f, sizeof(fe64));
    +    zunsafe_fast_call("x25519_fe64_sqr", h, f);
    +}
    +static void x25519_fe64_mul121666(fe64 h, fe64 f)
    +{
    +    zcheck(h, sizeof(fe64));
    +    zcheck(f, sizeof(fe64));
    +    zunsafe_fast_call("x25519_fe64_mul121666", h, f);
    +}
    +static void x25519_fe64_add(fe64 h, const fe64 f, const fe64 g)
    +{
    +    zcheck(h, sizeof(fe64));
    +    zcheck_readonly(f, sizeof(fe64));
    +    zcheck_readonly(g, sizeof(fe64));
    +    zunsafe_fast_call("x25519_fe64_add", h, f, g);
    +}
    +static void x25519_fe64_sub(fe64 h, const fe64 f, const fe64 g)
    +{
    +    zcheck(h, sizeof(fe64));
    +    zcheck_readonly(f, sizeof(fe64));
    +    zcheck_readonly(g, sizeof(fe64));
    +    zunsafe_fast_call("x25519_fe64_sub", h, f, g);
    +}
    +static void x25519_fe64_tobytes(uint8_t *s, const fe64 f)
    +{
    +    zcheck(s, sizeof(fe64));
    +    zcheck_readonly(f, sizeof(fe64));
    +    zunsafe_fast_call("x25519_fe64_tobytes", s, f);
    +}
     # define fe64_mul x25519_fe64_mul
     # define fe64_sqr x25519_fe64_sqr
     # define fe64_mul121666 x25519_fe64_mul121666

This provides wrappers for the `fe64` codepaths. All of these are constant time functions that operate on `fe64`, which is 256 bits of data.

    @@ -387,9 +424,25 @@ static void fe51_tobytes(uint8_t *s, const fe51 h)
     }
     
     # if defined(X25519_ASM)
    -void x25519_fe51_mul(fe51 h, const fe51 f, const fe51 g);
    -void x25519_fe51_sqr(fe51 h, const fe51 f);
    -void x25519_fe51_mul121666(fe51 h, fe51 f);
    +static void x25519_fe51_mul(fe51 h, const fe51 f, const fe51 g)
    +{
    +    zcheck(h, sizeof(fe51));
    +    zcheck_readonly(f, sizeof(fe51));
    +    zcheck_readonly(g, sizeof(fe51));
    +    zunsafe_fast_call("x25519_fe51_mul", h, f, g);
    +}
    +static void x25519_fe51_sqr(fe51 h, const fe51 f)
    +{
    +    zcheck(h, sizeof(fe51));
    +    zcheck_readonly(f, sizeof(fe51));
    +    zunsafe_fast_call("x25519_fe51_sqr", h, f);
    +}
    +static void x25519_fe51_mul121666(fe51 h, fe51 f)
    +{
    +    zcheck(h, sizeof(fe51));
    +    zcheck(f, sizeof(fe51));
    +    zunsafe_fast_call("x25519_fe51_mul121666", h, f);
    +}
     #  define fe51_mul x25519_fe51_mul
     #  define fe51_sq  x25519_fe51_sqr
     #  define fe51_mul121666 x25519_fe51_mul121666

Then we provide wrappers for the `fe51` codepaths. `fe51` is 320 bits of data. All of these functions are constant time.

### Changes To `crypto/ec/ecp_nistz256.c`

This file contains a high performance implementation of the NIST P-256 elliptic curve.

    @@ -30,6 +30,7 @@
     #include "crypto/bn.h"
     #include "ec_local.h"
     #include "internal/refcount.h"
    +#include <stdfil.h>
     
     #if BN_BITS2 != 64
     # define TOBN(hi,lo)    lo,hi

We start by including `<stdfil.h>`.

    @@ -39,6 +40,7 @@
     
     #define ALIGNPTR(p,N)   ((unsigned char *)p+N-(size_t)p%N)
     #define P256_LIMBS      (256/BN_BITS2)
    +#define P256_BYTES      (256/8)
     
     typedef unsigned short u16;

The code often talks about "limbs" of a 256-bit value, where a limb is a machine word (so 64 bits in our case, since Fil-C is all about X86\_64). But for the safety checks we'll be emitting, it's better to talk about the number of bytes in a 256-bit value, so we define `P256_BYTES` as a helpful constant.

    @@ -87,47 +89,120 @@ struct nistz256_pre_comp_st {
      * in all cases so far...
      */
     /* Modular add: res = a+b mod P   */
    -void ecp_nistz256_add(BN_ULONG res[P256_LIMBS],
    -                      const BN_ULONG a[P256_LIMBS],
    -                      const BN_ULONG b[P256_LIMBS]);
    +static void ecp_nistz256_add(BN_ULONG res[P256_LIMBS],
    +                             const BN_ULONG a[P256_LIMBS],
    +                             const BN_ULONG b[P256_LIMBS])
    +{
    +    zcheck(res, P256_BYTES);
    +    zcheck_readonly(a, P256_BYTES);
    +    zcheck_readonly(b, P256_BYTES);
    +    zunsafe_fast_call("ecp_nistz256_add", res, a, b);
    +}
     /* Modular mul by 2: res = 2*a mod P */
    -void ecp_nistz256_mul_by_2(BN_ULONG res[P256_LIMBS],
    -                           const BN_ULONG a[P256_LIMBS]);
    +static void ecp_nistz256_mul_by_2(BN_ULONG res[P256_LIMBS],
    +                                  const BN_ULONG a[P256_LIMBS])
    +{
    +    zcheck(res, P256_BYTES);
    +    zcheck_readonly(a, P256_BYTES);
    +    zunsafe_fast_call("ecp_nistz256_mul_by_2", res, a);
    +}
     /* Modular mul by 3: res = 3*a mod P */
    -void ecp_nistz256_mul_by_3(BN_ULONG res[P256_LIMBS],
    -                           const BN_ULONG a[P256_LIMBS]);
    +static void ecp_nistz256_mul_by_3(BN_ULONG res[P256_LIMBS],
    +                                  const BN_ULONG a[P256_LIMBS])
    +{
    +    zcheck(res, P256_BYTES);
    +    zcheck_readonly(a, P256_BYTES);
    +    zunsafe_fast_call("ecp_nistz256_mul_by_3", res, a);
    +}
     
     /* Modular div by 2: res = a/2 mod P */
    -void ecp_nistz256_div_by_2(BN_ULONG res[P256_LIMBS],
    -                           const BN_ULONG a[P256_LIMBS]);
    +static void ecp_nistz256_div_by_2(BN_ULONG res[P256_LIMBS],
    +                                  const BN_ULONG a[P256_LIMBS])
    +{
    +    zcheck(res, P256_BYTES);
    +    zcheck_readonly(a, P256_BYTES);
    +    zunsafe_fast_call("ecp_nistz256_div_by_2", res, a);
    +}
     /* Modular sub: res = a-b mod P   */
    -void ecp_nistz256_sub(BN_ULONG res[P256_LIMBS],
    -                      const BN_ULONG a[P256_LIMBS],
    -                      const BN_ULONG b[P256_LIMBS]);
    +static void ecp_nistz256_sub(BN_ULONG res[P256_LIMBS],
    +                             const BN_ULONG a[P256_LIMBS],
    +                             const BN_ULONG b[P256_LIMBS])
    +{
    +    zcheck(res, P256_BYTES);
    +    zcheck_readonly(a, P256_BYTES);
    +    zcheck_readonly(b, P256_BYTES);
    +    zunsafe_fast_call("ecp_nistz256_sub", res, a, b);
    +}
     /* Modular neg: res = -a mod P    */
    -void ecp_nistz256_neg(BN_ULONG res[P256_LIMBS], const BN_ULONG a[P256_LIMBS]);
    +static void ecp_nistz256_neg(BN_ULONG res[P256_LIMBS], const BN_ULONG a[P256_LIMBS])
    +{
    +    zcheck(res, P256_BYTES);
    +    zcheck_readonly(a, P256_BYTES);
    +    zunsafe_fast_call("ecp_nistz256_neg", res, a);
    +}
     /* Montgomery mul: res = a*b*2^-256 mod P */
    -void ecp_nistz256_mul_mont(BN_ULONG res[P256_LIMBS],
    -                           const BN_ULONG a[P256_LIMBS],
    -                           const BN_ULONG b[P256_LIMBS]);
    +static void ecp_nistz256_mul_mont(BN_ULONG res[P256_LIMBS],
    +                                  const BN_ULONG a[P256_LIMBS],
    +                                  const BN_ULONG b[P256_LIMBS])
    +{
    +    zcheck(res, P256_BYTES);
    +    zcheck_readonly(a, P256_BYTES);
    +    zcheck_readonly(b, P256_BYTES);
    +    zunsafe_fast_call("ecp_nistz256_mul_mont", res, a, b);
    +}
     /* Montgomery sqr: res = a*a*2^-256 mod P */
    -void ecp_nistz256_sqr_mont(BN_ULONG res[P256_LIMBS],
    -                           const BN_ULONG a[P256_LIMBS]);
    +static void ecp_nistz256_sqr_mont(BN_ULONG res[P256_LIMBS],
    +                                  const BN_ULONG a[P256_LIMBS])
    +{
    +    zcheck(res, P256_BYTES);
    +    zcheck_readonly(a, P256_BYTES);
    +    zunsafe_fast_call("ecp_nistz256_sqr_mont", res, a);
    +}
     /* Convert a number from Montgomery domain, by multiplying with 1 */
    -void ecp_nistz256_from_mont(BN_ULONG res[P256_LIMBS],
    -                            const BN_ULONG in[P256_LIMBS]);
    +static void ecp_nistz256_from_mont(BN_ULONG res[P256_LIMBS],
    +                                   const BN_ULONG in[P256_LIMBS])
    +{
    +    zcheck(res, P256_BYTES);
    +    zcheck_readonly(in, P256_BYTES);
    +    zunsafe_fast_call("ecp_nistz256_from_mont", res, in);
    +}
     /* Convert a number to Montgomery domain, by multiplying with 2^512 mod P*/
    -void ecp_nistz256_to_mont(BN_ULONG res[P256_LIMBS],
    -                          const BN_ULONG in[P256_LIMBS]);
    +static void ecp_nistz256_to_mont(BN_ULONG res[P256_LIMBS],
    +                                 const BN_ULONG in[P256_LIMBS])
    +{
    +    zcheck(res, P256_BYTES);
    +    zcheck_readonly(in, P256_BYTES);
    +    zunsafe_fast_call("ecp_nistz256_to_mont", res, in);
    +}
     /* Functions that perform constant time access to the precomputed tables */
    -void ecp_nistz256_scatter_w5(P256_POINT *val,
    -                             const P256_POINT *in_t, int idx);
    -void ecp_nistz256_gather_w5(P256_POINT *val,
    -                            const P256_POINT *in_t, int idx);
    -void ecp_nistz256_scatter_w7(P256_POINT_AFFINE *val,
    -                             const P256_POINT_AFFINE *in_t, int idx);
    -void ecp_nistz256_gather_w7(P256_POINT_AFFINE *val,
    -                            const P256_POINT_AFFINE *in_t, int idx);
    +static void ecp_nistz256_scatter_w5(P256_POINT *val,
    +                                    const P256_POINT *in_t, int idx)
    +{
    +    zcheck_readonly(in_t, sizeof(P256_POINT));
    +    zcheck(val + idx - 1, sizeof(P256_POINT));
    +    zunsafe_fast_call("ecp_nistz256_scatter_w5", val, in_t, idx);
    +}
    +static void ecp_nistz256_gather_w5(P256_POINT *val,
    +                                   const P256_POINT *in_t, int idx)
    +{
    +    zcheck_readonly(in_t, zchecked_mul(sizeof(P256_POINT), 16));
    +    zcheck(val, sizeof(P256_POINT));
    +    zunsafe_fast_call("ecp_nistz256_gather_w5", val, in_t, idx);
    +}
    +static void ecp_nistz256_scatter_w7(P256_POINT_AFFINE *val,
    +                                    const P256_POINT_AFFINE *in_t, int idx)
    +{
    +    zcheck_readonly(in_t, sizeof(P256_POINT_AFFINE));
    +    zcheck(val + idx, sizeof(P256_POINT_AFFINE));
    +    zunsafe_fast_call("ecp_nistz256_scatter_w7", val, in_t, idx);
    +}
    +static void ecp_nistz256_gather_w7(P256_POINT_AFFINE *val,
    +                                   const P256_POINT_AFFINE *in_t, int idx)
    +{
    +    zcheck_readonly(in_t, zchecked_mul(sizeof(P256_POINT_AFFINE), 64));
    +    zcheck(val, sizeof(P256_POINT_AFFINE));
    +    zunsafe_fast_call("ecp_nistz256_gather_w7", val, in_t, idx);
    +}
     
     /* One converted into the Montgomery domain */
     static const BN_ULONG ONE[P256_LIMBS] = {

This provides a bunch of wrappers for assembly functions relating to various P256 values, like `P256_POINT` (three P256's), `P256_POINT_AFFINE` (two P256's), and in some cases tables of 16 or 64 points. It took a lot of reading of the assembly code to work out what checks to do here. All of these functions are bounded-time, so we can use `zunsafe_fast_call`.

    @@ -246,12 +321,29 @@ static BN_ULONG is_one(const BIGNUM *z)
      * ecp_nistz256 module is ECP_NISTZ256_ASM.)
      */
     #ifndef ECP_NISTZ256_REFERENCE_IMPLEMENTATION
    -void ecp_nistz256_point_double(P256_POINT *r, const P256_POINT *a);
    -void ecp_nistz256_point_add(P256_POINT *r,
    -                            const P256_POINT *a, const P256_POINT *b);
    -void ecp_nistz256_point_add_affine(P256_POINT *r,
    -                                   const P256_POINT *a,
    -                                   const P256_POINT_AFFINE *b);
    +static void ecp_nistz256_point_double(P256_POINT *r, const P256_POINT *a)
    +{
    +    zcheck(r, sizeof(P256_POINT));
    +    zcheck_readonly(a, sizeof(P256_POINT));
    +    zunsafe_fast_call("ecp_nistz256_point_double", r, a);
    +}
    +static void ecp_nistz256_point_add(P256_POINT *r,
    +                                   const P256_POINT *a, const P256_POINT *b)
    +{
    +    zcheck(r, sizeof(P256_POINT));
    +    zcheck_readonly(a, sizeof(P256_POINT));
    +    zcheck_readonly(b, sizeof(P256_POINT));
    +    zunsafe_fast_call("ecp_nistz256_point_add", r, a, b);
    +}
    +static void ecp_nistz256_point_add_affine(P256_POINT *r,
    +                                          const P256_POINT *a,
    +                                          const P256_POINT_AFFINE *b)
    +{
    +    zcheck(r, sizeof(P256_POINT));
    +    zcheck_readonly(a, sizeof(P256_POINT));
    +    zcheck_readonly(b, sizeof(P256_POINT_AFFINE));
    +    zunsafe_fast_call("ecp_nistz256_point_add_affine", r, a, b);
    +}
     #else
     /* Point double: r = 2*a */
     static void ecp_nistz256_point_double(P256_POINT *r, const P256_POINT *a)

This provides more wrappers for bounded-time P256 point operations.

    @@ -1269,12 +1361,23 @@ static int ecp_nistz256_window_have_precompute_mult(const EC_GROUP *group)
     /*
      * Montgomery mul modulo Order(P): res = a*b*2^-256 mod Order(P)
      */
    -void ecp_nistz256_ord_mul_mont(BN_ULONG res[P256_LIMBS],
    -                               const BN_ULONG a[P256_LIMBS],
    -                               const BN_ULONG b[P256_LIMBS]);
    -void ecp_nistz256_ord_sqr_mont(BN_ULONG res[P256_LIMBS],
    -                               const BN_ULONG a[P256_LIMBS],
    -                               BN_ULONG rep);
    +static void ecp_nistz256_ord_mul_mont(BN_ULONG res[P256_LIMBS],
    +                                      const BN_ULONG a[P256_LIMBS],
    +                                      const BN_ULONG b[P256_LIMBS])
    +{
    +    zcheck(res, P256_BYTES);
    +    zcheck_readonly(a, P256_BYTES);
    +    zcheck_readonly(b, P256_BYTES);
    +    zunsafe_fast_call("ecp_nistz256_ord_mul_mont", res, a, b);
    +}
    +static void ecp_nistz256_ord_sqr_mont(BN_ULONG res[P256_LIMBS],
    +                                      const BN_ULONG a[P256_LIMBS],
    +                                      BN_ULONG rep)
    +{
    +    zcheck(res, P256_BYTES);
    +    zcheck_readonly(a, P256_BYTES);
    +    zunsafe_fast_call("ecp_nistz256_ord_sqr_mont", res, a, rep);
    +}
     
     static int ecp_nistz256_inv_mod_ord(const EC_GROUP *group, BIGNUM *r,
                                         const BIGNUM *x, BN_CTX *ctx)

Finally we wrap the montgomery multiplication and squaring operations.

### Changes To `crypto/ec/ecp_nistz256_table.c`

    @@ -21,16 +21,16 @@
      * appears to lead to invalid ELF files being produced.
      */
     
    +#define TOBN(hi,lo) (((unsigned long)hi<<32)|(unsigned long)lo)
    +
     #if defined(__GNUC__)
    -__attribute((aligned(4096)))
    +__attribute__((aligned(4096)))
     #elif defined(_MSC_VER)
     __declspec(align(4096))
     #elif defined(__SUNPRO_C)
     # pragma align 4096(ecp_nistz256_precomputed)
     #endif
    -static const BN_ULONG ecp_nistz256_precomputed[37][64 *
    -                                                   sizeof(P256_POINT_AFFINE) /
    -                                                   sizeof(BN_ULONG)] = {
    +const unsigned long ecp_nistz256_precomputed[37][64 * 8] = {
         {TOBN(0x79e730d4, 0x18a9143c), TOBN(0x75ba95fc, 0x5fedb601),
          TOBN(0x79fb732b, 0x77622510), TOBN(0x18905f76, 0xa53755c6),
          TOBN(0xddf25357, 0xce95560a), TOBN(0x8b4ab8e4, 0xba19e45c),

This is a `.c` file that is designed to be "compiled" by 29 lines of perl code. We make minimal changes to it to make it compile correctly with a real C compiler.

### Changes To `crypto/evp/e_aes_cbc_hmac_sha1.c`

This file provides an implementation of AES CBC encryption that also authenticates the message with SHA1. It uses some of the AES and stitched AES/SHA1 functions we wrapped in another file. It also uses some functions that aren't wrapped anywhere else.

    @@ -27,6 +27,7 @@
     #include "crypto/evp.h"
     #include "internal/constant_time.h"
     #include "evp_local.h"
    +#include <stdfil.h>
     
     typedef struct {
         AES_KEY ks;

Start by including `<stdfil.h>`.

    @@ -99,7 +100,12 @@ static int aesni_cbc_hmac_sha1_init_key(EVP_CIPHER_CTX *ctx,
     #  define aes_off 0
     # endif
     
    -void sha1_block_data_order(void *c, const void *p, size_t len);
    +void sha1_block_data_order(void *c, const void *p, size_t len)
    +{
    +    zcheck(c, sizeof(SHA_CTX));
    +    zcheck_readonly(p, zchecked_mul(len, SHA_CBLOCK));
    +    zunsafe_buf_call(zchecked_mul(len, SHA_CBLOCK), "sha1_block_data_order", c, p, len);
    +}
     
     static void sha1_update(SHA_CTX *c, const void *data, size_t len)
     {

We wrap this function that ingests data in units of SHA1 block (64 bytes).

    @@ -147,7 +153,20 @@ typedef struct {
         int blocks;
     } HASH_DESC;
     
    -void sha1_multi_block(SHA1_MB_CTX *, const HASH_DESC *, int);
    +void sha1_multi_block(SHA1_MB_CTX *ctx, const HASH_DESC *inp, int n4x)
    +{
    +    zcheck(ctx, sizeof(SHA1_MB_CTX));
    +    ZSAFETY_CHECK(n4x == 1 || n4x == 2);
    +    unsigned len = n4x * 4;
    +    zcheck_readonly(inp, zchecked_mul(len, sizeof(HASH_DESC)));
    +    unsigned i;
    +    unsigned total = 0;
    +    for (i = len; i--;) {
    +        zcheck_readonly(inp[i].ptr, zchecked_mul(inp[i].blocks, 64));
    +        total += zchecked_mul(inp[i].blocks, 64);
    +    }
    +    zunsafe_buf_call(total, "sha1_multi_block", ctx, inp, n4x);
    +}
     
     typedef struct {
         const unsigned char *inp;

Finally, we wrap a multi-block assembly function. Like other multi-block functions in OpenSSL, this takes the `n4x` argument that tells if we're dealing with 4 or 8 buffers. The `blocks` arguments in `HASH_DESC` are in units of SHA1 block, so 64 bytes.

### Changes To `crypto/evp/e_aes_cbc_hmac_sha256.c`

This file provides an implementation of AES CBC encryption that also authenticates the message with SHA256. It uses some of the AES and stitched AES/SHA256 functions we wrapped in another file. It also uses a function that isn't wrapped anywhere else.

    @@ -27,6 +27,7 @@
     #include "internal/constant_time.h"
     #include "crypto/evp.h"
     #include "evp_local.h"
    +#include <stdfil.h>
     
     typedef struct {
         AES_KEY ks;

As usual, include `<stdfil.h>`.

    @@ -141,7 +142,20 @@ typedef struct {
         int blocks;
     } HASH_DESC;
     
    -void sha256_multi_block(SHA256_MB_CTX *, const HASH_DESC *, int);
    +void sha256_multi_block(SHA256_MB_CTX *ctx, const HASH_DESC *inp, int n4x)
    +{
    +    zcheck(ctx, sizeof(SHA256_MB_CTX));
    +    ZSAFETY_CHECK(n4x == 1 || n4x == 2);
    +    unsigned len = n4x * 4;
    +    zcheck_readonly(inp, zchecked_mul(len, sizeof(HASH_DESC)));
    +    unsigned i;
    +    unsigned total = 0;
    +    for (i = len; i--;) {
    +        zcheck_readonly(inp[i].ptr, zchecked_mul(inp[i].blocks, 64));
    +        total += zchecked_mul(inp[i].blocks, 64);
    +    }
    +    zunsafe_buf_call(total, "sha256_multi_block", ctx, inp, n4x);
    +}
     
     typedef struct {
         const unsigned char *inp;

This is another multi-block function. Again, `n4x` indicates whether we have 4 or 8 buffers. The `blocks` arguments in `HASH_DESC` are in units of SHA256 blocks, so 64 bytes.

### Changes To `crypto/evp/e_chacha20_poly1305.c`

This implements the ChaCha20-Poly1305 authenticated encryption with associated data (AEAD) algorithm. This file mostly uses code that we alraedy handled the wrapping for elsewhere, but it does include a handful of its own functions that need wrapping.

    @@ -18,6 +18,7 @@
     # include "crypto/evp.h"
     # include "evp_local.h"
     # include "crypto/chacha.h"
    +# include <stdfil.h>
     
     typedef struct {
         union {

We include `<stdfil.h>` so we can `zunsafe_buf_call` and `zmkptr`.

    @@ -204,8 +205,20 @@ static int chacha20_poly1305_init_key(EVP_CIPHER_CTX *ctx,
     #   if defined(POLY1305_ASM) && (defined(__x86_64) || defined(__x86_64__) || \
                                      defined(_M_AMD64) || defined(_M_X64))
     #    define XOR128_HELPERS
    -void *xor128_encrypt_n_pad(void *out, const void *inp, void *otp, size_t len);
    -void *xor128_decrypt_n_pad(void *out, const void *inp, void *otp, size_t len);
    +void *xor128_encrypt_n_pad(void *out, const void *inp, void *otp, size_t len)
    +{
    +    zcheck(out, len);
    +    zcheck_readonly(inp, len);
    +    zcheck(otp, (len + 15) & -16);
    +    return zmkptr(otp, zunsafe_buf_call(len, "xor128_encrypt_n_pad", out, inp, otp, len));
    +}
    +void *xor128_decrypt_n_pad(void *out, const void *inp, void *otp, size_t len)
    +{
    +    zcheck(out, len);
    +    zcheck_readonly(inp, len);
    +    zcheck(otp, (len + 15) & -16);
    +    return zmkptr(otp, zunsafe_buf_call(len, "xor128_decrypt_n_pad", out, inp, otp, len));
    +}
     static const unsigned char zero[4 * CHACHA_BLK_SIZE] = { 0 };
     #   else
     static const unsigned char zero[2 * CHACHA_BLK_SIZE] = { 0 };

The two assembly functions that we wrap in this file are unique in that they return pointers. Luckily, they just return an offset pointer within the `otp` argument.

Note that the the `otp` bounds check is tricky:

- It's not super obvious, but the assembly always pads the output of `otp` up to a multiple of 16 bytes.

- The `len + 15` could overflow, but if it had, then the previous `zcheck`'s would have failed. So, it's narrowly OK not to use `zchecked_add` here (though maybe I should revisit this out of paranoia).

### Changes To `crypto/md5/md5_dgst.c`

MD5 is no longer suitable for cryptographic applications, but OpenSSL still supports it since it's still useful for checksumming.

    @@ -16,6 +16,7 @@
     #include <stdio.h>
     #include "md5_local.h"
     #include <openssl/opensslv.h>
    +#include <stdfil.h>
     
     /*
      * Implemented from RFC1321 The MD5 Message-Digest Algorithm

First we include `<stdfil.h>`.

    @@ -167,4 +168,11 @@ void md5_block_data_order(MD5_CTX *c, const void *data_, size_t num)
             D = c->D += D;
         }
     }
    +#else
    +void md5_block_data_order(MD5_CTX *c, const void *data_, size_t num)
    +{
    +    zcheck(c, sizeof(MD5_CTX));
    +    zcheck_readonly(data_, zchecked_mul(num, MD5_CBLOCK));
    +    zunsafe_buf_call(num, "ossl_md5_block_asm_data_order", c, data_, num);
    +}
     #endif

Like other `block_data_order` functions, this takes an input buffer with a length specified in block units. MD5 uses 64-byte (512-bit) blocks. The `MD5_CBLOCK` constant is defined to 64.

### New File: `crypto/modes/aesni_gcm_asm_forward.c`

This file contains forwarding functions for the Intel AES-NI Galois/Counter Mode.

    #include "internal/deprecated.h"
    
    #include <assert.h>
    
    #include <stdlib.h>
    #include <openssl/crypto.h>
    #include <openssl/aes.h>
    #include "crypto/modes.h"
    #include "crypto/aes_platform.h"
    #include <stdfil.h>
    #include <stddef.h>
    
    size_t aesni_gcm_encrypt(const unsigned char *in, unsigned char *out, size_t len,
                             const void *key, unsigned char ivec[16], u64 *Xi)
    {
        zcheck_readonly(in, len);
        zcheck(out, len);
        zcheck_readonly(key, sizeof(AES_KEY));
        zcheck(ivec, 16);
        zcheck(Xi, sizeof(GCM128_CONTEXT) - offsetof(GCM128_CONTEXT, Xi));
        return zunsafe_buf_call(len, "aesni_gcm_encrypt", in, out, len, key, ivec, Xi);
    }

This function has a tricky safety contract. The simple parts are that `len` is in bytes, the key is an `AES_KEY`, and the `ivec` is a 16 byte block. However, `Xi` points to not just the `Xi` field of `GCM128_CONTEXT` but a number of subsequent fields as well. We conservatively check that the `Xi` pointer is pointing into the `Xi` offset of something that is at least a `GCM128_CONTEXT`.

    size_t aesni_gcm_decrypt(const unsigned char *in, unsigned char *out, size_t len,
                             const void *key, unsigned char ivec[16], u64 *Xi)
    {
        zcheck_readonly(in, len);
        zcheck(out, len);
        zcheck_readonly(key, sizeof(AES_KEY));
        zcheck(ivec, 16);
        zcheck(Xi, sizeof(GCM128_CONTEXT) - offsetof(GCM128_CONTEXT, Xi));
        return zunsafe_buf_call(len, "aesni_gcm_decrypt", in, out, len, key, ivec, Xi);
    }

Same as `aesni_gcm_encrypt` but for decryption.

### Changes To `crypto/modes/build.info`

    @@ -4,7 +4,7 @@ $MODESASM=
     IF[{- !$disabled{asm} -}]
       $MODESASM_x86=ghash-x86.S
       $MODESDEF_x86=GHASH_ASM
    -  $MODESASM_x86_64=ghash-x86_64.s aesni-gcm-x86_64.s aes-gcm-avx512.s
    +  $MODESASM_x86_64=ghash-x86_64.s aesni_gcm_asm_forward.c aesni-gcm-x86_64.s aes-gcm-avx512.s
       $MODESDEF_x86_64=GHASH_ASM
     
       # ghash-ia64.s doesn't work on VMS

We add the `aesni_gcm_asm_forward.c` file to the build if assembly is enabled.

### Changes To `crypto/modes/gcm128.c`

    @@ -12,6 +12,7 @@
     #include "internal/cryptlib.h"
     #include "internal/endian.h"
     #include "crypto/modes.h"
    +#include <stdfil.h>
     
     #if defined(__GNUC__) && !defined(STRICT_ALIGNMENT)
     typedef size_t size_t_aX __attribute((__aligned__(1)));

We include `<stdfil.h>`.

    @@ -320,9 +321,21 @@ static void gcm_ghash_4bit(u64 Xi[2], const u128 Htable[16],
     }
     #  endif
     # else
    -void gcm_gmult_4bit(u64 Xi[2], const u128 Htable[16]);
    -void gcm_ghash_4bit(u64 Xi[2], const u128 Htable[16], const u8 *inp,
    -                    size_t len);
    +static void gcm_gmult_4bit(u64 Xi[2], const u128 Htable[16])
    +{
    +    zcheck(Xi, sizeof(u64) * 2);
    +    zcheck_readonly(Htable, sizeof(u128) * 16);
    +    zunsafe_fast_call("gcm_gmult_4bit", Xi, Htable);
    +}
    +
    +static void gcm_ghash_4bit(u64 Xi[2], const u128 Htable[16], const u8 *inp,
    +                           size_t len)
    +{
    +    zcheck(Xi, sizeof(u64) * 2);
    +    zcheck_readonly(Htable, sizeof(u128) * 16);
    +    zcheck_readonly(inp, len);
    +    zunsafe_buf_call(len, "gcm_ghash_4bit", Xi, Htable, inp, len);
    +}
     # endif
     
     # define GCM_MUL(ctx)      ctx->funcs.gmult(ctx->Xi.u,ctx->Htable)

Add forwarding functions for `gcm_gmult_4bit` and `gcm_ghash_4bit`.

    @@ -343,20 +356,56 @@ void gcm_ghash_4bit(u64 Xi[2], const u128 Htable[16], const u8 *inp,
              defined(_M_IX86)       || defined(_M_AMD64)    || defined(_M_X64))
     #  define GHASH_ASM_X86_OR_64
     
    -void gcm_init_clmul(u128 Htable[16], const u64 Xi[2]);
    -void gcm_gmult_clmul(u64 Xi[2], const u128 Htable[16]);
    -void gcm_ghash_clmul(u64 Xi[2], const u128 Htable[16], const u8 *inp,
    -                     size_t len);
    +static void gcm_init_clmul(u128 Htable[16], const u64 Xi[2])
    +{
    +    zcheck(Htable, sizeof(u128) * 16);
    +    zcheck_readonly(Xi, sizeof(u64) * 2);
    +    zunsafe_fast_call("gcm_init_clmul", Htable, Xi);
    +}
    +
    +static void gcm_gmult_clmul(u64 Xi[2], const u128 Htable[16])
    +{
    +    zcheck(Xi, sizeof(u64) * 2);
    +    zcheck_readonly(Htable, sizeof(u128) * 16);
    +    zunsafe_fast_call("gcm_gmult_clmul", Xi, Htable);
    +}
    +
    +static void gcm_ghash_clmul(u64 Xi[2], const u128 Htable[16], const u8 *inp,
    +                            size_t len)
    +{
    +    zcheck(Xi, sizeof(u64) * 2);
    +    zcheck_readonly(Htable, sizeof(u128) * 16);
    +    zcheck_readonly(inp, len);
    +    zunsafe_buf_call(len, "gcm_ghash_clmul", Xi, Htable, inp, len);
    +}
     
     #  if defined(__i386) || defined(__i386__) || defined(_M_IX86)
     #   define gcm_init_avx   gcm_init_clmul
     #   define gcm_gmult_avx  gcm_gmult_clmul
     #   define gcm_ghash_avx  gcm_ghash_clmul
     #  else
    -void gcm_init_avx(u128 Htable[16], const u64 Xi[2]);
    -void gcm_gmult_avx(u64 Xi[2], const u128 Htable[16]);
    +static void gcm_init_avx(u128 Htable[16], const u64 Xi[2])
    +{
    +    zcheck(Htable, sizeof(u128) * 16);
    +    zcheck_readonly(Xi, sizeof(u64) * 2);
    +    zunsafe_fast_call("gcm_init_avx", Htable, Xi);
    +}
    +
    +static void gcm_gmult_avx(u64 Xi[2], const u128 Htable[16])
    +{
    +    zcheck(Xi, sizeof(u64) * 2);
    +    zcheck_readonly(Htable, sizeof(u128) * 16);
    +    zunsafe_fast_call("gcm_gmult_avx", Xi, Htable);
    +}
    +
     void gcm_ghash_avx(u64 Xi[2], const u128 Htable[16], const u8 *inp,
    -                   size_t len);
    +                          size_t len)
    +{
    +    zcheck(Xi, sizeof(u64) * 2);
    +    zcheck_readonly(Htable, sizeof(u128) * 16);
    +    zcheck_readonly(inp, len);
    +    zunsafe_buf_call(len, "gcm_ghash_avx", Xi, Htable, inp, len);
    +}
     #  endif
     
     #  if   defined(__i386) || defined(__i386__) || defined(_M_IX86)

Add forwarding functioons for a bunch of other GCM functions. For all of these functions, we base the safety checks on the array lengths given in the function signatures.

### Changes To `crypto/poly1305/asm/poly1305-x86_64.pl`

    @@ -95,6 +95,11 @@ if (!$avx && `$ENV{CC} -v 2>&1` =~ /((?:clang|LLVM) version|.*based on LLVM) ([0
     	$avx = ($2>=3.0) + ($2>3.0);
     }
     
    +# FIXME: We should re-enable the avx codepaths. They are disabled because this code makes it
    +# necessary for user code to make indirect function calls into yololand, which Fil-C currently
    +# doesn't support.
    +$avx = 0;
    +
     open OUT,"| \"$^X\" \"$xlate\" $flavour \"$output\""
         or die "can't call $xlate: $!";
     *STDOUT=*OUT;

Normally, the Poly1305 assembly implementation has an initialization function that can opt to pick which sub-implementation to use, and then records this decision by stuffing function pointers into the OpenSSL context object.

Then, the C code indirectly calls those function pointers in the context object, instead of directly calling some named assembly function.

I don't like the idea of a Fil-C escape hatch that involves unchecked indirect calls. Also, it appears that all of these shenanigans are for performance rather than constant-time crypto. So, by setting `$avx` to `0`, I disable all of the variants except the most portable one.

### Changes To `crypto/poly1305/poly1305.c`

This file contained the use of those unsafe indirect calls, and so most of the changes in this file are to replace them with direct calls.

    @@ -12,6 +12,7 @@
     #include <openssl/crypto.h>
     
     #include "crypto/poly1305.h"
    +#include <stdfil.h>
     
     size_t Poly1305_ctx_size(void)
     {

Include `<stdfil.h>`.

    @@ -423,11 +424,28 @@ static void poly1305_emit(void *ctx, unsigned char mac[16],
     }
     # endif
     #else
    -int poly1305_init(void *ctx, const unsigned char key[16], void *func);
    -void poly1305_blocks(void *ctx, const unsigned char *inp, size_t len,
    -                     unsigned int padbit);
    -void poly1305_emit(void *ctx, unsigned char mac[16],
    -                   const unsigned int nonce[4]);
    +static int poly1305_init(void *ctx, const unsigned char key[16], void *func)
    +{
    +    zcheck(ctx, sizeof(poly1305_opaque));
    +    zcheck_readonly(key, 16);
    +    zcheck(func, sizeof(void*) * 2);
    +    return zunsafe_fast_call("poly1305_init", ctx, key, func);
    +}
    +static void poly1305_blocks(void *ctx, const unsigned char *inp, size_t len,
    +                            unsigned int padbit)
    +{
    +    zcheck(ctx, sizeof(poly1305_opaque));
    +    zcheck_readonly(inp, len);
    +    zunsafe_buf_call(len, "poly1305_blocks", ctx, inp, len, padbit);
    +}
    +static void poly1305_emit(void *ctx, unsigned char mac[16],
    +                          const unsigned int nonce[4])
    +{
    +    zcheck(ctx, sizeof(poly1305_opaque));
    +    zcheck(mac, 16);
    +    zcheck_readonly(nonce, sizeof(unsigned) * 4);
    +    zunsafe_fast_call("poly1305_emit", ctx, mac, nonce);
    +}
     #endif
     
     void Poly1305_Init(POLY1305 *ctx, const unsigned char key[32])

Wrap the three poly1305 functions, which take a `poly1305_opaque` context, and a buffer whose `len` is measured in bytes.

    @@ -456,26 +474,8 @@ void Poly1305_Init(POLY1305 *ctx, const unsigned char key[32])
     
     }
     
    -#ifdef POLY1305_ASM
    -/*
    - * This "eclipses" poly1305_blocks and poly1305_emit, but it's
    - * conscious choice imposed by -Wshadow compiler warnings.
    - */
    -# define poly1305_blocks (*poly1305_blocks_p)
    -# define poly1305_emit   (*poly1305_emit_p)
    -#endif
    -
     void Poly1305_Update(POLY1305 *ctx, const unsigned char *inp, size_t len)
     {
    -#ifdef POLY1305_ASM
    -    /*
    -     * As documented, poly1305_blocks is never called with input
    -     * longer than single block and padbit argument set to 0. This
    -     * property is fluently used in assembly modules to optimize
    -     * padbit handling on loop boundary.
    -     */
    -    poly1305_blocks_f poly1305_blocks_p = ctx->func.blocks;
    -#endif
         size_t rem, num;
     
         if ((num = ctx->num)) {

This turns off the indirect function call to `poly1305_blocks` and `poly1305_emit` by removing the `#define`. Also, remove the now-dead `poly1305_blocks_p` local. It was only used by the now-removed `poly1305_blocks` macro.

    @@ -509,10 +509,6 @@ void Poly1305_Update(POLY1305 *ctx, const unsigned char *inp, size_t len)
     
     void Poly1305_Final(POLY1305 *ctx, unsigned char mac[16])
     {
    -#ifdef POLY1305_ASM
    -    poly1305_blocks_f poly1305_blocks_p = ctx->func.blocks;
    -    poly1305_emit_f poly1305_emit_p = ctx->func.emit;
    -#endif
         size_t num;
     
         if ((num = ctx->num)) {

Remove the now-dead locals. They were only used by the now-removed macros.

### Changes To `crypto/rc4/build.info`

    @@ -3,7 +3,7 @@ LIBS=../../libcrypto
     $RC4ASM=rc4_enc.c rc4_skey.c
     IF[{- !$disabled{asm} -}]
       $RC4ASM_x86=rc4-586.S
    -  $RC4ASM_x86_64=rc4-x86_64.s rc4-md5-x86_64.s
    +  $RC4ASM_x86_64=rc4-x86_64.s rc4_md5_asm_forward.c rc4-md5-x86_64.s
       $RC4ASM_s390x=rc4-s390x.s
       $RC4ASM_parisc11=rc4-parisc.s
       $RC4ASM_parisc20_64=$RC4ASM_parisc11
    @@ -12,7 +12,7 @@ IF[{- !$disabled{asm} -}]
       # Now that we have defined all the arch specific variables, use the
       # appropriate one, and define the appropriate macros
       IF[$RC4ASM_{- $target{asm_arch} -}]
    -    $RC4ASM=$RC4ASM_{- $target{asm_arch} -}
    +    $RC4ASM=rc4_asm_forward.c $RC4ASM_{- $target{asm_arch} -}
         $RC4DEF=RC4_ASM
       ENDIF
     ENDIF

Add the forwarding files to the build if assembly is enabled.

### New File: `crypto/rc4/rc4_asm_forward.c`

    #include "internal/deprecated.h"
    
    #include <openssl/rc4.h>
    #include "rc4_local.h"
    #include <openssl/opensslv.h>
    #include <stdfil.h>
    
    void RC4_set_key(RC4_KEY *key, int len, const unsigned char *data)
    {
        zcheck(key, sizeof(RC4_KEY));
        zcheck_readonly(data, len);
        zunsafe_buf_call(len, "RC4_set_key", key, len, data);
    }

This sets up the RC4 key using `len` bytes of `data`.

    void RC4(RC4_KEY *key, size_t len, const unsigned char *indata,
             unsigned char *outdata)
    {
        zcheck(key, sizeof(RC4_KEY));
        zcheck_readonly(indata, len);
        zcheck(outdata, len);
        zunsafe_buf_call(len, "RC4", key, len, indata, outdata);
    }

This performs RC4 encryption for `len` bytes of data.

### New File: `crypto/rc4/rc4_md4_asm_forward.c`

    #include "internal/deprecated.h"
    
    #include <openssl/rc4.h>
    #include <openssl/md5.h>
    #include "rc4_local.h"
    #include <openssl/opensslv.h>
    #include <stdfil.h>
    
    void rc4_md5_enc(RC4_KEY *key, const void *in0, void *out,
                     MD5_CTX *ctx, const void *inp, size_t blocks)
    {
        zcheck(key, sizeof(RC4_KEY));
        zcheck(ctx, sizeof(MD5_CTX));
        zcheck_readonly(in0, zchecked_mul(blocks, MD5_CBLOCK));
        zcheck(out, zchecked_mul(blocks, MD5_CBLOCK));
        zcheck_readonly(inp, zchecked_mul(blocks, MD5_CBLOCK));
        zunsafe_call("rc4_md5_enc", key, in0, out, ctx, inp, blocks);
    }

This is the stitched RC4/MD5 implementation, which operates on MD5 blocks (64 bytes).

### Changes To `crypto/sha/build.info`

    @@ -72,7 +72,7 @@ IF[{- !$disabled{asm} -}]
       # Now that we have defined all the arch specific variables, use the
       # appropriate one, and define the appropriate macros
       IF[$KECCAK1600ASM_{- $target{asm_arch} -}]
    -    $KECCAK1600ASM=$KECCAK1600ASM_{- $target{asm_arch} -}
    +    $KECCAK1600ASM=keccak1600_asm_forward.c $KECCAK1600ASM_{- $target{asm_arch} -}
         $KECCAK1600DEF=KECCAK1600_ASM
       ENDIF
     ENDIF

Add the forwarding file for Keccak-f[1600] functions used by SHA3.

### New File: `crypto/sha/keccak1600_asm_forward.c`

    #include <openssl/e_os2.h>
    #include <string.h>
    #include <assert.h>
    #include <stdfil.h>
    
    size_t SHA3_absorb(uint64_t A[5][5], const unsigned char *inp, size_t len,
                       size_t r)
    {
        ZSAFETY_CHECK(r < (25 * sizeof(A[0][0])));
        ZSAFETY_CHECK((r % 8) == 0);
        zcheck(A, 25 * sizeof(A[0][0]));
        zcheck_readonly(inp, len);
        return zunsafe_buf_call(len, "SHA3_absorb", A, inp, len, r);
    }

This requires that `r` is an offset into `A` and `len` is in bytes.

    void SHA3_squeeze(uint64_t A[5][5], unsigned char *out, size_t len, size_t r, int next)
    {
        ZSAFETY_CHECK(r < (25 * sizeof(A[0][0])));
        ZSAFETY_CHECK((r % 8) == 0);
        zcheck(A, 25 * sizeof(A[0][0]));
        zcheck(out, len);
        zunsafe_buf_call(len, "SHA3_squeeze", A, out, len, r, next);
    }

Similar to `absorb`, but writes to `out`.

### Changes To `crypto/sha/sha256.c`

    @@ -23,6 +23,7 @@
     #include <openssl/opensslv.h>
     #include "internal/endian.h"
     #include "crypto/sha.h"
    +#include <stdfil.h>
     
     int SHA224_Init(SHA256_CTX *c)
     {

Include `<stdfil.h>`.

    @@ -123,6 +124,15 @@ void sha256_block_data_order_c(SHA256_CTX *ctx, const void *in, size_t num);
     #endif /* SHA256_ASM */
     void sha256_block_data_order(SHA256_CTX *ctx, const void *in, size_t num);
     
    +#ifdef SHA256_ASM
    +void sha256_block_data_order(SHA256_CTX *ctx, const void *in, size_t num)
    +{
    +    zcheck(ctx, sizeof(SHA256_CTX));
    +    zcheck_readonly(in, zchecked_mul(num, SHA256_CBLOCK));
    +    zunsafe_buf_call(zchecked_mul(num, SHA256_CBLOCK), "sha256_block_data_order", ctx, in, num);
    +}
    +#endif
    +
     #include "crypto/md32_common.h"
     
     #if !defined(SHA256_ASM) || defined(INCLUDE_C_SHA256)

Wraps the SHA256 assembly implementation. `num` specifies the size of the input in units of SHA256 blocks (64 bytes).

### Changes to `crypto/sha/sha512.c`

    @@ -58,6 +58,7 @@
     
     #include "internal/cryptlib.h"
     #include "crypto/sha.h"
    +#include <stdfil.h>
     
     #if defined(__i386) || defined(__i386__) || defined(_M_IX86) || \
         defined(__x86_64) || defined(_M_AMD64) || defined(_M_X64) || \

Include `<stdfil.h>`.

    @@ -156,6 +157,15 @@ void sha512_block_data_order_c(SHA512_CTX *ctx, const void *in, size_t num);
     #endif
     void sha512_block_data_order(SHA512_CTX *ctx, const void *in, size_t num);
     
    +#ifdef SHA512_ASM
    +void sha512_block_data_order(SHA512_CTX *ctx, const void *in, size_t num)
    +{
    +    zcheck(ctx, sizeof(SHA512_CTX));
    +    zcheck_readonly(in, zchecked_mul(num, SHA512_CBLOCK));
    +    zunsafe_buf_call(zchecked_mul(num, SHA512_CBLOCK), "sha512_block_data_order", ctx, in, num);
    +}
    +#endif
    +
     int SHA512_Final(unsigned char *md, SHA512_CTX *c)
     {
         unsigned char *p = (unsigned char *)c->u.p;

Wraps the SHA512 assembly implementation. `num` specifies the size of the input in units of SHA512 blocks (128 bytes).

### Changes To `crypto/whrlpool/build.info`

    @@ -6,7 +6,7 @@ IF[{- !$disabled{asm} -}]
         $WPASM_x86=wp_block.c wp-mmx.S
         $WPDEF_x86=WHIRLPOOL_ASM
       ENDIF
    -  $WPASM_x86_64=wp-x86_64.s
    +  $WPASM_x86_64=wp_asm_forward.c wp-x86_64.s
       $WPDEF_x86_64=WHIRLPOOL_ASM
     
       # Now that we have defined all the arch specific variables, use the

Add the whirlpool assembly wrapper file to the build if assembly is enabled.

### New File: `crypto/whrlpool/wp_asm_forward.c`

    #include "internal/deprecated.h"
    
    #include "internal/cryptlib.h"
    #include "wp_local.h"
    #include <string.h>
    
    #include <stdfil.h>
    
    void whirlpool_block(WHIRLPOOL_CTX *ctx, const void *inp, size_t n)
    {
        zcheck(ctx, sizeof(WHIRLPOOL_CTX));
        zcheck_readonly(inp, zchecked_mul(n, WHIRLPOOL_BBLOCK / 8));
        zunsafe_buf_call(zchecked_mul(n, WHIRLPOOL_BBLOCK / 8), "whirlpool_block", ctx, inp, n);
    }

This wraps the whirlpool hash function, where the input length is specified in units of block size. The block size constant (`WHIRLPOOL_BBLOCK`) specifies the block size in bits (512 bits, so 64 bytes).

### Changes To `crypto/x86_64cpuid.pl`

    @@ -27,14 +27,6 @@ open OUT,"| \"$^X\" \"$xlate\" $flavour \"$output\""
     				 ("%rdi","%rsi","%rdx","%rcx");	# Unix order
     
     print<<___;
    -.extern		OPENSSL_cpuid_setup
    -.hidden		OPENSSL_cpuid_setup
    -.section	.init
    -	call	OPENSSL_cpuid_setup
    -
    -.hidden	OPENSSL_ia32cap_P
    -.comm	OPENSSL_ia32cap_P,16,4
    -
     .text
     
     .globl	OPENSSL_atomic_add

This change does two things:

1. Remove the global constructor that calls `OPENSSL_cpuid_setup`, since we now have a global constructor that will call it defined in Fil-C. We need to do this because we're not providing a way for assembly code to call Fil-C and because we need to let the Fil-C runtime control when global constructors run.

2. Remove the assembly-side definitioon of `OPENSSL_ia32cap_P`. We have defined this in Fil-C instead, and used `.filc_unsafe_export` to make it visible to assembly.

The last change in this file is to remove the `OPENSSL_cleanse` function since we are defining `OPENSSL_cleanse` using `zmemset`.

    @@ -237,44 +229,6 @@ OPENSSL_ia32_cpuid:
     .cfi_endproc
     .size	OPENSSL_ia32_cpuid,.-OPENSSL_ia32_cpuid
     
    -.globl  OPENSSL_cleanse
    -.type   OPENSSL_cleanse,\@abi-omnipotent
    -.align  16
    -OPENSSL_cleanse:
    -.cfi_startproc
    -	endbranch
    -	xor	%rax,%rax
    -	cmp	\$15,$arg2
    -	jae	.Lot
    -	cmp	\$0,$arg2
    -	je	.Lret
    -.Little:
    -	mov	%al,($arg1)
    -	sub	\$1,$arg2
    -	lea	1($arg1),$arg1
    -	jnz	.Little
    -.Lret:
    -	ret
    -.align	16
    -.Lot:
    -	test	\$7,$arg1
    -	jz	.Laligned
    -	mov	%al,($arg1)
    -	lea	-1($arg2),$arg2
    -	lea	1($arg1),$arg1
    -	jmp	.Lot
    -.Laligned:
    -	mov	%rax,($arg1)
    -	lea	-8($arg2),$arg2
    -	test	\$-8,$arg2
    -	lea	8($arg1),$arg1
    -	jnz	.Laligned
    -	cmp	\$0,$arg2
    -	jne	.Little
    -	ret
    -.cfi_endproc
    -.size	OPENSSL_cleanse,.-OPENSSL_cleanse
    -
     .globl  CRYPTO_memcmp
     .type   CRYPTO_memcmp,\@abi-omnipotent
     .align  16

### Changes To `engines/e_padlock.c`

PadLock is an instruction set extension on VIA CPUs.

    @@ -24,6 +24,7 @@
     #include <openssl/rand.h>
     #include <openssl/err.h>
     #include <openssl/modes.h>
    +#include <stdfil.h>
     
     #ifndef OPENSSL_NO_PADLOCKENG

Include `<stdfil.h>`.

    @@ -214,27 +215,83 @@ struct padlock_cipher_data {
     };
     
     /* Interface to assembler module */
    -unsigned int padlock_capability(void);
    -void padlock_key_bswap(AES_KEY *key);
    -void padlock_verify_context(struct padlock_cipher_data *ctx);
    -void padlock_reload_key(void);
    -void padlock_aes_block(void *out, const void *inp,
    -                       struct padlock_cipher_data *ctx);
    -int padlock_ecb_encrypt(void *out, const void *inp,
    -                        struct padlock_cipher_data *ctx, size_t len);
    -int padlock_cbc_encrypt(void *out, const void *inp,
    -                        struct padlock_cipher_data *ctx, size_t len);
    -int padlock_cfb_encrypt(void *out, const void *inp,
    -                        struct padlock_cipher_data *ctx, size_t len);
    -int padlock_ofb_encrypt(void *out, const void *inp,
    -                        struct padlock_cipher_data *ctx, size_t len);
    -int padlock_ctr32_encrypt(void *out, const void *inp,
    -                          struct padlock_cipher_data *ctx, size_t len);
    -int padlock_xstore(void *out, int edx);
    -void padlock_sha1_oneshot(void *ctx, const void *inp, size_t len);
    -void padlock_sha1(void *ctx, const void *inp, size_t len);
    -void padlock_sha256_oneshot(void *ctx, const void *inp, size_t len);
    -void padlock_sha256(void *ctx, const void *inp, size_t len);
    +static unsigned int padlock_capability(void)
    +{
    +    return zunsafe_fast_call("padlock_capability");
    +}
    +
    +static void padlock_key_bswap(AES_KEY *key)
    +{
    +    zcheck(key, sizeof(AES_KEY));
    +    zunsafe_fast_call("padlock_key_bswap", key);
    +}
    +
    +static void padlock_reload_key(void)
    +{
    +    zunsafe_fast_call("padlock_reload_key");
    +}
    +
    +static void padlock_aes_block(void *out, const void *inp,
    +                              struct padlock_cipher_data *ctx)
    +{
    +    zcheck(out, AES_BLOCK_SIZE);
    +    zcheck_readonly(inp, AES_BLOCK_SIZE);
    +    zcheck(ctx, sizeof(struct padlock_cipher_data));
    +    zunsafe_fast_call("padlock_aes_block", out, inp, ctx);
    +}
    +
    +static int padlock_ecb_encrypt(void *out, const void *inp,
    +                               struct padlock_cipher_data *ctx, size_t len)
    +{
    +    zcheck(out, len);
    +    zcheck_readonly(inp, len);
    +    zcheck(ctx, sizeof(struct padlock_cipher_data));
    +    return zunsafe_buf_call(len, "padlock_ecb_encrypt", out, inp, ctx, len);
    +}
    +
    +static int padlock_cbc_encrypt(void *out, const void *inp,
    +                               struct padlock_cipher_data *ctx, size_t len)
    +{
    +    zcheck(out, len);
    +    zcheck_readonly(inp, len);
    +    zcheck(ctx, sizeof(struct padlock_cipher_data));
    +    return zunsafe_buf_call(len, "padlock_cbc_encrypt", out, inp, ctx, len);
    +}
    +
    +static int padlock_cfb_encrypt(void *out, const void *inp,
    +                               struct padlock_cipher_data *ctx, size_t len)
    +{
    +    zcheck(out, len);
    +    zcheck_readonly(inp, len);
    +    zcheck(ctx, sizeof(struct padlock_cipher_data));
    +    return zunsafe_buf_call(len, "padlock_cfb_encrypt", out, inp, ctx, len);
    +}
    +
    +static int padlock_ofb_encrypt(void *out, const void *inp,
    +                               struct padlock_cipher_data *ctx, size_t len)
    +{
    +    zcheck(out, len);
    +    zcheck_readonly(inp, len);
    +    zcheck(ctx, sizeof(struct padlock_cipher_data));
    +    return zunsafe_buf_call(len, "padlock_ofb_encrypt", out, inp, ctx, len);
    +}
    +
    +static int padlock_ctr32_encrypt(void *out, const void *inp,
    +                                 struct padlock_cipher_data *ctx, size_t len)
    +{
    +    zcheck(out, len);
    +    zcheck_readonly(inp, len);
    +    zcheck(ctx, sizeof(struct padlock_cipher_data));
    +    return zunsafe_buf_call(len, "padlock_ctr32_encrypt", out, inp, ctx, len);
    +}
    +
    +static int padlock_xstore(void *out, int edx)
    +{
    +    zcheck(out, 8); /* Really, the xstore might be requested to store only 4 bytes and out may point
    +                       at an int. But we don't have to be so precise since an int in Fil-C is really
    +                       16 bytes. */
    +    return zunsafe_fast_call("padlock_xstore", out, edx);
    +}
     
     /*
      * Load supported features of the CPU to see if the PadLock is available.

Wrap the assembly functions for PadLock.

It's not clear how important any of this is since I don't have a VIA CPU and I don't know anyone who does.

### Changes To `include/crypto/md32_common.h`

    @@ -101,7 +101,7 @@
     
     #ifndef PEDANTIC
     # if defined(__GNUC__) && __GNUC__>=2 && \
    -     !defined(OPENSSL_NO_ASM) && !defined(OPENSSL_NO_INLINE_ASM)
    +    !defined(OPENSSL_NO_ASM) && !defined(OPENSSL_NO_INLINE_ASM) && !defined(__FILC__)
     #  if defined(__riscv_zbb) || defined(__riscv_zbkb)
     #   if __riscv_xlen == 64
     #   undef ROTATE

Disable the inline assembly implementation of `ROTATE`.

### Changes To `include/crypto/modes.h`

    @@ -38,7 +38,7 @@ typedef unsigned char u8;
     # endif
     #endif
     
    -#if !defined(PEDANTIC) && !defined(OPENSSL_NO_ASM) && !defined(OPENSSL_NO_INLINE_ASM)
    +#if !defined(PEDANTIC) && !defined(OPENSSL_NO_ASM) && !defined(OPENSSL_NO_INLINE_ASM) && !defined(__FILC__)
     # if defined(__GNUC__) && __GNUC__>=2
     #  if defined(__x86_64) || defined(__x86_64__)
     #   define BSWAP8(x) ({ u64 ret_=(x);                   \

Disable the inline assembly implementation of `BSWAP`.

### Changes To `include/crypto/poly1305.h`

    @@ -24,11 +24,12 @@ typedef void (*poly1305_blocks_f) (void *ctx, const unsigned char *inp,
     typedef void (*poly1305_emit_f) (void *ctx, unsigned char mac[16],
                                      const unsigned int nonce[4]);
     
    +typedef double poly1305_opaque[24]; /* large enough to hold internal state, declared
    +                                     * 'double' to ensure at least 64-bit invariant
    +                                     * alignment across all platforms and
    +                                     * configurations */
     struct poly1305_context {
    -    double opaque[24];  /* large enough to hold internal state, declared
    -                         * 'double' to ensure at least 64-bit invariant
    -                         * alignment across all platforms and
    -                         * configurations */
    +    poly1305_opaque opaque;
         unsigned int nonce[4];
         unsigned char data[POLY1305_BLOCK_SIZE];
         size_t num;

Define the `poly1305_opaque` type, which we use in assembly wrappers of poly1305.

### Changes To `providers/implementations/ciphers/cipher_aes_gcm_hw.c`

    @@ -16,6 +16,7 @@
     #include "internal/deprecated.h"
     
     #include "cipher_aes_gcm.h"
    +#include <stdfil.h>
     
     static int aes_gcm_initkey(PROV_GCM_CTX *ctx, const unsigned char *key,
                                        size_t keylen)

Include `<stdfil.h>`. This is needed because of the `.inc` files that this file includes.

    @@ -26,6 +27,7 @@ static int aes_gcm_initkey(PROV_GCM_CTX *ctx, const unsigned char *key,
     # ifdef HWAES_CAPABLE
         if (HWAES_CAPABLE) {
     #  ifdef HWAES_ctr32_encrypt_blocks
    +
             GCM_HW_SET_KEY_CTR_FN(ks, HWAES_set_encrypt_key, HWAES_encrypt,
                                   HWAES_ctr32_encrypt_blocks);
     #  else

This looks like an unnecessary changes.

### Changes To `providers/implementations/ciphers/cipher_aes_gcm_hw_vaes_avx512.inc`

    @@ -19,27 +19,69 @@
     # define VAES_GCM_ENABLED
     
     /* Returns non-zero when AVX512F + VAES + VPCLMULDQD combination is available */
    -int ossl_vaes_vpclmulqdq_capable(void);
    +static int ossl_vaes_vpclmulqdq_capable(void)
    +{
    +    return zunsafe_fast_call("ossl_vaes_vpclmulqdq_capable");
    +}
     
     # define OSSL_AES_GCM_UPDATE(direction)                                 \
    +    static                                                              \
         void ossl_aes_gcm_ ## direction ## _avx512(const void *ks,          \
                                                    void *gcm128ctx,         \
                                                    unsigned int *pblocklen, \
                                                    const unsigned char *in, \
                                                    size_t len,              \
    -                                               unsigned char *out);
    +                                               unsigned char *out)      \
    +    {                                                                   \
    +        zcheck_readonly(ks, sizeof(AES_KEY));                           \
    +        zcheck(gcm128ctx, sizeof(GCM128_CONTEXT));                      \
    +        zcheck(pblocklen, sizeof(unsigned int));                        \
    +        zcheck_readonly(in, len);                                       \
    +        zcheck(out, len);                                               \
    +        zunsafe_buf_call(                                               \
    +            len, "ossl_aes_gcm_" #direction "_avx512",                  \
    +            ks, gcm128ctx, pblocklen, in, len, out);                    \
    +    }
     
     OSSL_AES_GCM_UPDATE(encrypt)
     OSSL_AES_GCM_UPDATE(decrypt)
     
    -void ossl_aes_gcm_init_avx512(const void *ks, void *gcm128ctx);
    -void ossl_aes_gcm_setiv_avx512(const void *ks, void *gcm128ctx,
    -                               const unsigned char *iv, size_t ivlen);
    -void ossl_aes_gcm_update_aad_avx512(void *gcm128ctx, const unsigned char *aad,
    -                                    size_t aadlen);
    -void ossl_aes_gcm_finalize_avx512(void *gcm128ctx, unsigned int pblocklen);
    +static void ossl_aes_gcm_init_avx512(const void *ks, void *gcm128ctx)
    +{
    +    zcheck_readonly(ks, sizeof(AES_KEY));
    +    zcheck(gcm128ctx, sizeof(GCM128_CONTEXT));
    +    zunsafe_fast_call("ossl_aes_gcm_init_avx512", ks, gcm128ctx);
    +}
    +
    +static void ossl_aes_gcm_setiv_avx512(const void *ks, void *gcm128ctx,
    +                                      const unsigned char *iv, size_t ivlen)
    +{
    +    zcheck_readonly(ks, sizeof(AES_KEY));
    +    zcheck(gcm128ctx, sizeof(GCM128_CONTEXT));
    +    zcheck_readonly(iv, ivlen);
    +    zunsafe_buf_call(ivlen, "ossl_aes_gcm_setiv_avx512", ks, gcm128ctx, iv, ivlen);
    +}
    +
    +static void ossl_aes_gcm_update_aad_avx512(void *gcm128ctx, const unsigned char *aad,
    +                                           size_t aadlen)
    +{
    +    zcheck(gcm128ctx, sizeof(GCM128_CONTEXT));
    +    zcheck_readonly(aad, aadlen);
    +    zunsafe_buf_call(aadlen, "ossl_aes_gcm_update_aad_avx512", gcm128ctx, aad, aadlen);
    +}
    +
    +static void ossl_aes_gcm_finalize_avx512(void *gcm128ctx, unsigned int pblocklen)
    +{
    +    zcheck(gcm128ctx, sizeof(GCM128_CONTEXT));
    +    zunsafe_fast_call("ossl_aes_gcm_finalize_avx512", gcm128ctx, pblocklen);
    +}
     
    -void ossl_gcm_gmult_avx512(u64 Xi[2], const void *gcm128ctx);
    +static void ossl_gcm_gmult_avx512(u64 Xi[2], const void *gcm128ctx)
    +{
    +    zcheck(Xi, sizeof(u64) * 2);
    +    zcheck_readonly(gcm128ctx, sizeof(GCM128_CONTEXT));
    +    zunsafe_fast_call("ossl_gcm_gmult_avx512", Xi, gcm128ctx);
    +}
     
     static int vaes_gcm_setkey(PROV_GCM_CTX *ctx, const unsigned char *key,
                                size_t keylen)

This wraps the AES Galois/Counter Mode implementation that uses AVX512.

### Changes To `providers/implementations/rands/seeding/rand_cpu_x86.c`

    @@ -11,6 +11,7 @@
     #include <openssl/opensslconf.h>
     #include "crypto/rand_pool.h"
     #include "prov/seeding.h"
    +#include <stdfil.h>
     
     #ifdef OPENSSL_RAND_SEED_RDCPU
     # if defined(OPENSSL_SYS_TANDEM) && defined(_TNS_X_TARGET)

I think this change is unnecessary. It's here because I used to have an assembly wrapper in this file, but later removed it.

### That's It!

That's the whole ~90KB patch to OpenSSL 3.3.1 to make it possible to use the constant-time crypto assembly code while compiling OpenSSL'c C code with Fil-C.

## Conclusion

Thanks to these changes, using OpenSSL compiled with Fil-C is a net security improvement:

- All of the C code (i.e. most of OpenSSL) is compiled with Fil-C, and so it becomes totally memory safe.

- Any code that is written in assembly is still assembled the same way as it is normally in an OpenSSL build. Therefore, we are not introducing any timing side channel regressions by using C code instead of assembly code.

It's still possible to compile OpenSSL with `no-asm` and get a fully memory-safe version with no assembly code, with the risk that the C code has timing side channels. However, I don't recommend doing that. Consider that if you examine the [OpenSSL vulnerabilities](https://openssl-library.org/news/vulnerabilities/) going back to the beginning of 2023, there is *not a single vulnerability* in Linux/X86\_64 assembly. There is one vulnerability in the Windows version of X86\_64 assembly (because Windows has a weird calling convention). There is one vulnerability in PowerPC code and one ARM vulnerability (which is admittedly sad). But there are *many* vulnerabilities in C code. Therefore, it's unlikely that using memory-unsafe assembly on Linux/X86\_64 introduces much attack surface. And it is likely that using assembly reduces the timing side-channel attack surface.
