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
#endif

JanetTable *janet_table_proto_flatten(JanetTable *t);

/* C Functions */

JANET_CORE_FN(cfun_table_new,
              "(table/new capacity)",
              "Creates a new empty table with pre-allocated memory "
              "for `capacity` entries. This means that if one knows the number of "
              "entries going into a table on creation, extra memory allocation "
              "can be avoided. "
              "Returns the new table.") {
    janet_fixarity(argc, 1);
    int32_t cap = janet_getnat(argv, 0);
    return janet_wrap_table(janet_table(cap));
}

JANET_CORE_FN(cfun_table_weak,
              "(table/weak capacity)",
              "Creates a new empty table with weak references to keys and values. Similar to `table/new`. "
              "Returns the new table.") {
    janet_fixarity(argc, 1);
    int32_t cap = janet_getnat(argv, 0);
    return janet_wrap_table(janet_table_weakkv(cap));
}

JANET_CORE_FN(cfun_table_weak_keys,
              "(table/weak-keys capacity)",
              "Creates a new empty table with weak references to keys and normal references to values. Similar to `table/new`. "
              "Returns the new table.") {
    janet_fixarity(argc, 1);
    int32_t cap = janet_getnat(argv, 0);
    return janet_wrap_table(janet_table_weakk(cap));
}

JANET_CORE_FN(cfun_table_weak_values,
              "(table/weak-values capacity)",
              "Creates a new empty table with normal references to keys and weak references to values. Similar to `table/new`. "
              "Returns the new table.") {
    janet_fixarity(argc, 1);
    int32_t cap = janet_getnat(argv, 0);
    return janet_wrap_table(janet_table_weakv(cap));
}

JANET_CORE_FN(cfun_table_getproto,
              "(table/getproto tab)",
              "Get the prototype table of a table. Returns nil if the table "
              "has no prototype, otherwise returns the prototype.") {
    janet_fixarity(argc, 1);
    JanetTable *t = janet_gettable(argv, 0);
    return t->proto
           ? janet_wrap_table(t->proto)
           : janet_wrap_nil();
}

JANET_CORE_FN(cfun_table_setproto,
              "(table/setproto tab proto)",
              "Set the prototype of a table. Returns the original table `tab`.") {
    janet_fixarity(argc, 2);
    JanetTable *table = janet_gettable(argv, 0);
    JanetTable *proto = NULL;
    if (!janet_checktype(argv[1], JANET_NIL)) {
        proto = janet_gettable(argv, 1);
    }
    table->proto = proto;
    return argv[0];
}

JANET_CORE_FN(cfun_table_tostruct,
              "(table/to-struct tab &opt proto)",
              "Return a struct based on a table `tab`. If given, "
              "the optional argument `proto` specifies the new "
              "struct's prototype. Note that if `proto` is not "
              "specified, the new struct will not have a "
              "prototype.") {
    janet_arity(argc, 1, 2);
    JanetTable *t = janet_gettable(argv, 0);
    JanetStruct proto = janet_optstruct(argv, argc, 1, NULL);
    JanetStruct st = janet_table_to_struct(t);
    janet_struct_proto(st) = proto;
    return janet_wrap_struct(st);
}

JANET_CORE_FN(cfun_table_rawget,
              "(table/rawget tab key)",
              "Gets a value from a table `tab` without looking at the prototype table. "
              "If `tab` does not contain the key directly, the function will return "
              "nil without checking the prototype. Returns the value in the table.") {
    janet_fixarity(argc, 2);
    JanetTable *table = janet_gettable(argv, 0);
    return janet_table_rawget(table, argv[1]);
}

JANET_CORE_FN(cfun_table_clone,
              "(table/clone tab)",
              "Create a copy of a table. Updates to the new table will not change the old table, "
              "and vice versa.") {
    janet_fixarity(argc, 1);
    JanetTable *table = janet_gettable(argv, 0);
    return janet_wrap_table(janet_table_clone(table));
}

JANET_CORE_FN(cfun_table_clear,
              "(table/clear tab)",
              "Remove all key-value pairs in a table and return the modified table `tab`.") {
    janet_fixarity(argc, 1);
    JanetTable *table = janet_gettable(argv, 0);
    janet_table_clear(table);
    return janet_wrap_table(table);
}

JANET_CORE_FN(cfun_table_proto_flatten,
              "(table/proto-flatten tab)",
              "Create a new table that is the result of merging all prototypes into a new table.") {
    janet_fixarity(argc, 1);
    JanetTable *table = janet_gettable(argv, 0);
    return janet_wrap_table(janet_table_proto_flatten(table));
}

/* Load the table module */
void janet_lib_table(JanetTable *env) {
    JanetRegExt table_cfuns[] = {
        JANET_CORE_REG("table/new", cfun_table_new),
        JANET_CORE_REG("table/weak", cfun_table_weak),
        JANET_CORE_REG("table/weak-keys", cfun_table_weak_keys),
        JANET_CORE_REG("table/weak-values", cfun_table_weak_values),
        JANET_CORE_REG("table/to-struct", cfun_table_tostruct),
        JANET_CORE_REG("table/getproto", cfun_table_getproto),
        JANET_CORE_REG("table/setproto", cfun_table_setproto),
        JANET_CORE_REG("table/rawget", cfun_table_rawget),
        JANET_CORE_REG("table/clone", cfun_table_clone),
        JANET_CORE_REG("table/clear", cfun_table_clear),
        JANET_CORE_REG("table/proto-flatten", cfun_table_proto_flatten),
        JANET_REG_END
    };
    janet_core_cfuns_ext(env, NULL, table_cfuns);
}
