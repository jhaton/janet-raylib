/*
 * Embedding example: a C program with Janet and raylib linked in statically.
 * No module files are needed at runtime; janet_raylib_preload makes
 * (import raylib) resolve to the linked-in bindings and Janet layer.
 */
#include <janet.h>
#include <stdio.h>

#include "janet_raylib.h"

static const char *script =
    "(import raylib :as rl)\n"
    "(def image (rl/gen-image-gradient-linear 8 8 0 :red :blue))\n"
    "(def corner (first (rl/load-image-colors image)))\n"
    "(rl/unload-image image)\n"
    "(printf \"EMBED_OK vector=%q corner=%q layer-macro=%q\"\n"
    "        (rl/vector2-add [1 2] [3 4]) corner\n"
    "        (truthy? (get-in (curenv) ['rl/with-drawing :macro])))\n";

int main(void) {
    janet_init();
    JanetTable *env = janet_core_env(NULL);
    if (janet_raylib_preload(env)) {
        fprintf(stderr, "failed to preload raylib modules\n");
        janet_deinit();
        return 1;
    }
    Janet result;
    int status = janet_dostring(env, script, "embed", &result);
    janet_deinit();
    return status;
}
