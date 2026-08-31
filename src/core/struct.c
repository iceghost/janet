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
#include <math.h>
#endif

void janet_struct_put_ext(JanetKV *st, Janet key, Janet value, int replace);

/* C Functions */

JANET_CORE_FN(cfun_struct_with_proto,
              "(struct/with-proto proto & kvs)",
              "Create a struct using the `proto` argument as the struct's "
              "prototype. `kvs` are as in the `struct` function.") {
    janet_arity(argc, 1, -1);
    JanetStruct proto = janet_optstruct(argv, argc, 0, NULL);
    if (!(argc & 1))
        janet_panic("expected odd number of arguments");
    JanetKV *st = janet_struct_begin(argc / 2);
    for (int32_t i = 1; i < argc; i += 2) {
        janet_struct_put(st, argv[i], argv[i + 1]);
    }
    janet_struct_proto(st) = proto;
    return janet_wrap_struct(janet_struct_end(st));
}

JANET_CORE_FN(cfun_struct_getproto,
              "(struct/getproto st)",
              "Return the prototype of a struct, or nil if it doesn't have one.") {
    janet_fixarity(argc, 1);
    JanetStruct st = janet_getstruct(argv, 0);
    return janet_struct_proto(st)
           ? janet_wrap_struct(janet_struct_proto(st))
           : janet_wrap_nil();
}

JANET_CORE_FN(cfun_struct_flatten,
              "(struct/proto-flatten st)",
              "Convert a struct with prototypes to a struct with no prototypes by merging "
              "all key value pairs from recursive prototypes into one new struct.") {
    janet_fixarity(argc, 1);
    JanetStruct st = janet_getstruct(argv, 0);

    /* get an upper bounds on the number of items in the final struct */
    int64_t pair_count = 0;
    JanetStruct cursor = st;
    while (cursor) {
        pair_count += janet_struct_length(cursor);
        cursor = janet_struct_proto(cursor);
    }

    if (pair_count > INT32_MAX) {
        janet_panic("struct too large");
    }

    JanetKV *accum = janet_struct_begin((int32_t) pair_count);
    cursor = st;
    while (cursor) {
        for (int32_t i = 0; i < janet_struct_capacity(cursor); i++) {
            const JanetKV *kv = cursor + i;
            if (!janet_checktype(kv->key, JANET_NIL)) {
                janet_struct_put_ext(accum, kv->key, kv->value, 0);
            }
        }
        cursor = janet_struct_proto(cursor);
    }
    return janet_wrap_struct(janet_struct_end(accum));
}

JANET_CORE_FN(cfun_struct_to_table,
              "(struct/to-table st &opt recursive)",
              "Convert a struct to a table. If recursive is true, also convert the "
              "table's prototypes into the new struct's prototypes as well.") {
    janet_arity(argc, 1, 2);
    JanetStruct st = janet_getstruct(argv, 0);
    int recursive = argc > 1 && janet_truthy(argv[1]);
    JanetTable *tab = NULL;
    JanetStruct cursor = st;
    JanetTable *tab_cursor = tab;
    do {
        if (tab) {
            tab_cursor->proto = janet_table(janet_struct_length(cursor));
            tab_cursor = tab_cursor->proto;
        } else {
            tab = janet_table(janet_struct_length(cursor));
            tab_cursor = tab;
        }
        /* TODO - implement as memcpy since struct memory should be compatible
         * with table memory */
        for (int32_t i = 0; i < janet_struct_capacity(cursor); i++) {
            const JanetKV *kv = cursor + i;
            if (!janet_checktype(kv->key, JANET_NIL)) {
                janet_table_put(tab_cursor, kv->key, kv->value);
            }
        }
        cursor = janet_struct_proto(cursor);
    } while (recursive && cursor);
    return janet_wrap_table(tab);
}

JANET_CORE_FN(cfun_struct_rawget,
              "(struct/rawget st key)",
              "Gets a value from a struct `st` without looking at the prototype struct. "
              "If `st` does not contain the key directly, the function will return "
              "nil without checking the prototype. Returns the value in the struct.") {
    janet_fixarity(argc, 2);
    JanetStruct st = janet_getstruct(argv, 0);
    return janet_struct_rawget(st, argv[1]);
}

/* Load the struct module */
void janet_lib_struct(JanetTable *env) {
    JanetRegExt struct_cfuns[] = {
        JANET_CORE_REG("struct/with-proto", cfun_struct_with_proto),
        JANET_CORE_REG("struct/getproto", cfun_struct_getproto),
        JANET_CORE_REG("struct/proto-flatten", cfun_struct_flatten),
        JANET_CORE_REG("struct/to-table", cfun_struct_to_table),
        JANET_CORE_REG("struct/rawget", cfun_struct_rawget),
        JANET_REG_END
    };
    janet_core_cfuns_ext(env, NULL, struct_cfuns);
}
