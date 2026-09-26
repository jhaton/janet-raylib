/* manual.c - functions whose shape the generator cannot express. */
#include "jrl.h"
#include "gen/types.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---------------------------------------------------------------------------
 * Trace log capture
 *
 * raylib logs from the main thread and from its audio thread. A Janet VM belongs
 * to one thread, so the callback never touches Janet: it formats each message
 * into a fixed ring under a mutex, and take-trace-logs drains the ring from Janet.
 * ------------------------------------------------------------------------- */

#define JRL_LOG_CAPACITY 512
#define JRL_LOG_MESSAGE_LENGTH 256

typedef struct {
    int level;
    char message[JRL_LOG_MESSAGE_LENGTH];
} JrlLogEntry;

static JrlLogEntry jrl_log_ring[JRL_LOG_CAPACITY];
static JrlLogEntry jrl_log_drain[JRL_LOG_CAPACITY]; /* used only by the Janet thread */
static int32_t jrl_log_start = 0;
static int32_t jrl_log_count = 0;
static int64_t jrl_log_dropped = 0;
static JanetOSMutex *jrl_log_mutex = NULL;

static void jrl_log_callback(int level, const char *text, va_list args) {
    janet_os_mutex_lock(jrl_log_mutex);
    int32_t slot;
    if (jrl_log_count == JRL_LOG_CAPACITY) {
        slot = jrl_log_start;
        jrl_log_start = (jrl_log_start + 1) % JRL_LOG_CAPACITY;
        jrl_log_dropped++;
    } else {
        slot = (jrl_log_start + jrl_log_count) % JRL_LOG_CAPACITY;
        jrl_log_count++;
    }
    jrl_log_ring[slot].level = level;
    vsnprintf(jrl_log_ring[slot].message, JRL_LOG_MESSAGE_LENGTH, text, args);
    janet_os_mutex_unlock(jrl_log_mutex);
}

static Janet cfun_set_trace_log_capture(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);
    SetTraceLogCallback(janet_getboolean(argv, 0) ? jrl_log_callback : NULL);
    return janet_wrap_nil();
}

static Janet cfun_take_trace_logs(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 0);
    (void) argv;
    janet_os_mutex_lock(jrl_log_mutex);
    int32_t count = jrl_log_count;
    int64_t dropped = jrl_log_dropped;
    for (int32_t i = 0; i < count; i++) jrl_log_drain[i] = jrl_log_ring[(jrl_log_start + i) % JRL_LOG_CAPACITY];
    jrl_log_start = 0;
    jrl_log_count = 0;
    jrl_log_dropped = 0;
    janet_os_mutex_unlock(jrl_log_mutex);
    JanetArray *result = janet_array(count + (dropped > 0));
    if (dropped > 0) {
        char notice[64];
        snprintf(notice, sizeof(notice), "%lld older trace log messages were dropped", (long long) dropped);
        Janet entry[2] = {janet_wrap_integer(LOG_WARNING), janet_cstringv(notice)};
        janet_array_push(result, janet_wrap_tuple(janet_tuple_n(entry, 2)));
    }
    for (int32_t i = 0; i < count; i++) {
        Janet entry[2] = {janet_wrap_integer(jrl_log_drain[i].level), janet_cstringv(jrl_log_drain[i].message)};
        janet_array_push(result, janet_wrap_tuple(janet_tuple_n(entry, 2)));
    }
    return janet_wrap_array(result);
}

/* ---------------------------------------------------------------------------
 * Models
 * ------------------------------------------------------------------------- */

static int id_in(const unsigned int *ids, int32_t count, unsigned int id) {
    for (int32_t i = 0; i < count; i++) {
        if (ids[i] == id) return 1;
    }
    return 0;
}

static Janet cfun_unload_model_resources(int32_t argc, Janet *argv) {
    janet_arity(argc, 1, 2);
    int32_t keep_count = 0;
    const Janet *keep_items = NULL;
    if (argc > 1 && !janet_indexed_view(argv[1], &keep_items, &keep_count))
        janet_panicf("argument 1: expected a tuple or array of textures, got %q", argv[1]);
    unsigned int *keep = janet_smalloc(sizeof(unsigned int) * (size_t) (keep_count + 1));
    for (int32_t i = 0; i < keep_count; i++)
        keep[i] = ((Texture *) jrl_handle_ptr(keep_items[i], &jrl_type_Texture, "keep"))->id;
    Model model = *(Model *) jrl_unload_handle(argv, 0, &jrl_type_Model);
    unsigned int default_id = rlGetTextureIdDefault();
    unsigned int *unloaded = janet_smalloc(sizeof(unsigned int) * (size_t) (model.materialCount * MAX_MATERIAL_MAPS + 1));
    int32_t unloaded_count = 0;
    for (int i = 0; i < model.materialCount; i++) {
        MaterialMap *maps = model.materials[i].maps;
        if (maps == NULL) continue;
        for (int j = 0; j < MAX_MATERIAL_MAPS; j++) {
            unsigned int id = maps[j].texture.id;
            if (id == 0 || id == default_id || id_in(keep, keep_count, id) || id_in(unloaded, unloaded_count, id)) continue;
            rlUnloadTexture(id);
            unloaded[unloaded_count++] = id;
        }
    }
    UnloadModel(model);
    jrl_mark_unloaded(argv[0]);
    janet_sfree(keep);
    janet_sfree(unloaded);
    return janet_wrap_integer(unloaded_count);
}

static Janet cfun_gen_image_font_atlas(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 4);
    int32_t glyph_count = 0;
    const GlyphInfo *glyphs = jrl_get_handle_array(argv, 0, &jrl_type_GlyphInfo, &glyph_count);
    int font_size = jrl_get_int(argv, 1);
    int padding = jrl_get_int(argv, 2);
    int pack_method = jrl_get_int(argv, 3);
    Rectangle *recs = NULL;
    Image image = GenImageFontAtlas(glyphs, &recs, glyph_count, font_size, padding, pack_method);
    Janet result[2] = {
        jrl_handle_new(&jrl_type_Image, &image, 0),
        jrl_wrap_carray(JRL_K_TYPE, &jrl_type_Rectangle, recs, glyph_count)
    };
    if (recs) MemFree(recs);
    return janet_wrap_tuple(janet_tuple_n(result, 2));
}

static Janet cfun_unload_materials(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);
    int32_t count = 0;
    Material *materials = jrl_unload_array(argv, 0, &jrl_type_Material, &count);
    for (int32_t i = 0; i < count; i++) UnloadMaterial(materials[i]);
    MemFree(materials);
    jrl_mark_unloaded(argv[0]);
    return janet_wrap_nil();
}

static Janet cfun_handle_live(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);
    return janet_wrap_boolean(jrl_value_live(argv[0]));
}

/* ---------------------------------------------------------------------------
 * Registration
 * ------------------------------------------------------------------------- */

static const JanetRegExt manual_cfuns[] = {
    {"gen-image-font-atlas", cfun_gen_image_font_atlas,
     "(gen-image-font-atlas glyphs font-size padding pack-method)\n\n"
     "Generate an image font atlas from a glyph array returned by load-font-data. "
     "Returns [image recs], where recs holds one Rectangle per glyph.\n\n"
     "C: Image GenImageFontAtlas(const GlyphInfo *glyphs, Rectangle **glyphRecs, int glyphCount, int fontSize, int padding, int packMethod)",
     __FILE__, __LINE__},
    {"unload-materials", cfun_unload_materials,
     "(unload-materials materials)\n\n"
     "Unload every material in an array returned by load-materials, then free the array.",
     __FILE__, __LINE__},
    {"handle-live?", cfun_handle_live,
     "(handle-live? x)\n\n"
     "True when a raylib handle or array can still be used: it has not been unloaded, "
     "and neither has the resource it belongs to.",
     __FILE__, __LINE__},
    {"set-trace-log-capture", cfun_set_trace_log_capture,
     "(set-trace-log-capture enabled)\n\n"
     "When enabled, raylib log messages (from any thread) are queued instead of printed; "
     "collect them with take-trace-logs. Disabling restores raylib's own printing. "
     "set-trace-log-level still filters what is logged. The queue keeps the newest 512 messages.",
     __FILE__, __LINE__},
    {"take-trace-logs", cfun_take_trace_logs,
     "(take-trace-logs)\n\n"
     "Remove and return queued log messages, oldest first, as an array of [level message] "
     "tuples, where level is a TraceLogLevel integer. If messages were dropped because the "
     "queue was full, the first entry is a log-warning saying how many.",
     __FILE__, __LINE__},
    {"unload-model-resources", cfun_unload_model_resources,
     "(unload-model-resources model &opt keep)\n\n"
     "Unload model together with the textures its materials reference, which unload-model "
     "leaves behind. Each distinct non-default texture is unloaded once. Textures listed in "
     "keep (a tuple of Texture handles you still own) are left alone. Material shaders are "
     "never unloaded: raylib's model loaders do not create them, so any custom shader is "
     "yours to unload. Returns the number of textures unloaded.",
     __FILE__, __LINE__},
    {NULL, NULL, NULL, NULL, 0}
};

void jrl_register_manual(JanetTable *env) {
    if (jrl_log_mutex == NULL) {
        jrl_log_mutex = malloc(janet_os_mutex_size());
        if (jrl_log_mutex == NULL) janet_panic("out of memory allocating the trace log mutex");
        janet_os_mutex_init(jrl_log_mutex);
    }
    janet_cfuns_ext(env, NULL, manual_cfuns);
}
