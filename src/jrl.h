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
    const JrlEnumMember *members;
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
} JrlField;

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

extern const JrlColorName jrl_color_names[];
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

/* Handles */
Janet jrl_handle_new(const JrlType *t, const void *value, int borrowed);
Janet jrl_handle_view(const JrlType *t, void *ptr, Janet owner);
void *jrl_handle_ptr(Janet x, const JrlType *t, const char *what);
void *jrl_get_handle(const Janet *argv, int32_t n, const JrlType *t);
void *jrl_unload_handle(const Janet *argv, int32_t n, const JrlType *t);
void jrl_mark_unloaded(Janet x);
void jrl_adopt(Janet handle, Janet owner);
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

#define JRL_UNIFORM_RAYLIB 0
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
