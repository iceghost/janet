/*
* Copyright (c) 2026 Calvin Rose
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to
* deal in the Software without restriction, including without limitation the
* rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
* sell copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in
* all copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
* IN THE SOFTWARE.
*/

#ifndef JANET_AMALG
#include "features.h"
#include <janet.h>
#include "gc.h"
#include "util.h"
#include "state.h"
#endif

void janet_buffer_trim(JanetBuffer *buffer);

/* C functions */

JANET_CORE_FN(cfun_buffer_new,
              "(buffer/new capacity)",
              "Creates a new, empty buffer with enough backing memory for `capacity` bytes. "
              "Returns a new buffer of length 0.") {
    janet_fixarity(argc, 1);
    int32_t cap = janet_getinteger(argv, 0);
    JanetBuffer *buffer = janet_buffer(cap);
    return janet_wrap_buffer(buffer);
}

JANET_CORE_FN(cfun_buffer_new_filled,
              "(buffer/new-filled count &opt byte)",
              "Creates a new buffer of length `count` filled with `byte`. By default, `byte` is 0. "
              "Returns the new buffer.") {
    janet_arity(argc, 1, 2);
    int32_t count = janet_getinteger(argv, 0);
    if (count < 0) count = 0;
    int32_t byte = 0;
    if (argc == 2) {
        byte = janet_getinteger(argv, 1) & 0xFF;
    }
    JanetBuffer *buffer = janet_buffer(count);
    if (buffer->data && count > 0)
        memset(buffer->data, byte, count);
    buffer->count = count;
    return janet_wrap_buffer(buffer);
}

JANET_CORE_FN(cfun_buffer_frombytes,
              "(buffer/from-bytes & byte-vals)",
              "Creates a buffer from integer parameters with byte values. All integers "
              "will be coerced to the range of 1 byte 0-255.") {
    int32_t i;
    JanetBuffer *buffer = janet_buffer(argc);
    for (i = 0; i < argc; i++) {
        int32_t c = janet_getinteger(argv, i);
        buffer->data[i] = c & 0xFF;
    }
    buffer->count = argc;
    return janet_wrap_buffer(buffer);
}

JANET_CORE_FN(cfun_buffer_fill,
              "(buffer/fill buffer &opt byte)",
              "Fill up a buffer with bytes, defaulting to 0s. Does not change the buffer's length. "
              "Returns the modified buffer.") {
    janet_arity(argc, 1, 2);
    JanetBuffer *buffer = janet_getbuffer(argv, 0);
    int32_t byte = 0;
    if (argc == 2) {
        byte = janet_getinteger(argv, 1) & 0xFF;
    }
    if (buffer->count) {
        memset(buffer->data, byte, buffer->count);
    }
    return argv[0];
}

JANET_CORE_FN(cfun_buffer_trim,
              "(buffer/trim buffer)",
              "Set the backing capacity of the buffer to the current length of the buffer. Returns the "
              "modified buffer.") {
    janet_fixarity(argc, 1);
    JanetBuffer *buffer = janet_getbuffer(argv, 0);
    janet_buffer_trim(buffer);
    return argv[0];
}

JANET_CORE_FN(cfun_buffer_u8,
              "(buffer/push-byte buffer & xs)",
              "Append bytes to a buffer. Returns the modified buffer. "
              "Expands the buffer as necessary. Throws an error if size limit is exceeded.") {
    int32_t i;
    janet_arity(argc, 1, -1);
    JanetBuffer *buffer = janet_getbuffer(argv, 0);
    for (i = 1; i < argc; i++) {
        janet_buffer_push_u8(buffer, (uint8_t)(janet_getinteger(argv, i) & 0xFF));
    }
    return argv[0];
}

JANET_CORE_FN(cfun_buffer_word,
              "(buffer/push-word buffer & xs)",
              "Append machine words to a buffer. The 4 bytes of the integer are appended "
              "in twos complement, little endian order, unsigned for all x. Returns the modified buffer. "
              "Expands the buffer as necessary. Throws an error if size limit is exceeded.") {
    int32_t i;
    janet_arity(argc, 1, -1);
    JanetBuffer *buffer = janet_getbuffer(argv, 0);
    for (i = 1; i < argc; i++) {
        double number = janet_getnumber(argv, i);
        uint32_t word = (uint32_t) number;
        if (word != number)
            janet_panicf("cannot convert %v to machine word", argv[i]);
        janet_buffer_push_u32(buffer, word);
    }
    return argv[0];
}

JANET_CORE_FN(cfun_buffer_chars,
              "(buffer/push-string buffer & xs)",
              "Push byte sequences onto the end of a buffer. "
              "Will accept any of strings, keywords, symbols, and buffers. "
              "Returns the modified buffer. "
              "Expands the buffer as necessary. Throws an error if size limit is exceeded.") {
    int32_t i;
    janet_arity(argc, 1, -1);
    JanetBuffer *buffer = janet_getbuffer(argv, 0);
    for (i = 1; i < argc; i++) {
        JanetByteView view = janet_getbytes(argv, i);
        if (view.bytes == buffer->data) {
            janet_buffer_ensure(buffer, buffer->count + view.len, 2);
            view.bytes = buffer->data;
        }
        janet_buffer_push_bytes(buffer, view.bytes, view.len);
    }
    return argv[0];
}

static int should_reverse_bytes(const Janet *argv, int32_t argc) {
    JanetKeyword order_kw = janet_getkeyword(argv, argc);
    if (!janet_cstrcmp(order_kw, "le")) {
#if JANET_BIG_ENDIAN
        return 1;
#endif
    } else if (!janet_cstrcmp(order_kw, "be")) {
#if JANET_LITTLE_ENDIAN
        return 1;
#endif
    } else if (!janet_cstrcmp(order_kw, "native")) {
        return 0;
    } else {
        janet_panicf("expected endianness :le, :be or :native, got %v", argv[1]);
    }
    return 0;
}

static void reverse_u32(uint8_t bytes[4]) {
    uint8_t temp;
    temp = bytes[3];
    bytes[3] = bytes[0];
    bytes[0] = temp;
    temp = bytes[2];
    bytes[2] = bytes[1];
    bytes[1] = temp;
}

static void reverse_u64(uint8_t bytes[8]) {
    uint8_t temp;
    temp = bytes[7];
    bytes[7] = bytes[0];
    bytes[0] = temp;
    temp = bytes[6];
    bytes[6] = bytes[1];
    bytes[1] = temp;
    temp = bytes[5];
    bytes[5] = bytes[2];
    bytes[2] = temp;
    temp = bytes[4];
    bytes[4] = bytes[3];
    bytes[3] = temp;
}

JANET_CORE_FN(cfun_buffer_push_uint16,
              "(buffer/push-uint16 buffer order data)",
              "Push a 16 bit unsigned integer data onto the end of the buffer. "
              "Returns the modified buffer."
              "Expands the buffer as necessary. Throws an error if size limit is exceeded.") {
    janet_fixarity(argc, 3);
    JanetBuffer *buffer = janet_getbuffer(argv, 0);
    int reverse = should_reverse_bytes(argv, 1);
    uint16_t data = janet_getuinteger16(argv, 2);
    uint8_t bytes[sizeof(data)];
    memcpy(bytes, &data, sizeof(bytes));
    if (reverse) {
        uint8_t temp = bytes[1];
        bytes[1] = bytes[0];
        bytes[0] = temp;
    }
    janet_buffer_push_bytes(buffer, bytes, sizeof(bytes));
    return argv[0];
}

JANET_CORE_FN(cfun_buffer_push_uint32,
              "(buffer/push-uint32 buffer order data)",
              "Push a 32 bit unsigned integer data onto the end of the buffer. "
              "Returns the modified buffer."
              "Expands the buffer as necessary. Throws an error if size limit is exceeded.") {
    janet_fixarity(argc, 3);
    JanetBuffer *buffer = janet_getbuffer(argv, 0);
    int reverse = should_reverse_bytes(argv, 1);
    uint32_t data = janet_getuinteger(argv, 2);
    uint8_t bytes[sizeof(data)];
    memcpy(bytes, &data, sizeof(bytes));
    if (reverse)
        reverse_u32(bytes);
    janet_buffer_push_bytes(buffer, bytes, sizeof(bytes));
    return argv[0];
}

JANET_CORE_FN(cfun_buffer_push_uint64,
              "(buffer/push-uint64 buffer order data)",
              "Push a 64 bit unsigned integer data onto the end of the buffer. "
              "Returns the modified buffer."
              "Expands the buffer as necessary. Throws an error if size limit is exceeded.") {
    janet_fixarity(argc, 3);
    JanetBuffer *buffer = janet_getbuffer(argv, 0);
    int reverse = should_reverse_bytes(argv, 1);
    uint64_t data = janet_getuinteger64(argv, 2);
    uint8_t bytes[sizeof(data)];
    memcpy(bytes, &data, sizeof(bytes));
    if (reverse)
        reverse_u64(bytes);
    janet_buffer_push_bytes(buffer, bytes, sizeof(bytes));
    return argv[0];
}

JANET_CORE_FN(cfun_buffer_push_float32,
              "(buffer/push-float32 buffer order data)",
              "Push the underlying bytes of a 32 bit float data onto the end of the buffer. "
              "Returns the modified buffer."
              "Expands the buffer as necessary. Throws an error if size limit is exceeded.") {
    janet_fixarity(argc, 3);
    JanetBuffer *buffer = janet_getbuffer(argv, 0);
    int reverse = should_reverse_bytes(argv, 1);
    float data = (float) janet_getnumber(argv, 2);
    uint8_t bytes[sizeof(data)];
    memcpy(bytes, &data, sizeof(bytes));
    if (reverse)
        reverse_u32(bytes);
    janet_buffer_push_bytes(buffer, bytes, sizeof(bytes));
    return argv[0];
}

JANET_CORE_FN(cfun_buffer_push_float64,
              "(buffer/push-float64 buffer order data)",
              "Push the underlying bytes of a 64 bit float data onto the end of the buffer. "
              "Returns the modified buffer."
              "Expands the buffer as necessary. Throws an error if size limit is exceeded.") {
    janet_fixarity(argc, 3);
    JanetBuffer *buffer = janet_getbuffer(argv, 0);
    int reverse = should_reverse_bytes(argv, 1);
    double data = janet_getnumber(argv, 2);
    uint8_t bytes[sizeof(data)];
    memcpy(bytes, &data, sizeof(bytes));
    if (reverse)
        reverse_u64(bytes);
    janet_buffer_push_bytes(buffer, bytes, sizeof(bytes));
    return argv[0];
}

static void buffer_push_impl(JanetBuffer *buffer, Janet *argv, int32_t argc_offset, int32_t argc) {
    for (int32_t i = argc_offset; i < argc; i++) {
        if (janet_checktype(argv[i], JANET_NUMBER)) {
            janet_buffer_push_u8(buffer, (uint8_t)(janet_getinteger(argv, i) & 0xFF));
        } else {
            JanetByteView view = janet_getbytes(argv, i);
            if (view.bytes == buffer->data) {
                janet_buffer_ensure(buffer, buffer->count + view.len, 2);
                view.bytes = buffer->data;
            }
            janet_buffer_push_bytes(buffer, view.bytes, view.len);
        }
    }
}

JANET_CORE_FN(cfun_buffer_push_at,
              "(buffer/push-at buffer index & xs)",
              "Same as buffer/push, but copies the new data into the buffer "
              " at index `index`.") {
    janet_arity(argc, 2, -1);
    JanetBuffer *buffer = janet_getbuffer(argv, 0);
    int32_t index = janet_getinteger(argv, 1);
    int32_t old_count = buffer->count;
    if (index < 0 || index > old_count) {
        janet_panicf("index out of range [0, %d)", old_count);
    }
    buffer->count = index;
    buffer_push_impl(buffer, argv, 2, argc);
    if (buffer->count < old_count) {
        buffer->count = old_count;
    }
    return argv[0];
}

JANET_CORE_FN(cfun_buffer_push,
              "(buffer/push buffer & xs)",
              "Push both individual bytes and byte sequences to a buffer. For each x in xs, "
              "push the byte if x is an integer, otherwise push the bytesequence to the buffer. "
              "Thus, this function behaves like both `buffer/push-string` and `buffer/push-byte`. "
              "Returns the modified buffer. "
              "Expands the buffer as necessary. Throws an error if size limit is exceeded.") {
    janet_arity(argc, 1, -1);
    JanetBuffer *buffer = janet_getbuffer(argv, 0);
    buffer_push_impl(buffer, argv, 1, argc);
    return argv[0];
}

JANET_CORE_FN(cfun_buffer_clear,
              "(buffer/clear buffer)",
              "Sets the size of a buffer to 0 and empties it. The buffer retains "
              "its memory so it can be efficiently refilled. Returns the modified buffer.") {
    janet_fixarity(argc, 1);
    JanetBuffer *buffer = janet_getbuffer(argv, 0);
    buffer->count = 0;
    return argv[0];
}

JANET_CORE_FN(cfun_buffer_popn,
              "(buffer/popn buffer n)",
              "Removes the last `n` bytes from the buffer. Returns the modified buffer.") {
    janet_fixarity(argc, 2);
    JanetBuffer *buffer = janet_getbuffer(argv, 0);
    int32_t n = janet_getinteger(argv, 1);
    if (n < 0) janet_panic("n must be non-negative");
    if (buffer->count < n) {
        buffer->count = 0;
    } else {
        buffer->count -= n;
    }
    return argv[0];
}

JANET_CORE_FN(cfun_buffer_slice,
              "(buffer/slice bytes &opt start end)",
              "Takes a slice of a byte sequence from `start` to `end`. The range is half open, "
              "[start, end). Indexes can also be negative, indicating indexing from the end of the "
              "end of the array. By default, `start` is 0 and `end` is the length of the buffer. "
              "Returns a new buffer.") {
    JanetByteView view = janet_getbytes(argv, 0);
    JanetRange range = janet_getslice(argc, argv);
    JanetBuffer *buffer = janet_buffer(range.end - range.start);
    if (buffer->data)
        memcpy(buffer->data, view.bytes + range.start, range.end - range.start);
    buffer->count = range.end - range.start;
    return janet_wrap_buffer(buffer);
}

static void bitloc(int32_t argc, Janet *argv, JanetBuffer **b, int32_t *index, int *bit) {
    janet_fixarity(argc, 2);
    JanetBuffer *buffer = janet_getbuffer(argv, 0);
    double x = janet_getnumber(argv, 1);
    int64_t bitindex = (int64_t) x;
    int64_t byteindex = bitindex >> 3;
    int which_bit = bitindex & 7;
    if (bitindex != x || bitindex < 0 || byteindex >= buffer->count)
        janet_panicf("invalid bit index %v", argv[1]);
    *b = buffer;
    *index = (int32_t) byteindex;
    *bit = which_bit;
}

JANET_CORE_FN(cfun_buffer_bitset,
              "(buffer/bit-set buffer index)",
              "Sets the bit at the given bit-index. Returns the buffer.") {
    int bit;
    int32_t index;
    JanetBuffer *buffer;
    bitloc(argc, argv, &buffer, &index, &bit);
    buffer->data[index] |= 1 << bit;
    return argv[0];
}

JANET_CORE_FN(cfun_buffer_bitclear,
              "(buffer/bit-clear buffer index)",
              "Clears the bit at the given bit-index. Returns the buffer.") {
    int bit;
    int32_t index;
    JanetBuffer *buffer;
    bitloc(argc, argv, &buffer, &index, &bit);
    buffer->data[index] &= ~(1 << bit);
    return argv[0];
}

JANET_CORE_FN(cfun_buffer_bitget,
              "(buffer/bit buffer index)",
              "Gets the bit at the given bit-index. Returns true if the bit is set, false if not.") {
    int bit;
    int32_t index;
    JanetBuffer *buffer;
    bitloc(argc, argv, &buffer, &index, &bit);
    return janet_wrap_boolean(buffer->data[index] & (1 << bit));
}

JANET_CORE_FN(cfun_buffer_bittoggle,
              "(buffer/bit-toggle buffer index)",
              "Toggles the bit at the given bit index in buffer. Returns the buffer.") {
    int bit;
    int32_t index;
    JanetBuffer *buffer;
    bitloc(argc, argv, &buffer, &index, &bit);
    buffer->data[index] ^= (1 << bit);
    return argv[0];
}

JANET_CORE_FN(cfun_buffer_blit,
              "(buffer/blit dest src &opt dest-start src-start src-end)",
              "Insert the contents of `src` into `dest`. Can optionally take indices that "
              "indicate which part of `src` to copy into which part of `dest`. Indices can be "
              "negative in order to index from the end of `src` or `dest`. Returns `dest`.") {
    janet_arity(argc, 2, 5);
    JanetBuffer *dest = janet_getbuffer(argv, 0);
    JanetByteView src = janet_getbytes(argv, 1);
    int same_buf = src.bytes == dest->data;
    int32_t offset_dest = 0;
    int32_t offset_src = 0;
    if (argc > 2 && !janet_checktype(argv[2], JANET_NIL))
        offset_dest = janet_gethalfrange(argv, 2, dest->count, "dest-start");
    if (argc > 3 && !janet_checktype(argv[3], JANET_NIL))
        offset_src = janet_gethalfrange(argv, 3, src.len, "src-start");
    int32_t length_src;
    if (argc > 4) {
        int32_t src_end = src.len;
        if (!janet_checktype(argv[4], JANET_NIL))
            src_end = janet_gethalfrange(argv, 4, src.len, "src-end");
        length_src = src_end - offset_src;
        if (length_src < 0) length_src = 0;
    } else {
        length_src = src.len - offset_src;
    }
    int64_t last = (int64_t) offset_dest + length_src;
    if (last > INT32_MAX)
        janet_panic("buffer blit out of range");
    int32_t last32 = (int32_t) last;
    janet_buffer_ensure(dest, last32, 2);
    if (last32 > dest->count) dest->count = last32;
    if (length_src) {
        if (same_buf) {
            /* janet_buffer_ensure may have invalidated src */
            src.bytes = dest->data;
            memmove(dest->data + offset_dest, src.bytes + offset_src, length_src);
        } else {
            memcpy(dest->data + offset_dest, src.bytes + offset_src, length_src);
        }
    }
    return argv[0];
}

JANET_CORE_FN(cfun_buffer_format,
              "(buffer/format buffer format & args)",
              "Snprintf like functionality for printing values into a buffer. Returns "
              "the modified buffer.") {
    janet_arity(argc, 2, -1);
    JanetBuffer *buffer = janet_getbuffer(argv, 0);
    const char *strfrmt = (const char *) janet_getstring(argv, 1);
    janet_buffer_format(buffer, strfrmt, 1, argc, argv);
    return argv[0];
}

JANET_CORE_FN(cfun_buffer_format_at,
              "(buffer/format-at buffer at format & args)",
              "Snprintf like functionality for printing values into a buffer. Returns "
              "the modified buffer.") {
    janet_arity(argc, 2, -1);
    JanetBuffer *buffer = janet_getbuffer(argv, 0);
    int32_t at = janet_getinteger(argv, 1);
    if (at < 0) {
        at += buffer->count + 1;
    }
    if (at > buffer->count || at < 0) janet_panicf("expected index at to be in range [0, %d), got %d", buffer->count, at);
    int32_t oldcount = buffer->count;
    buffer->count = at;
    const char *strfrmt = (const char *) janet_getstring(argv, 2);
    janet_buffer_format(buffer, strfrmt, 2, argc, argv);
    if (buffer->count < oldcount) {
        buffer->count = oldcount;
    }
    return argv[0];
}

void janet_lib_buffer(JanetTable *env) {
    JanetRegExt buffer_cfuns[] = {
        JANET_CORE_REG("buffer/new", cfun_buffer_new),
        JANET_CORE_REG("buffer/new-filled", cfun_buffer_new_filled),
        JANET_CORE_REG("buffer/from-bytes", cfun_buffer_frombytes),
        JANET_CORE_REG("buffer/fill", cfun_buffer_fill),
        JANET_CORE_REG("buffer/trim", cfun_buffer_trim),
        JANET_CORE_REG("buffer/push-byte", cfun_buffer_u8),
        JANET_CORE_REG("buffer/push-word", cfun_buffer_word),
        JANET_CORE_REG("buffer/push-string", cfun_buffer_chars),
        JANET_CORE_REG("buffer/push-uint16", cfun_buffer_push_uint16),
        JANET_CORE_REG("buffer/push-uint32", cfun_buffer_push_uint32),
        JANET_CORE_REG("buffer/push-uint64", cfun_buffer_push_uint64),
        JANET_CORE_REG("buffer/push-float32", cfun_buffer_push_float32),
        JANET_CORE_REG("buffer/push-float64", cfun_buffer_push_float64),
        JANET_CORE_REG("buffer/push", cfun_buffer_push),
        JANET_CORE_REG("buffer/push-at", cfun_buffer_push_at),
        JANET_CORE_REG("buffer/popn", cfun_buffer_popn),
        JANET_CORE_REG("buffer/clear", cfun_buffer_clear),
        JANET_CORE_REG("buffer/slice", cfun_buffer_slice),
        JANET_CORE_REG("buffer/bit-set", cfun_buffer_bitset),
        JANET_CORE_REG("buffer/bit-clear", cfun_buffer_bitclear),
        JANET_CORE_REG("buffer/bit", cfun_buffer_bitget),
        JANET_CORE_REG("buffer/bit-toggle", cfun_buffer_bittoggle),
        JANET_CORE_REG("buffer/blit", cfun_buffer_blit),
        JANET_CORE_REG("buffer/format", cfun_buffer_format),
        JANET_CORE_REG("buffer/format-at", cfun_buffer_format_at),
        JANET_REG_END
    };
    janet_core_cfuns_ext(env, NULL, buffer_cfuns);
}
