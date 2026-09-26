/* Entry point for the dynamically loaded module raylib/native. */
#include "janet_raylib.h"

JANET_MODULE_ENTRY(JanetTable *env) {
    janet_raylib_register(env);
}
