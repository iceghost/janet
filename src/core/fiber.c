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
#include "fiber.h"
#include "state.h"
#include "gc.h"
#include "util.h"
#endif

static void fiber_reset(JanetFiber *fiber) {
    fiber->maxstack = JANET_STACK_MAX;
    fiber->frame = 0;
    fiber->stackstart = JANET_FRAME_SIZE;
    fiber->stacktop = JANET_FRAME_SIZE;
    fiber->child = NULL;
    fiber->flags = JANET_FIBER_MASK_YIELD | JANET_FIBER_RESUME_NO_USEVAL | JANET_FIBER_RESUME_NO_SKIP;
    fiber->env = NULL;
    fiber->last_value = janet_wrap_nil();
#ifdef JANET_EV
    fiber->sched_id = 0;
    fiber->ev_callback = NULL;
    fiber->ev_state = NULL;
    fiber->ev_stream = NULL;
    fiber->supervisor_channel = NULL;
#endif
    janet_fiber_set_status(fiber, JANET_STATUS_NEW);
}

static JanetFiber *fiber_alloc(int32_t capacity) {
    Janet *data;
    JanetFiber *fiber = janet_gcalloc(JANET_MEMORY_FIBER, sizeof(JanetFiber));
    if (capacity < 32) {
        capacity = 32;
    }
    fiber->capacity = capacity;
    data = array_allocate(sizeof(Janet), capacity);
    if (NULL == data) {
        JANET_OUT_OF_MEMORY;
    }
    janet_vm.next_collection += sizeof(Janet) * capacity;
    fiber->data = data;
    return fiber;
}

/* Create a new fiber with argn values on the stack by reusing a fiber. */
JanetFiber *janet_fiber_reset(JanetFiber *fiber, JanetFunction *callee, int32_t argc, const Janet *argv) {
    int32_t newstacktop;
    fiber_reset(fiber);
    if (argc) {
        newstacktop = fiber->stacktop + argc;
        if (newstacktop >= fiber->capacity) {
            janet_fiber_setcapacity(fiber, 2 * newstacktop);
        }
        if (argv) {
            memcpy(fiber->data + fiber->stacktop, argv, argc * sizeof(Janet));
        } else {
            /* If argv not given, fill with nil */
            for (int32_t i = 0; i < argc; i++) {
                fiber->data[fiber->stacktop + i] = janet_wrap_nil();
            }
        }
        fiber->stacktop = newstacktop;
    }
    /* Don't panic on failure since we use this to implement janet_pcall */
    if (janet_fiber_funcframe(fiber, callee)) return NULL;
    janet_fiber_frame(fiber)->flags |= JANET_STACKFRAME_ENTRANCE;
#ifdef JANET_EV
    fiber->supervisor_channel = NULL;
#endif
    return fiber;
}

/* Create a new fiber with argn values on the stack. */
JanetFiber *janet_fiber(JanetFunction *callee, int32_t capacity, int32_t argc, const Janet *argv) {
    return janet_fiber_reset(fiber_alloc(capacity), callee, argc, argv);
}

/* CFuns */

JANET_CORE_FN(cfun_fiber_getenv,
              "(fiber/getenv fiber)",
              "Gets the environment for a fiber. Returns nil if no such table is "
              "set yet.") {
    janet_fixarity(argc, 1);
    JanetFiber *fiber = janet_getfiber(argv, 0);
    return fiber->env ?
           janet_wrap_table(fiber->env) :
           janet_wrap_nil();
}

JANET_CORE_FN(cfun_fiber_setenv,
              "(fiber/setenv fiber table)",
              "Sets the environment table for a fiber. Set to nil to remove the current "
              "environment.") {
    janet_fixarity(argc, 2);
    JanetFiber *fiber = janet_getfiber(argv, 0);
    if (janet_checktype(argv[1], JANET_NIL)) {
        fiber->env = NULL;
    } else {
        fiber->env = janet_gettable(argv, 1);
    }
    return argv[0];
}

JANET_CORE_FN(cfun_fiber_new,
              "(fiber/new func &opt sigmask env)",
              "Create a new fiber with function body func. Can optionally "
              "take a set of signals `sigmask` to capture from child fibers, "
              "and an environment table `env`. The mask is specified as a keyword where each character "
              "is used to indicate a signal to block. If the ev module is enabled, and "
              "this fiber is used as an argument to `ev/go`, these \"blocked\" signals "
              "will result in messages being sent to the supervisor channel. "
              "The default sigmask is :y. "
              "For example,\n\n"
              "    (fiber/new myfun :e123)\n\n"
              "blocks error signals and user signals 1, 2 and 3. The signals are "
              "as follows:\n\n"
              "* :a - block all signals\n"
              "* :d - block debug signals\n"
              "* :e - block error signals\n"
              "* :t - block termination signals: error + user[0-4]\n"
              "* :u - block user signals\n"
              "* :y - block yield signals\n"
              "* :w - block await signals (user9)\n"
              "* :r - block interrupt signals (user8)\n"
              "* :0-9 - block a specific user signal\n\n"
              "The sigmask argument also can take environment flags. If any mutually "
              "exclusive flags are present, the last flag takes precedence.\n\n"
              "* :i - inherit the environment from the current fiber\n"
              "* :p - the environment table's prototype is the current environment table") {
    janet_arity(argc, 1, 3);
    JanetFunction *func = janet_getfunction(argv, 0);
    JanetFiber *fiber;
    if (func->def->min_arity > 1) {
        janet_panicf("fiber function must accept 0 or 1 arguments");
    }
    fiber = janet_fiber(func, 64, func->def->min_arity, NULL);
    janet_assert(fiber != NULL, "bad fiber arity check");
    if (argc == 3 && !janet_checktype(argv[2], JANET_NIL)) {
        fiber->env = janet_gettable(argv, 2);
    }
    if (argc >= 2) {
        int32_t i;
        JanetByteView view = janet_getbytes(argv, 1);
        fiber->flags = JANET_FIBER_RESUME_NO_USEVAL | JANET_FIBER_RESUME_NO_SKIP;
        janet_fiber_set_status(fiber, JANET_STATUS_NEW);
        for (i = 0; i < view.len; i++) {
            if (view.bytes[i] >= '0' && view.bytes[i] <= '9') {
                fiber->flags |= JANET_FIBER_MASK_USERN(view.bytes[i] - '0');
            } else {
                switch (view.bytes[i]) {
                    default:
                        janet_panicf("invalid flag %c, expected a, t, d, e, u, y, w, r, i, or p", view.bytes[i]);
                        break;
                    case 'a':
                        fiber->flags |=
                            JANET_FIBER_MASK_DEBUG |
                            JANET_FIBER_MASK_ERROR |
                            JANET_FIBER_MASK_USER |
                            JANET_FIBER_MASK_YIELD;
                        break;
                    case 't':
                        fiber->flags |=
                            JANET_FIBER_MASK_ERROR |
                            JANET_FIBER_MASK_USER0 |
                            JANET_FIBER_MASK_USER1 |
                            JANET_FIBER_MASK_USER2 |
                            JANET_FIBER_MASK_USER3 |
                            JANET_FIBER_MASK_USER4;
                        break;
                    case 'd':
                        fiber->flags |= JANET_FIBER_MASK_DEBUG;
                        break;
                    case 'e':
                        fiber->flags |= JANET_FIBER_MASK_ERROR;
                        break;
                    case 'u':
                        fiber->flags |= JANET_FIBER_MASK_USER;
                        break;
                    case 'y':
                        fiber->flags |= JANET_FIBER_MASK_YIELD;
                        break;
                    case 'w':
                        fiber->flags |= JANET_FIBER_MASK_USER9;
                        break;
                    case 'r':
                        fiber->flags |= JANET_FIBER_MASK_USER8;
                        break;
                    case 'i':
                        if (!janet_vm.fiber->env) {
                            janet_vm.fiber->env = janet_table(0);
                        }
                        fiber->env = janet_vm.fiber->env;
                        break;
                    case 'p':
                        if (!janet_vm.fiber->env) {
                            janet_vm.fiber->env = janet_table(0);
                        }
                        fiber->env = janet_table(0);
                        fiber->env->proto = janet_vm.fiber->env;
                        break;
                }
            }
        }
    }
    return janet_wrap_fiber(fiber);
}

JANET_CORE_FN(cfun_fiber_status,
              "(fiber/status fib)",
              "Get the status of a fiber. The status will be one of:\n\n"
              "* :dead - the fiber has finished\n"
              "* :error - the fiber has errored out\n"
              "* :debug - the fiber is suspended in debug mode\n"
              "* :pending - the fiber has been yielded\n"
              "* :user(0-7) - the fiber is suspended by a user signal\n"
              "* :interrupted - the fiber was interrupted\n"
              "* :suspended - the fiber is waiting to be resumed by the scheduler\n"
              "* :new - the fiber has just been created and not yet run\n"
              "* :alive - the fiber is currently running and cannot be resumed") {
    janet_fixarity(argc, 1);
    JanetFiber *fiber = janet_getfiber(argv, 0);
    uint32_t s = janet_fiber_status(fiber);
    return janet_ckeywordv(janet_status_names[s]);
}

JANET_CORE_FN(cfun_fiber_current,
              "(fiber/current)",
              "Returns the currently running fiber.") {
    (void) argv;
    janet_fixarity(argc, 0);
    return janet_wrap_fiber(janet_vm.fiber);
}

JANET_CORE_FN(cfun_fiber_root,
              "(fiber/root)",
              "Returns the current root fiber. The root fiber is the oldest "
              "ancestor that does not have a parent. Note that a root fiber "
              "is also a task fiber.") {
    (void) argv;
    janet_fixarity(argc, 0);
    return janet_wrap_fiber(janet_vm.root_fiber);
}

JANET_CORE_FN(cfun_fiber_maxstack,
              "(fiber/maxstack fib)",
              "Gets the maximum stack size in janet values allowed for a fiber. While memory for "
              "the fiber's stack is not allocated up front, the fiber will not allocated more "
              "than this amount and will throw a stack-overflow error if more memory is needed. ") {
    janet_fixarity(argc, 1);
    JanetFiber *fiber = janet_getfiber(argv, 0);
    return janet_wrap_integer(fiber->maxstack);
}

JANET_CORE_FN(cfun_fiber_setmaxstack,
              "(fiber/setmaxstack fib maxstack)",
              "Sets the maximum stack size in janet values for a fiber. By default, the "
              "maximum stack size is usually 8192.") {
    janet_fixarity(argc, 2);
    JanetFiber *fiber = janet_getfiber(argv, 0);
    int32_t maxs = janet_getinteger(argv, 1);
    if (maxs < 0) {
        janet_panic("expected positive integer");
    }
    fiber->maxstack = maxs;
    return argv[0];
}

int janet_fiber_can_resume(JanetFiber *fiber) {
    JanetFiberStatus s = janet_fiber_status(fiber);
    int isFinished = s == JANET_STATUS_DEAD ||
                     s == JANET_STATUS_ERROR ||
                     s == JANET_STATUS_USER0 ||
                     s == JANET_STATUS_USER1 ||
                     s == JANET_STATUS_USER2 ||
                     s == JANET_STATUS_USER3 ||
                     s == JANET_STATUS_USER4;
    return !isFinished;
}

JANET_CORE_FN(cfun_fiber_can_resume,
              "(fiber/can-resume? fiber)",
              "Check if a fiber is finished and cannot be resumed.") {
    janet_fixarity(argc, 1);
    JanetFiber *fiber = janet_getfiber(argv, 0);
    return janet_wrap_boolean(janet_fiber_can_resume(fiber));
}

JANET_CORE_FN(cfun_fiber_last_value,
              "(fiber/last-value fiber)",
              "Get the last value returned or signaled from the fiber.") {
    janet_fixarity(argc, 1);
    JanetFiber *fiber = janet_getfiber(argv, 0);
    return fiber->last_value;
}

/* Module entry point */
void janet_lib_fiber(JanetTable *env) {
    JanetRegExt fiber_cfuns[] = {
        JANET_CORE_REG("fiber/new", cfun_fiber_new),
        JANET_CORE_REG("fiber/status", cfun_fiber_status),
        JANET_CORE_REG("fiber/root", cfun_fiber_root),
        JANET_CORE_REG("fiber/current", cfun_fiber_current),
        JANET_CORE_REG("fiber/maxstack", cfun_fiber_maxstack),
        JANET_CORE_REG("fiber/setmaxstack", cfun_fiber_setmaxstack),
        JANET_CORE_REG("fiber/getenv", cfun_fiber_getenv),
        JANET_CORE_REG("fiber/setenv", cfun_fiber_setenv),
        JANET_CORE_REG("fiber/can-resume?", cfun_fiber_can_resume),
        JANET_CORE_REG("fiber/last-value", cfun_fiber_last_value),
        JANET_REG_END
    };
    janet_core_cfuns_ext(env, NULL, fiber_cfuns);
}
