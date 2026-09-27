/*
 * jrl.h - runtime shared by the generated and hand-written binding code.
 *
 * Value model:
 *   tuple types   Vector2/3/4, Quaternion, Matrix, Color, Rectangle, float3, float16
 *                 cross as flat tuples of numbers; Color also accepts keywords.
 *   struct types  plain C structs (Camera3D, Ray, ...) cross as Janet structs with
 *                 kebab-case keyword keys.
 *   handle types  resources (Image, Texture, Model, Sound, ...) cross as abstract
 *                 values that own or view C memory. Owned handles are freed only by
 *                 their unload function; any use after unload raises a Janet error.
 */
#ifndef JRL_H
#define JRL_H

#include <janet.h>
#include <stddef.h>
#include <stdint.h>

#include "raylib.h"
#include "config.h"
#define RAYMATH_STATIC_INLINE
#include "raymath.h"
#include "rlgl.h"

typedef enum {
    JRL_K_INT,
    JRL_K_UINT,
    JRL_K_UCHAR,
    JRL_K_USHORT,
    JRL_K_FLOAT,
    JRL_K_DOUBLE,
    JRL_K_BOOL,
    JRL_K_CSTRING,
    JRL_K_TYPE
} JrlKind;

typedef enum {
    JRL_SHAPE_TUPLE,
    JRL_SHAPE_STRUCT,
    JRL_SHAPE_HANDLE
} JrlShape;

typedef enum {
    JRL_FIELD_SCALAR,   /* one scalar, or one struct when kind is JRL_K_TYPE */
    JRL_FIELD_FIXED,    /* T name[N] */
    JRL_FIELD_CHARS,    /* char name[N], converted to a string */
    JRL_FIELD_POINTER,  /* T *name with a runtime element count */
    JRL_FIELD_POINTER2, /* T **name: rows of inner elements */
    JRL_FIELD_BYTES,    /* void *name with a runtime byte count, read as a buffer copy */
    JRL_FIELD_HIDDEN
} JrlFieldShape;

typedef struct {
    const char *key; /* keyword name without the enum prefix */
    int64_t value;
} JrlEnumMember;

typedef struct {
    const char *name;
    const JrlEnumMember *members; /* sorted by key for binary search */
    int32_t count;
    int flags; /* accepts an indexed collection of members, OR-ed */
} JrlEnum;

typedef struct JrlType JrlType;
typedef int32_t (*JrlCountFn)(const void *self);

typedef struct {
    const char *key;
    JrlFieldShape shape;
    JrlKind kind;
    const JrlType *type;
    const JrlEnum *enumt;
    size_t offset;
    int32_t fixed;
    JrlCountFn count;
    JrlCountFn inner;
    int readonly;
    int32_t count_field;       /* JRL_FIELD_POINTER: index of the field holding the count, or -1 */
    int32_t count_factor;      /* elements per count unit (vertexCount * 3) */
    const JrlEnum *index_enum; /* array views also accept these member keywords as indices */
    int32_t key_index;         /* this field's keyword in jrl_field_key_names */
} JrlField;

/* Field keywords, made once per Janet VM by jrl_init_keys (called when the
 * module registers) instead of on every struct conversion. Keywords belong to
 * a VM, and each thread runs its own, so the cache is thread-local; a thread
 * that never registered the module falls back to making them per call. */
extern const char *const jrl_field_key_names[];
extern const int32_t jrl_field_key_count;
extern JANET_THREAD_LOCAL Janet *jrl_field_keys;
void jrl_init_keys(void);

static inline Janet jrl_field_key(const JrlField *f) {
    return jrl_field_keys ? jrl_field_keys[f->key_index] : janet_ckeywordv(f->key);
}

struct JrlType {
    const char *name;
    size_t size;
    JrlShape shape;
    const JrlField *fields;
    int32_t field_count;
    const JanetAbstractType *at;
};

typedef struct {
    const char *key;
    Color color;
} JrlColorName;

extern const JrlColorName jrl_color_names[]; /* sorted by key for binary search */
extern const int32_t jrl_color_name_count;

/* Handle behaviour shared by every generated abstract type. */
int jrl_handle_gcmark(void *data, size_t len);
int jrl_handle_get(void *data, Janet key, Janet *out);
void jrl_handle_put(void *data, Janet key, Janet value);
void jrl_handle_tostring(void *data, JanetBuffer *buffer);
Janet jrl_handle_next(void *data, Janet key);

/* Scalars */
int jrl_get_int(const Janet *argv, int32_t n);
unsigned int jrl_get_uint(const Janet *argv, int32_t n);
unsigned int jrl_get_uint_bits(const Janet *argv, int32_t n);
unsigned char jrl_get_uchar(const Janet *argv, int32_t n);
char jrl_get_char(const Janet *argv, int32_t n);
float jrl_get_float(const Janet *argv, int32_t n);
double jrl_get_double(const Janet *argv, int32_t n);
bool jrl_get_bool(const Janet *argv, int32_t n);
const char *jrl_get_cstring(const Janet *argv, int32_t n);
const char *jrl_opt_cstring(const Janet *argv, int32_t n);
int jrl_get_enum(const Janet *argv, int32_t n, const JrlEnum *e);
Janet jrl_wrap_cstring(const char *s);

/* Value structs */
void jrl_from_janet(const JrlType *t, Janet v, void *out, const char *what);
Janet jrl_to_janet(const JrlType *t, const void *p, Janet owner);
void jrl_get_value(const Janet *argv, int32_t n, const JrlType *t, void *out);

/* ---------------------------------------------------------------------------
 * Inline fast paths for the tuple types every draw call passes.
 *
 * The common shape (a tuple or array of exactly the right numbers; for Color,
 * integers in 0-255 or a color keyword) is converted here without leaving the
 * caller. Anything else falls back to the generic conversion, which accepts
 * the other spellings and raises the usual errors, so validation and messages
 * are the same as before.
 * ------------------------------------------------------------------------- */

extern const JrlType jrl_type_Vector2;
extern const JrlType jrl_type_Vector3;
extern const JrlType jrl_type_Vector4;
extern const JrlType jrl_type_Rectangle;
extern const JrlType jrl_type_Color;

int jrl_color_keyword(Janet v, Color *out); /* 1 if v names a color */

static inline int jrl_items(Janet v, const Janet **items, int32_t *len) {
    if (janet_checktype(v, JANET_TUPLE)) {
        *items = janet_unwrap_tuple(v);
        *len = janet_tuple_length(*items);
        return 1;
    }
    if (janet_checktype(v, JANET_ARRAY)) {
        JanetArray *a = janet_unwrap_array(v);
        *items = a->data;
        *len = a->count;
        return 1;
    }
    return 0;
}

/* n numbers into consecutive floats (Vector2/3/4 and Rectangle are all-float structs). */
static inline int jrl_fast_floats(Janet v, float *out, int32_t n) {
    const Janet *items;
    int32_t len;
    if (!jrl_items(v, &items, &len) || len != n) return 0;
    for (int32_t i = 0; i < n; i++) {
        if (!janet_checktype(items[i], JANET_NUMBER)) return 0;
        out[i] = (float) janet_unwrap_number(items[i]);
    }
    return 1;
}

static inline int jrl_fast_color(Janet v, Color *out) {
    const Janet *items;
    int32_t len;
    if (janet_checktype(v, JANET_KEYWORD)) return jrl_color_keyword(v, out);
    if (!jrl_items(v, &items, &len) || len != 4) return 0;
    unsigned char c[4];
    for (int32_t i = 0; i < 4; i++) {
        if (!janet_checktype(items[i], JANET_NUMBER)) return 0;
        double d = janet_unwrap_number(items[i]);
        if (!(d >= 0.0 && d <= 255.0) || d != (double) (int) d) return 0;
        c[i] = (unsigned char) d;
    }
    *out = (Color) {c[0], c[1], c[2], c[3]};
    return 1;
}

#define JRL_FAST_FLOAT_GETTER(T, N) \
    static inline T jrl_get_##T(const Janet *argv, int32_t n) { \
        T value; \
        if (!jrl_fast_floats(argv[n], (float *) &value, N)) jrl_get_value(argv, n, &jrl_type_##T, &value); \
        return value; \
    }
JRL_FAST_FLOAT_GETTER(Vector2, 2)
JRL_FAST_FLOAT_GETTER(Vector3, 3)
JRL_FAST_FLOAT_GETTER(Vector4, 4)
JRL_FAST_FLOAT_GETTER(Rectangle, 4)
#undef JRL_FAST_FLOAT_GETTER

static inline Color jrl_get_Color(const Janet *argv, int32_t n) {
    Color value;
    if (!jrl_fast_color(argv[n], &value)) jrl_get_value(argv, n, &jrl_type_Color, &value);
    return value;
}

static inline Janet jrl_wrap_floats(const float *p, int32_t n) {
    Janet *t = janet_tuple_begin(n);
    for (int32_t i = 0; i < n; i++) t[i] = janet_wrap_number(p[i]);
    return janet_wrap_tuple(janet_tuple_end(t));
}

static inline Janet jrl_wrap_Vector2(Vector2 v) { return jrl_wrap_floats(&v.x, 2); }
static inline Janet jrl_wrap_Vector3(Vector3 v) { return jrl_wrap_floats(&v.x, 3); }
static inline Janet jrl_wrap_Vector4(Vector4 v) { return jrl_wrap_floats(&v.x, 4); }
static inline Janet jrl_wrap_Rectangle(Rectangle v) { return jrl_wrap_floats(&v.x, 4); }
static inline Janet jrl_wrap_Color(Color c) {
    Janet *t = janet_tuple_begin(4);
    t[0] = janet_wrap_integer(c.r);
    t[1] = janet_wrap_integer(c.g);
    t[2] = janet_wrap_integer(c.b);
    t[3] = janet_wrap_integer(c.a);
    return janet_wrap_tuple(janet_tuple_end(t));
}

/* Handles */
Janet jrl_handle_new(const JrlType *t, const void *value, int borrowed);
Janet jrl_handle_view(const JrlType *t, void *ptr, Janet owner);
void *jrl_handle_ptr(Janet x, const JrlType *t, const char *what);
void *jrl_get_handle(const Janet *argv, int32_t n, const JrlType *t);
void *jrl_unload_handle(const Janet *argv, int32_t n, const JrlType *t);
void jrl_mark_unloaded(Janet x);
void jrl_adopt(Janet handle, Janet owner);
void jrl_handle_set_frames(Janet handle, int32_t frames);
int jrl_handle_raylib_owned(Janet x);

/* make-<type>: an owned handle built from a struct of fields (see jrl.c). */
Janet jrl_make(const JrlType *t, const Janet *argv, int32_t n);
void jrl_handle_attach(Janet handle, Janet owner);
int jrl_value_live(Janet x);

/* Arrays: views into handle memory, and arrays returned by Load* functions */
Janet jrl_array_owned(JrlKind kind, const JrlType *t, void *ptr, int32_t count);
void *jrl_unload_array(const Janet *argv, int32_t n, const JrlType *t, int32_t *count);
void *jrl_get_handle_array(const Janet *argv, int32_t n, const JrlType *t, int32_t *count);

/* Call-scoped conversions; free the result with janet_sfree after the call. */
void *jrl_get_carray(const Janet *argv, int32_t n, JrlKind kind, const JrlType *t,
                     const JrlEnum *e, int nullable, int32_t fixed, int32_t *count);
JanetByteView jrl_get_bytes(const Janet *argv, int32_t n, int nullable);
void *jrl_get_raw_pointer(const Janet *argv, int32_t n);

#define JRL_UNIFORM_RLGL 1
#define JRL_UNIFORM_ATTRIB 2
void *jrl_get_uniform(const Janet *argv, int32_t n, int family, int type, int count);

/* Returned C memory, copied into Janet values */
Janet jrl_wrap_carray(JrlKind kind, const JrlType *t, const void *ptr, int32_t count);
Janet jrl_wrap_bytes(const void *ptr, int32_t size);

/* Module registration */
void jrl_register_types(JanetTable *env);
void jrl_register_raylib(JanetTable *env);
void jrl_register_raymath(JanetTable *env);
void jrl_register_rlgl(JanetTable *env);
void jrl_register_manual(JanetTable *env);

#endif
