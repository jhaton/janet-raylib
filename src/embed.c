/* Static embedding: preload raylib/native and the raylib layer into module/cache. */
#include "janet_raylib.h"

/* Generated at build time from lib/raylib/init.janet by gen/embed-layer.janet. */
extern const unsigned char jrl_layer_source[];
extern const int32_t jrl_layer_source_length;

int janet_raylib_preload(JanetTable *env) {
    Janet cache_value;
    if (janet_resolve(env, janet_csymbol("module/cache"), &cache_value) == JANET_BINDING_NONE ||
        !janet_checktype(cache_value, JANET_TABLE)) {
        return 1;
    }
    JanetTable *cache = janet_unwrap_table(cache_value);

    JanetTable *native = janet_table(0);
    janet_raylib_register(native);
    janet_table_put(cache, janet_cstringv("raylib/native"), janet_wrap_table(native));

    JanetTable *layer = janet_table(0);
    layer->proto = env;
    Janet result;
    if (janet_dobytes(layer, jrl_layer_source, jrl_layer_source_length, "raylib/init.janet", &result)) {
        return 1;
    }
    janet_table_put(cache, janet_cstringv("raylib"), janet_wrap_table(layer));
    return 0;
}
