/* jrl.c - conversions, guarded handles, and array views. See jrl.h. */
#include "jrl.h"
#include "gen/types.h"

#include <stdlib.h>
#include <string.h>

typedef struct {
    const JrlType *type;
    void *ptr;
    Janet owner;
    int32_t frames;        /* images from load-image-anim: :data spans every frame */
    uint8_t unloaded;
    uint8_t borrowed;
    uint8_t view;
} JrlHandle;

#define JRL_STORAGE_OFFSET ((sizeof(JrlHandle) + 15) & ~(size_t)15)

typedef struct {
    JrlKind kind;
    const JrlType *type;
    const JrlEnum *enumt;
    Janet owner;           /* field views: the handle that owns the memory */
    const JrlField *field; /* field views */
    int32_t row;           /* row of a JRL_FIELD_POINTER2 field, or -1 */
    void *ptr;             /* owned arrays */
    int32_t count;         /* owned arrays */
    uint8_t owned;
    uint8_t unloaded;
    uint8_t adopted;       /* owned arrays moved into a value built by make-<type> */
    uint8_t readonly;
} JrlArray;

static int jrl_array_gcmark(void *data, size_t len);
static int jrl_array_get(void *data, Janet key, Janet *out);
static void jrl_array_put(void *data, Janet key, Janet value);
static void jrl_array_tostring(void *data, JanetBuffer *buffer);
static Janet jrl_array_next(void *data, Janet key);
static size_t jrl_array_length(void *data, size_t len);

static const JanetAbstractType jrl_array_type = {
    "raylib/array",
    NULL,
    jrl_array_gcmark,
    jrl_array_get,
    jrl_array_put,
    NULL,
    NULL,
    jrl_array_tostring,
    NULL,
    NULL,
    jrl_array_next,
    NULL,
    jrl_array_length,
    NULL,
    NULL
};

/* ---------------------------------------------------------------------------
 * Identification and liveness
 * ------------------------------------------------------------------------- */

static JrlHandle *as_handle(Janet x) {
    if (!janet_checktype(x, JANET_ABSTRACT)) return NULL;
    void *p = janet_unwrap_abstract(x);
    if (janet_abstract_type(p)->gcmark != jrl_handle_gcmark) return NULL;
    return p;
}

static JrlArray *as_array(Janet x) {
    if (!janet_checktype(x, JANET_ABSTRACT)) return NULL;
    void *p = janet_unwrap_abstract(x);
    if (janet_abstract_type(p) != &jrl_array_type) return NULL;
    return p;
}

static int owner_live(Janet owner);

static int handle_live(const JrlHandle *h) {
    return !h->unloaded && owner_live(h->owner);
}

static int array_live(const JrlArray *a) {
    return a->owned ? !a->unloaded : owner_live(a->owner);
}

static int owner_live(Janet owner) {
    JrlHandle *h;
    JrlArray *a;
    if (janet_checktype(owner, JANET_NIL)) return 1;
    if ((h = as_handle(owner))) return handle_live(h);
    if ((a = as_array(owner))) return array_live(a);
    return 1;
}

int jrl_value_live(Janet x) {
    JrlHandle *h;
    JrlArray *a;
    if ((h = as_handle(x))) return handle_live(h);
    if ((a = as_array(x))) return array_live(a);
    janet_panicf("expected a raylib handle or array, got %q", x);
}

static void check_handle_live(const JrlHandle *h, const char *what) {
    if (h->unloaded) janet_panicf("%s: %s was already unloaded", what, h->type->name);
    if (!owner_live(h->owner))
        janet_panicf("%s: %s belongs to a resource that was unloaded", what, h->type->name);
}

/* ---------------------------------------------------------------------------
 * Scalars
 * ------------------------------------------------------------------------- */

static int64_t integer_in(Janet v, int64_t lo, int64_t hi, const char *what) {
    if (!janet_checktype(v, JANET_NUMBER))
        janet_panicf("%s: expected integer, got %q", what, v);
    double d = janet_unwrap_number(v);
    if (d != (double)(int64_t)d || d < (double)lo || d > (double)hi)
        janet_panicf("%s: expected integer in range [%q, %q], got %q", what,
                     janet_wrap_number((double) lo), janet_wrap_number((double) hi), v);
    return (int64_t) d;
}

static double number_of(Janet v, const char *what) {
    if (!janet_checktype(v, JANET_NUMBER))
        janet_panicf("%s: expected number, got %q", what, v);
    return janet_unwrap_number(v);
}

/* Error context for argument n. The labels are static so the success path of
 * every conversion stays free of string formatting. */
static const char *const argument_labels[] = {
    "argument 0", "argument 1", "argument 2", "argument 3", "argument 4",
    "argument 5", "argument 6", "argument 7", "argument 8", "argument 9",
    "argument 10", "argument 11", "argument 12", "argument 13", "argument 14",
    "argument 15"
};

static const char *argument_label(int32_t n) {
    if (n >= 0 && n < (int32_t) (sizeof(argument_labels) / sizeof(argument_labels[0])))
        return argument_labels[n];
    return "argument";
}

/* Binary search over a key-sorted table of records whose first member is the key. */
static int32_t find_key(const uint8_t *kw, const void *table, int32_t count, size_t stride) {
    int32_t lo = 0, hi = count - 1;
    while (lo <= hi) {
        int32_t mid = lo + (hi - lo) / 2;
        int cmp = janet_cstrcmp(kw, *(const char *const *) ((const char *) table + (size_t) mid * stride));
        if (cmp == 0) return mid;
        if (cmp < 0) hi = mid - 1;
        else lo = mid + 1;
    }
    return -1;
}

int jrl_get_int(const Janet *argv, int32_t n) {
    return (int) integer_in(argv[n], INT32_MIN, INT32_MAX, argument_label(n));
}

unsigned int jrl_get_uint(const Janet *argv, int32_t n) {
    return (unsigned int) integer_in(argv[n], 0, UINT32_MAX, argument_label(n));
}

/* A 32-bit pattern such as a packed color: negative values wrap as C's
 * int -> unsigned int conversion does, so (get-color (color-to-int c)) works. */
unsigned int jrl_get_uint_bits(const Janet *argv, int32_t n) {
    return (unsigned int) (uint32_t) integer_in(argv[n], INT32_MIN, UINT32_MAX, argument_label(n));
}

unsigned char jrl_get_uchar(const Janet *argv, int32_t n) {
    return (unsigned char) integer_in(argv[n], 0, 255, argument_label(n));
}

char jrl_get_char(const Janet *argv, int32_t n) {
    const uint8_t *bytes;
    int32_t len;
    if (janet_bytes_view(argv[n], &bytes, &len)) {
        if (len != 1) janet_panicf("argument %d: expected a one-byte string, got %q", n, argv[n]);
        return (char) bytes[0];
    }
    return (char) integer_in(argv[n], 0, 255, argument_label(n));
}

float jrl_get_float(const Janet *argv, int32_t n) {
    return (float) number_of(argv[n], argument_label(n));
}

double jrl_get_double(const Janet *argv, int32_t n) {
    return number_of(argv[n], argument_label(n));
}

bool jrl_get_bool(const Janet *argv, int32_t n) {
    return janet_getboolean(argv, n);
}

const char *jrl_get_cstring(const Janet *argv, int32_t n) {
    return janet_getcstring(argv, n);
}

const char *jrl_opt_cstring(const Janet *argv, int32_t n) {
    if (janet_checktype(argv[n], JANET_NIL)) return NULL;
    return janet_getcstring(argv, n);
}

Janet jrl_wrap_cstring(const char *s) {
    return s ? janet_cstringv(s) : janet_wrap_nil();
}

static int64_t enum_member(const JrlEnum *e, Janet v, const char *what) {
    if (janet_checktype(v, JANET_KEYWORD)) {
        const uint8_t *kw = janet_unwrap_keyword(v);
        int32_t i = find_key(kw, e->members, e->count, sizeof(JrlEnumMember));
        if (i >= 0) return e->members[i].value;
        janet_panicf("%s: unknown %s member %q", what, e->name, v);
    }
    return integer_in(v, INT32_MIN, UINT32_MAX, what);
}

static int64_t enum_value(const JrlEnum *e, Janet v, const char *what) {
    const Janet *items;
    int32_t len;
    if (e->flags && janet_indexed_view(v, &items, &len)) {
        int64_t result = 0;
        for (int32_t i = 0; i < len; i++) result |= enum_member(e, items[i], what);
        return result;
    }
    return enum_member(e, v, what);
}

int jrl_get_enum(const Janet *argv, int32_t n, const JrlEnum *e) {
    return (int) enum_value(e, argv[n], argument_label(n));
}

/* ---------------------------------------------------------------------------
 * Elements
 * ------------------------------------------------------------------------- */

static size_t kind_size(JrlKind kind, const JrlType *t) {
    switch (kind) {
        case JRL_K_INT: return sizeof(int);
        case JRL_K_UINT: return sizeof(unsigned int);
        case JRL_K_UCHAR: return sizeof(unsigned char);
        case JRL_K_USHORT: return sizeof(unsigned short);
        case JRL_K_FLOAT: return sizeof(float);
        case JRL_K_DOUBLE: return sizeof(double);
        case JRL_K_BOOL: return sizeof(bool);
        case JRL_K_CSTRING: return sizeof(char *);
        case JRL_K_TYPE: return t->size;
    }
    return 0;
}

static Janet read_elem(JrlKind kind, const JrlType *t, const void *p, Janet owner) {
    switch (kind) {
        case JRL_K_INT: return janet_wrap_integer(*(const int *) p);
        case JRL_K_UINT: return janet_wrap_number((double) *(const unsigned int *) p);
        case JRL_K_UCHAR: return janet_wrap_integer(*(const unsigned char *) p);
        case JRL_K_USHORT: return janet_wrap_integer(*(const unsigned short *) p);
        case JRL_K_FLOAT: return janet_wrap_number(*(const float *) p);
        case JRL_K_DOUBLE: return janet_wrap_number(*(const double *) p);
        case JRL_K_BOOL: return janet_wrap_boolean(*(const bool *) p);
        case JRL_K_CSTRING: return jrl_wrap_cstring(*(char *const *) p);
        case JRL_K_TYPE:
            if (t->shape == JRL_SHAPE_HANDLE) return jrl_handle_view(t, (void *) p, owner);
            return jrl_to_janet(t, p, owner);
    }
    return janet_wrap_nil();
}

static void write_elem(JrlKind kind, const JrlType *t, const JrlEnum *e,
                       void *p, Janet v, const char *what) {
    switch (kind) {
        case JRL_K_INT:
            *(int *) p = (int) (e ? enum_value(e, v, what) : integer_in(v, INT32_MIN, INT32_MAX, what));
            break;
        case JRL_K_UINT:
            *(unsigned int *) p = (unsigned int) (e ? enum_value(e, v, what) : integer_in(v, 0, UINT32_MAX, what));
            break;
        case JRL_K_UCHAR: *(unsigned char *) p = (unsigned char) integer_in(v, 0, 255, what); break;
        case JRL_K_USHORT: *(unsigned short *) p = (unsigned short) integer_in(v, 0, 65535, what); break;
        case JRL_K_FLOAT: *(float *) p = (float) number_of(v, what); break;
        case JRL_K_DOUBLE: *(double *) p = number_of(v, what); break;
        case JRL_K_BOOL:
            if (!janet_checktype(v, JANET_BOOLEAN)) janet_panicf("%s: expected boolean, got %q", what, v);
            *(bool *) p = janet_unwrap_boolean(v);
            break;
        case JRL_K_CSTRING:
            janet_panicf("%s: C string elements are read-only", what);
            break;
        case JRL_K_TYPE:
            if (t->shape == JRL_SHAPE_HANDLE) {
                memcpy(p, jrl_handle_ptr(v, t, what), t->size);
            } else {
                jrl_from_janet(t, v, p, what);
            }
            break;
    }
}

/* ---------------------------------------------------------------------------
 * Value structs
 * ------------------------------------------------------------------------- */

static int32_t tuple_width(const JrlType *t) {
    int32_t width = 0;
    for (int32_t i = 0; i < t->field_count; i++) {
        width += t->fields[i].shape == JRL_FIELD_FIXED ? t->fields[i].fixed : 1;
    }
    return width;
}

JANET_THREAD_LOCAL Janet *jrl_field_keys = NULL;

void jrl_init_keys(void) {
    /* Registering again (another env in the same VM, or a new VM on this
     * thread after janet_deinit) replaces the previous keys. */
    if (jrl_field_keys == NULL) {
        jrl_field_keys = malloc(sizeof(Janet) * (size_t) jrl_field_key_count);
        if (jrl_field_keys == NULL) janet_panic("out of memory");
    } else {
        for (int32_t i = 0; i < jrl_field_key_count; i++) janet_gcunroot(jrl_field_keys[i]);
    }
    for (int32_t i = 0; i < jrl_field_key_count; i++) {
        jrl_field_keys[i] = janet_ckeywordv(jrl_field_key_names[i]);
        janet_gcroot(jrl_field_keys[i]);
    }
}

/* The inline getters in jrl.h fill these structs as float arrays. */
_Static_assert(sizeof(Vector2) == 2 * sizeof(float), "Vector2 layout");
_Static_assert(sizeof(Vector3) == 3 * sizeof(float), "Vector3 layout");
_Static_assert(sizeof(Vector4) == 4 * sizeof(float), "Vector4 layout");
_Static_assert(sizeof(Rectangle) == 4 * sizeof(float), "Rectangle layout");

int jrl_color_keyword(Janet v, Color *out) {
    int32_t i = find_key(janet_unwrap_keyword(v), jrl_color_names, jrl_color_name_count, sizeof(JrlColorName));
    if (i < 0) return 0;
    *out = jrl_color_names[i].color;
    return 1;
}

static void tuple_from_janet(const JrlType *t, Janet v, void *out, const char *what) {
    const Janet *items;
    int32_t len;
    /* The inline getters' shapes first, for arrays of points and struct
     * fields; everything else takes the checked path below. */
    if (t == &jrl_type_Color) {
        if (jrl_fast_color(v, out)) return;
    } else if (t == &jrl_type_Vector2 || t == &jrl_type_Vector3 || t == &jrl_type_Vector4 ||
               t == &jrl_type_Rectangle) {
        if (jrl_fast_floats(v, out, (int32_t) (t->size / sizeof(float)))) return;
    }
    int32_t width = tuple_width(t);
    if (t == &jrl_type_Color) {
        Color *c = out;
        if (janet_checktype(v, JANET_KEYWORD)) {
            int32_t i = find_key(janet_unwrap_keyword(v), jrl_color_names, jrl_color_name_count, sizeof(JrlColorName));
            if (i >= 0) {
                *c = jrl_color_names[i].color;
                return;
            }
            janet_panicf("%s: unknown color %q", what, v);
        }
        if (janet_indexed_view(v, &items, &len) && len == 3) {
            c->r = (unsigned char) integer_in(items[0], 0, 255, what);
            c->g = (unsigned char) integer_in(items[1], 0, 255, what);
            c->b = (unsigned char) integer_in(items[2], 0, 255, what);
            c->a = 255;
            return;
        }
    }
    if (!janet_indexed_view(v, &items, &len) || len != width)
        janet_panicf("%s: expected %s as a tuple of %d numbers, got %q", what, t->name, width, v);
    int32_t index = 0;
    for (int32_t i = 0; i < t->field_count; i++) {
        const JrlField *f = &t->fields[i];
        int32_t n = f->shape == JRL_FIELD_FIXED ? f->fixed : 1;
        size_t size = kind_size(f->kind, f->type);
        for (int32_t j = 0; j < n; j++) {
            write_elem(f->kind, f->type, NULL, (char *) out + f->offset + (size_t) j * size, items[index++], what);
        }
    }
}

static Janet tuple_to_janet(const JrlType *t, const void *p) {
    int32_t width = tuple_width(t);
    Janet *tuple = janet_tuple_begin(width);
    int32_t index = 0;
    for (int32_t i = 0; i < t->field_count; i++) {
        const JrlField *f = &t->fields[i];
        int32_t n = f->shape == JRL_FIELD_FIXED ? f->fixed : 1;
        size_t size = kind_size(f->kind, f->type);
        for (int32_t j = 0; j < n; j++) {
            tuple[index++] = read_elem(f->kind, f->type, (const char *) p + f->offset + (size_t) j * size, janet_wrap_nil());
        }
    }
    return janet_wrap_tuple(janet_tuple_end(tuple));
}

static void field_from_janet(const JrlField *f, void *base, Janet v, const char *what) {
    void *p = (char *) base + f->offset;
    const Janet *items;
    int32_t len;
    switch (f->shape) {
        case JRL_FIELD_SCALAR:
            write_elem(f->kind, f->type, f->enumt, p, v, what);
            break;
        case JRL_FIELD_FIXED: {
            size_t size = kind_size(f->kind, f->type);
            if (!janet_indexed_view(v, &items, &len) || len != f->fixed)
                janet_panicf("%s: field :%s expects %d elements, got %q", what, f->key, f->fixed, v);
            for (int32_t j = 0; j < len; j++)
                write_elem(f->kind, f->type, f->enumt, (char *) p + (size_t) j * size, items[j], what);
            break;
        }
        case JRL_FIELD_CHARS: {
            const uint8_t *bytes;
            if (!janet_bytes_view(v, &bytes, &len) || len >= f->fixed)
                janet_panicf("%s: field :%s expects a string shorter than %d bytes, got %q", what, f->key, f->fixed, v);
            memset(p, 0, (size_t) f->fixed);
            memcpy(p, bytes, (size_t) len);
            break;
        }
        default:
            janet_panicf("%s: field :%s cannot be replaced; mutate its elements instead", what, f->key);
    }
}

void jrl_from_janet(const JrlType *t, Janet v, void *out, const char *what) {
    if (t->shape == JRL_SHAPE_TUPLE) {
        tuple_from_janet(t, v, out, what);
        return;
    }
    if (t->shape == JRL_SHAPE_HANDLE) {
        memcpy(out, jrl_handle_ptr(v, t, what), t->size);
        return;
    }
    if (!janet_checktypes(v, JANET_TFLAG_DICTIONARY))
        janet_panicf("%s: expected %s as a struct or table, got %q", what, t->name, v);
    for (int32_t i = 0; i < t->field_count; i++) {
        const JrlField *f = &t->fields[i];
        if (f->shape == JRL_FIELD_HIDDEN) continue;
        Janet fv = janet_get(v, jrl_field_key(f));
        if (janet_checktype(fv, JANET_NIL))
            janet_panicf("%s: %s is missing field :%s", what, t->name, f->key);
        field_from_janet(f, out, fv, what);
    }
}

static Janet array_view(const JrlField *f, Janet owner, int32_t row);

static Janet field_to_janet(const JrlField *f, const void *base, Janet owner) {
    const void *p = (const char *) base + f->offset;
    switch (f->shape) {
        case JRL_FIELD_SCALAR:
            return read_elem(f->kind, f->type, p, owner);
        case JRL_FIELD_FIXED: {
            size_t size = kind_size(f->kind, f->type);
            Janet *tuple = janet_tuple_begin(f->fixed);
            for (int32_t j = 0; j < f->fixed; j++)
                tuple[j] = read_elem(f->kind, f->type, (const char *) p + (size_t) j * size, owner);
            return janet_wrap_tuple(janet_tuple_end(tuple));
        }
        case JRL_FIELD_CHARS: {
            const char *end = memchr(p, 0, (size_t) f->fixed);
            int32_t len = end ? (int32_t) (end - (const char *) p) : f->fixed;
            return janet_stringv(p, len);
        }
        case JRL_FIELD_POINTER:
        case JRL_FIELD_POINTER2:
            if (*(void *const *) p == NULL) return janet_wrap_nil();
            return array_view(f, owner, -1);
        case JRL_FIELD_BYTES: {
            const void *data = *(void *const *) p;
            if (data == NULL) return janet_wrap_nil();
            return jrl_wrap_bytes(data, f->count(base));
        }
        case JRL_FIELD_HIDDEN:
            break;
    }
    return janet_wrap_nil();
}

Janet jrl_to_janet(const JrlType *t, const void *p, Janet owner) {
    if (t->shape == JRL_SHAPE_TUPLE) return tuple_to_janet(t, p);
    if (t->shape == JRL_SHAPE_HANDLE) return jrl_handle_view(t, (void *) p, owner);
    int32_t visible = 0;
    for (int32_t i = 0; i < t->field_count; i++) visible += t->fields[i].shape != JRL_FIELD_HIDDEN;
    JanetKV *st = janet_struct_begin(visible);
    for (int32_t i = 0; i < t->field_count; i++) {
        const JrlField *f = &t->fields[i];
        if (f->shape == JRL_FIELD_HIDDEN) continue;
        janet_struct_put(st, jrl_field_key(f), field_to_janet(f, p, owner));
    }
    return janet_wrap_struct(janet_struct_end(st));
}

void jrl_get_value(const Janet *argv, int32_t n, const JrlType *t, void *out) {
    jrl_from_janet(t, argv[n], out, argument_label(n));
}

/* ---------------------------------------------------------------------------
 * Handles
 * ------------------------------------------------------------------------- */

int jrl_handle_gcmark(void *data, size_t len) {
    (void) len;
    janet_mark(((JrlHandle *) data)->owner);
    return 0;
}

Janet jrl_handle_new(const JrlType *t, const void *value, int borrowed) {
    JrlHandle *h = janet_abstract(t->at, JRL_STORAGE_OFFSET + t->size);
    h->type = t;
    h->ptr = (char *) h + JRL_STORAGE_OFFSET;
    h->owner = janet_wrap_nil();
    h->frames = 1;
    h->unloaded = 0;
    h->borrowed = (uint8_t) (borrowed != 0);
    h->view = 0;
    memcpy(h->ptr, value, t->size);
    return janet_wrap_abstract(h);
}

Janet jrl_handle_view(const JrlType *t, void *ptr, Janet owner) {
    JrlHandle *h = janet_abstract(t->at, sizeof(JrlHandle));
    h->type = t;
    h->ptr = ptr;
    h->owner = owner;
    h->frames = 1;
    h->unloaded = 0;
    h->borrowed = 1;
    h->view = 1;
    return janet_wrap_abstract(h);
}

void *jrl_handle_ptr(Janet x, const JrlType *t, const char *what) {
    JrlHandle *h = as_handle(x);
    if (h == NULL || h->type != t)
        janet_panicf("%s: expected %s, got %q", what, t->name, x);
    check_handle_live(h, what);
    return h->ptr;
}

void *jrl_get_handle(const Janet *argv, int32_t n, const JrlType *t) {
    return jrl_handle_ptr(argv[n], t, argument_label(n));
}

void *jrl_unload_handle(const Janet *argv, int32_t n, const JrlType *t) {
    JrlHandle *h = as_handle(argv[n]);
    if (h == NULL || h->type != t)
        janet_panicf("argument %d: expected %s, got %q", n, t->name, argv[n]);
    if (h->unloaded) janet_panicf("argument %d: %s was already unloaded", n, t->name);
    if (h->view) janet_panicf("argument %d: cannot unload a view into another resource's %s", n, t->name);
    if (h->borrowed) janet_panicf("argument %d: %s is owned by raylib or another resource and cannot be unloaded", n, t->name);
    return h->ptr;
}

void jrl_mark_unloaded(Janet x) {
    JrlHandle *h;
    JrlArray *a;
    if ((h = as_handle(x))) h->unloaded = 1;
    else if ((a = as_array(x))) a->unloaded = 1;
}

void jrl_adopt(Janet handle, Janet owner) {
    JrlHandle *h = as_handle(handle);
    if (h == NULL) return;
    h->borrowed = 1;
    h->owner = owner;
}

void jrl_handle_attach(Janet handle, Janet owner) {
    JrlHandle *h = as_handle(handle);
    if (h != NULL) h->owner = owner;
}

void jrl_handle_set_frames(Janet handle, int32_t frames) {
    JrlHandle *h = as_handle(handle);
    if (h != NULL && frames > 1) h->frames = frames;
}

/* A handle raylib owns itself (get-font-default), as opposed to one adopted
 * by or viewed through another resource. */
int jrl_handle_raylib_owned(Janet x) {
    JrlHandle *h = as_handle(x);
    return h != NULL && h->borrowed && !h->view && janet_checktype(h->owner, JANET_NIL);
}

static const JrlField *find_field(const JrlType *t, Janet key) {
    if (!janet_checktype(key, JANET_KEYWORD)) return NULL;
    const uint8_t *kw = janet_unwrap_keyword(key);
    for (int32_t i = 0; i < t->field_count; i++) {
        const JrlField *f = &t->fields[i];
        if (f->shape != JRL_FIELD_HIDDEN && !janet_cstrcmp(kw, f->key)) return f;
    }
    return NULL;
}

int jrl_handle_get(void *data, Janet key, Janet *out) {
    JrlHandle *h = data;
    const JrlField *f = find_field(h->type, key);
    if (f == NULL) return 0;
    check_handle_live(h, "field access");
    if (f->shape == JRL_FIELD_BYTES && h->frames > 1) {
        const void *bytes = *(void *const *) ((char *) h->ptr + f->offset);
        int64_t size = (int64_t) f->count(h->ptr) * h->frames;
        if (size > INT32_MAX) janet_panicf("%s :%s is too large for a Janet buffer", h->type->name, f->key);
        *out = bytes ? jrl_wrap_bytes(bytes, (int32_t) size) : janet_wrap_nil();
        return 1;
    }
    *out = field_to_janet(f, h->ptr, janet_wrap_abstract(h));
    return 1;
}

void jrl_handle_put(void *data, Janet key, Janet value) {
    JrlHandle *h = data;
    const JrlField *f = find_field(h->type, key);
    if (f == NULL) janet_panicf("%s has no field %q", h->type->name, key);
    check_handle_live(h, "field update");
    if (f->readonly) janet_panicf("%s field :%s is read-only", h->type->name, f->key);
    field_from_janet(f, h->ptr, value, h->type->name);
}

Janet jrl_handle_next(void *data, Janet key) {
    const JrlType *t = ((JrlHandle *) data)->type;
    int32_t start = 0;
    if (!janet_checktype(key, JANET_NIL)) {
        const JrlField *f = find_field(t, key);
        if (f == NULL) return janet_wrap_nil();
        start = (int32_t) (f - t->fields) + 1;
    }
    for (int32_t i = start; i < t->field_count; i++) {
        if (t->fields[i].shape != JRL_FIELD_HIDDEN) return jrl_field_key(&t->fields[i]);
    }
    return janet_wrap_nil();
}

void jrl_handle_tostring(void *data, JanetBuffer *buffer) {
    JrlHandle *h = data;
    if (h->unloaded) {
        janet_buffer_push_cstring(buffer, "unloaded");
        return;
    }
    if (!owner_live(h->owner)) {
        janet_buffer_push_cstring(buffer, "owner-unloaded");
        return;
    }
    int first = 1;
    if (h->view) {
        janet_buffer_push_cstring(buffer, "view");
        first = 0;
    }
    for (int32_t i = 0; i < h->type->field_count; i++) {
        const JrlField *f = &h->type->fields[i];
        if (f->shape != JRL_FIELD_SCALAR || f->kind == JRL_K_TYPE) continue;
        if (!first) janet_buffer_push_u8(buffer, ' ');
        first = 0;
        janet_formatb(buffer, "%s=%V", f->key, read_elem(f->kind, f->type, (char *) h->ptr + f->offset, janet_wrap_nil()));
    }
}

/* ---------------------------------------------------------------------------
 * Arrays
 * ------------------------------------------------------------------------- */

static JrlArray *array_new(void) {
    JrlArray *a = janet_abstract(&jrl_array_type, sizeof(JrlArray));
    memset(a, 0, sizeof(JrlArray));
    a->owner = janet_wrap_nil();
    a->row = -1;
    return a;
}

static Janet array_view(const JrlField *f, Janet owner, int32_t row) {
    JrlArray *a = array_new();
    a->kind = f->kind;
    a->type = f->type;
    a->enumt = f->enumt;
    a->owner = owner;
    a->field = f;
    a->row = row;
    a->readonly = (uint8_t) f->readonly;
    return janet_wrap_abstract(a);
}

Janet jrl_array_owned(JrlKind kind, const JrlType *t, void *ptr, int32_t count) {
    JrlArray *a = array_new();
    a->kind = kind;
    a->type = t;
    a->ptr = ptr;
    a->count = count;
    a->owned = 1;
    return janet_wrap_abstract(a);
}

static void *array_resolve(JrlArray *a, int32_t *count) {
    if (a->owned) {
        if (a->adopted) janet_panicf("array of %s was adopted by another resource", a->type ? a->type->name : "values");
        if (a->unloaded) janet_panicf("array of %s was already unloaded", a->type ? a->type->name : "values");
        *count = a->count;
        return a->ptr;
    }
    JrlHandle *owner = as_handle(a->owner);
    check_handle_live(owner, "array");
    void *base = owner->ptr;
    void *ptr = *(void **)((char *) base + a->field->offset);
    if (ptr == NULL) {
        *count = 0;
        return NULL;
    }
    if (a->row >= 0) {
        if (a->row >= a->field->count(base)) janet_panicf("array row %d no longer exists", a->row);
        *count = a->field->inner(base);
        return ((void **) ptr)[a->row];
    }
    *count = a->field->count(base);
    return ptr;
}

static int array_is_rows(const JrlArray *a) {
    return !a->owned && a->field->shape == JRL_FIELD_POINTER2 && a->row < 0;
}

static int jrl_array_gcmark(void *data, size_t len) {
    (void) len;
    janet_mark(((JrlArray *) data)->owner);
    return 0;
}

/* Integer index, or a member keyword for fields indexed by an enum
 * (material maps: :albedo is material-map-albedo). */
static int array_index(const JrlArray *a, Janet key, int32_t count, int32_t *index) {
    int32_t i;
    if (janet_checktype(key, JANET_KEYWORD) && !a->owned && a->field->index_enum) {
        i = (int32_t) enum_member(a->field->index_enum, key, "array index");
    } else if (janet_checkint(key)) {
        i = janet_unwrap_integer(key);
    } else {
        return 0;
    }
    if (i < 0 || i >= count) return 0;
    *index = i;
    return 1;
}

static int jrl_array_get(void *data, Janet key, Janet *out) {
    JrlArray *a = data;
    int32_t count, i;
    void *ptr = array_resolve(a, &count);
    if (!array_index(a, key, count, &i)) return 0;
    if (array_is_rows(a)) {
        *out = array_view(a->field, a->owner, i);
        return 1;
    }
    size_t size = kind_size(a->kind, a->type);
    *out = read_elem(a->kind, a->type, (char *) ptr + (size_t) i * size, janet_wrap_abstract(a));
    return 1;
}

static void jrl_array_put(void *data, Janet key, Janet value) {
    JrlArray *a = data;
    int32_t count, i;
    void *ptr = array_resolve(a, &count);
    if (a->readonly || array_is_rows(a) || a->kind == JRL_K_CSTRING)
        janet_panicf("array is read-only");
    if (!array_index(a, key, count, &i))
        janet_panicf("array index %q out of range [0, %d)", key, count);
    size_t size = kind_size(a->kind, a->type);
    write_elem(a->kind, a->type, a->enumt, (char *) ptr + (size_t) i * size, value, "array element");
}

static size_t jrl_array_length(void *data, size_t len) {
    (void) len;
    int32_t count;
    array_resolve(data, &count);
    return (size_t) count;
}

static Janet jrl_array_next(void *data, Janet key) {
    int32_t count;
    array_resolve(data, &count);
    if (janet_checktype(key, JANET_NIL)) return count > 0 ? janet_wrap_integer(0) : janet_wrap_nil();
    if (!janet_checkint(key)) return janet_wrap_nil();
    int32_t next = janet_unwrap_integer(key) + 1;
    return next < count ? janet_wrap_integer(next) : janet_wrap_nil();
}

static const char *kind_name(JrlKind kind, const JrlType *t) {
    switch (kind) {
        case JRL_K_INT: return "int";
        case JRL_K_UINT: return "unsigned int";
        case JRL_K_UCHAR: return "unsigned char";
        case JRL_K_USHORT: return "unsigned short";
        case JRL_K_FLOAT: return "float";
        case JRL_K_DOUBLE: return "double";
        case JRL_K_BOOL: return "bool";
        case JRL_K_CSTRING: return "string";
        case JRL_K_TYPE: return t->name;
    }
    return "?";
}

static void jrl_array_tostring(void *data, JanetBuffer *buffer) {
    JrlArray *a = data;
    if (!array_live(a)) {
        janet_buffer_push_cstring(buffer, "unloaded");
        return;
    }
    int32_t count;
    array_resolve(a, &count);
    janet_formatb(buffer, "%s%s[%d]", kind_name(a->kind, a->type), array_is_rows(a) ? "[]" : "", count);
}

static JrlArray *get_array_of(const Janet *argv, int32_t n, const JrlType *t) {
    JrlArray *a = as_array(argv[n]);
    if (a == NULL || a->kind != JRL_K_TYPE || a->type != t)
        janet_panicf("argument %d: expected an array of %s, got %q", n, t->name, argv[n]);
    return a;
}

void *jrl_unload_array(const Janet *argv, int32_t n, const JrlType *t, int32_t *count) {
    JrlArray *a = get_array_of(argv, n, t);
    if (!a->owned) janet_panicf("argument %d: cannot unload a view into another resource", n);
    if (a->adopted) janet_panicf("argument %d: array of %s was adopted by another resource", n, t->name);
    if (a->unloaded) janet_panicf("argument %d: array of %s was already unloaded", n, t->name);
    *count = a->count;
    return a->ptr;
}

void *jrl_get_handle_array(const Janet *argv, int32_t n, const JrlType *t, int32_t *count) {
    return array_resolve(get_array_of(argv, n, t), count);
}

/* ---------------------------------------------------------------------------
 * Constructors
 *
 * make-<type> builds a value the way C code writes (T){ .field = ... }:
 * omitted fields are zero. Arrays and bytes are copied into memory from
 * raylib's allocator, so the normal Unload* function frees them; a count
 * field left out is filled from its array's length. Handle fields (a
 * RenderTexture's textures) and owned arrays of handles (load-font-data's
 * glyphs) are adopted: the new value owns them afterwards. Everything is
 * converted and checked into scratch memory before anything is allocated
 * or adopted, so a bad argument leaves the inputs untouched.
 * ------------------------------------------------------------------------- */

#define JRL_MAKE_MAX_FIELDS 64

typedef struct {
    const JrlField *field;
    void *scratch;   /* converted contents, or NULL */
    size_t size;     /* bytes in scratch */
    JrlArray *moved; /* owned array whose memory the new value takes over */
} JrlPending;

static int32_t read_count(const JrlField *cf, const void *base) {
    const void *p = (const char *) base + cf->offset;
    return cf->kind == JRL_K_UINT ? (int32_t) *(const unsigned int *) p : *(const int *) p;
}

static void write_count(const JrlField *cf, void *base, int32_t n) {
    void *p = (char *) base + cf->offset;
    if (cf->kind == JRL_K_UINT) *(unsigned int *) p = (unsigned int) n;
    else *(int *) p = n;
}

static JrlHandle *adoptable(Janet v, const JrlType *t, const char *what, const char *key) {
    JrlHandle *h = as_handle(v);
    if (h == NULL || h->type != t) janet_panicf("%s: field :%s expects %s, got %q", what, key, t->name, v);
    check_handle_live(h, what);
    if (h->view || h->borrowed)
        janet_panicf("%s: field :%s: this %s is owned by raylib or another resource, so it cannot be adopted",
                     what, key, t->name);
    return h;
}

/* Element count of a pointer field's value, and its elements when they are
 * Janet values (items) or live C memory (a view's ptr). */
static int32_t field_value_count(const JrlField *f, Janet fv, const char *what,
                                 JrlArray **array, void **ptr, const Janet **items) {
    int32_t len;
    JrlArray *a = as_array(fv);
    *array = a;
    *ptr = NULL;
    *items = NULL;
    if (a != NULL) {
        if (a->kind != f->kind || a->type != f->type)
            janet_panicf("%s: field :%s expects %s elements, got %q", what, f->key, kind_name(f->kind, f->type), fv);
        *ptr = array_resolve(a, &len);
        return len;
    }
    if (!janet_indexed_view(fv, items, &len))
        janet_panicf("%s: field :%s expects a tuple or array, got %q", what, f->key, fv);
    return len;
}

Janet jrl_make(const JrlType *t, const Janet *argv, int32_t n) {
    const char *what = argument_label(n);
    Janet v = argv[n];
    if (!janet_checktypes(v, JANET_TFLAG_DICTIONARY))
        janet_panicf("%s: expected a struct or table of %s fields, got %q", what, t->name, v);
    if (t->field_count > JRL_MAKE_MAX_FIELDS) janet_panicf("%s has too many fields to build", t->name);

    const JanetKV *kvs;
    int32_t kv_len, kv_cap;
    janet_dictionary_view(v, &kvs, &kv_len, &kv_cap);
    for (int32_t i = 0; i < kv_cap; i++) {
        if (janet_checktype(kvs[i].key, JANET_NIL)) continue;
        const JrlField *f = find_field(t, kvs[i].key);
        if (f == NULL) janet_panicf("%s: %s has no field %q", what, t->name, kvs[i].key);
        if (f->shape == JRL_FIELD_POINTER2)
            janet_panicf("%s: %s field :%s cannot be built from Janet values", what, t->name, f->key);
    }

    void *base = janet_smalloc(t->size);
    memset(base, 0, t->size);
    uint8_t set[JRL_MAKE_MAX_FIELDS] = {0};
    JrlHandle *adopted[JRL_MAKE_MAX_FIELDS];
    int32_t adopted_count = 0;
    JrlPending pending[JRL_MAKE_MAX_FIELDS];
    int32_t pending_count = 0;

    /* Scalars first: the counts and sizes the pointer fields are checked against. */
    for (int32_t i = 0; i < t->field_count; i++) {
        const JrlField *f = &t->fields[i];
        if (f->shape != JRL_FIELD_SCALAR && f->shape != JRL_FIELD_FIXED && f->shape != JRL_FIELD_CHARS) continue;
        Janet fv = janet_get(v, jrl_field_key(f));
        if (janet_checktype(fv, JANET_NIL)) continue;
        if (f->shape == JRL_FIELD_SCALAR && f->kind == JRL_K_TYPE && f->type->shape == JRL_SHAPE_HANDLE) {
            JrlHandle *h = adoptable(fv, f->type, what, f->key);
            for (int32_t j = 0; j < adopted_count; j++)
                if (adopted[j] == h) janet_panicf("%s: the same %s is given for two fields", what, f->type->name);
            memcpy((char *) base + f->offset, h->ptr, f->type->size);
            adopted[adopted_count++] = h;
        } else {
            field_from_janet(f, base, fv, what);
        }
        set[i] = 1;
    }

    /* Counts not given explicitly come from the array lengths, which must agree. */
    for (int32_t i = 0; i < t->field_count; i++) {
        const JrlField *f = &t->fields[i];
        if (f->shape != JRL_FIELD_POINTER || f->count_field < 0) continue;
        Janet fv = janet_get(v, jrl_field_key(f));
        if (janet_checktype(fv, JANET_NIL)) continue;
        JrlArray *a;
        void *ptr;
        const Janet *items;
        int32_t len = field_value_count(f, fv, what, &a, &ptr, &items);
        const JrlField *cf = &t->fields[f->count_field];
        int32_t factor = f->count_factor;
        if (len % factor)
            janet_panicf("%s: field :%s needs a multiple of %d elements, got %d", what, f->key, factor, len);
        if (set[f->count_field]) {
            int32_t have = read_count(cf, base);
            if ((int64_t) have * factor != len)
                janet_panicf("%s: field :%s has %d elements, but :%s %d needs %d", what, f->key, len,
                             cf->key, have, have * factor);
        } else {
            write_count(cf, base, len / factor);
            set[f->count_field] = 1;
        }
    }

    /* Convert array and byte contents into scratch memory. */
    for (int32_t i = 0; i < t->field_count; i++) {
        const JrlField *f = &t->fields[i];
        if (f->shape != JRL_FIELD_POINTER && f->shape != JRL_FIELD_BYTES) continue;
        Janet fv = janet_get(v, jrl_field_key(f));
        if (janet_checktype(fv, JANET_NIL)) continue;
        JrlPending *p = &pending[pending_count++];
        p->field = f;
        p->scratch = NULL;
        p->size = 0;
        p->moved = NULL;
        int32_t need = f->count(base);
        if (need < 0) janet_panicf("%s: field :%s has a negative size", what, f->key);
        if (f->shape == JRL_FIELD_BYTES) {
            JanetByteView bytes;
            if (!janet_bytes_view(fv, &bytes.bytes, &bytes.len))
                janet_panicf("%s: field :%s expects a string or buffer, got %q", what, f->key, fv);
            if (bytes.len != need)
                janet_panicf("%s: field :%s needs %d bytes for the other fields, got %d", what, f->key, need, bytes.len);
            p->size = (size_t) need;
            p->scratch = janet_smalloc(need > 0 ? p->size : 1);
            memcpy(p->scratch, bytes.bytes, p->size);
            continue;
        }
        JrlArray *a;
        void *ptr;
        const Janet *items;
        int32_t len = field_value_count(f, fv, what, &a, &ptr, &items);
        if (len != need)
            janet_panicf("%s: field :%s needs %d elements, got %d", what, f->key, need, len);
        if (a != NULL && a->owned) {
            for (int32_t j = 0; j < pending_count - 1; j++)
                if (pending[j].moved == a) janet_panicf("%s: the same array is given for two fields", what);
            p->moved = a;
            continue;
        }
        if (f->kind == JRL_K_TYPE && f->type->shape == JRL_SHAPE_HANDLE)
            janet_panicf("%s: field :%s takes an owned array of %s from a Load* function, which the new %s adopts",
                         what, f->key, f->type->name, t->name);
        if (f->kind == JRL_K_CSTRING)
            janet_panicf("%s: field :%s cannot be built from Janet strings", what, f->key);
        size_t size = kind_size(f->kind, f->type);
        p->size = (size_t) need * size;
        p->scratch = janet_smalloc(p->size > 0 ? p->size : 1);
        if (ptr != NULL) {
            memcpy(p->scratch, ptr, p->size);
        } else {
            for (int32_t j = 0; j < len; j++)
                write_elem(f->kind, f->type, f->enumt, (char *) p->scratch + (size_t) j * size, items[j], what);
        }
    }

    /* Everything is valid: allocate, move, adopt. */
    Janet result = jrl_handle_new(t, base, 0);
    JrlHandle *rh = as_handle(result);
    janet_sfree(base);
    for (int32_t i = 0; i < pending_count; i++) {
        JrlPending *p = &pending[i];
        void **slot = (void **) ((char *) rh->ptr + p->field->offset);
        if (p->moved) {
            *slot = p->moved->ptr;
            p->moved->ptr = NULL;
            p->moved->unloaded = 1;
            p->moved->adopted = 1;
            continue;
        }
        if (p->size > 0) {
            *slot = RL_MALLOC(p->size);
            if (*slot == NULL) janet_panicf("out of memory building %s :%s", t->name, p->field->key);
            memcpy(*slot, p->scratch, p->size);
        }
        janet_sfree(p->scratch);
    }
    for (int32_t i = 0; i < adopted_count; i++) jrl_adopt(janet_wrap_abstract(adopted[i]), result);
    return result;
}

/* ---------------------------------------------------------------------------
 * Call-scoped conversions
 * ------------------------------------------------------------------------- */

void *jrl_get_carray(const Janet *argv, int32_t n, JrlKind kind, const JrlType *t,
                     const JrlEnum *e, int nullable, int32_t fixed, int32_t *count) {
    const Janet *items;
    int32_t len;
    if (nullable && janet_checktype(argv[n], JANET_NIL)) {
        *count = 0;
        return NULL;
    }
    if (!janet_indexed_view(argv[n], &items, &len))
        janet_panicf("argument %d: expected a tuple or array, got %q", n, argv[n]);
    /* raylib treats a count of 0 as "use the default count" and then reads
     * that many elements from a non-NULL pointer (LoadFontData), so an empty
     * array must reach C as NULL. */
    if (nullable && len == 0) {
        *count = 0;
        return NULL;
    }
    if (fixed > 0 && len != fixed)
        janet_panicf("argument %d: expected exactly %d elements, got %d", n, fixed, len);
    size_t size = kind_size(kind, t);
    char *out = janet_smalloc(len > 0 ? (size_t) len * size : 1);
    const char *what = argument_label(n);
    for (int32_t i = 0; i < len; i++) {
        if (kind == JRL_K_CSTRING) {
            if (!janet_checktypes(items[i], JANET_TFLAG_STRING | JANET_TFLAG_SYMBOL | JANET_TFLAG_KEYWORD))
                janet_panicf("%s: element %d must be a string, got %q", what, i, items[i]);
            ((const char **) out)[i] = (const char *) janet_unwrap_string(items[i]);
        } else {
            write_elem(kind, t, e, out + (size_t) i * size, items[i], what);
        }
    }
    *count = len;
    return out;
}

JanetByteView jrl_get_bytes(const Janet *argv, int32_t n, int nullable) {
    JanetByteView view = {NULL, 0};
    if (nullable && janet_checktype(argv[n], JANET_NIL)) return view;
    if (!janet_bytes_view(argv[n], &view.bytes, &view.len))
        janet_panicf("argument %d: expected a string or buffer, got %q", n, argv[n]);
    return view;
}

void *jrl_get_raw_pointer(const Janet *argv, int32_t n) {
    const uint8_t *bytes;
    int32_t len;
    if (janet_checktype(argv[n], JANET_NIL)) return NULL;
    if (janet_checktype(argv[n], JANET_POINTER)) return janet_unwrap_pointer(argv[n]);
    if (janet_bytes_view(argv[n], &bytes, &len)) return (void *) bytes;
    janet_panicf("argument %d: expected nil, a pointer, or a buffer, got %q", n, argv[n]);
}

/* Element kind (0 float, 1 int, 2 unsigned) and component count of a uniform type. */
static void uniform_layout(int family, int type, int *elem, int *components) {
    if (type >= 0 && type <= 3) {
        *elem = 0;
        *components = type + 1;
        return;
    }
    if (family != JRL_UNIFORM_ATTRIB && type >= 4 && type <= 7) {
        *elem = 1;
        *components = type - 3;
        return;
    }
    if (family == JRL_UNIFORM_RLGL && type >= RL_SHADER_UNIFORM_UINT && type <= RL_SHADER_UNIFORM_UIVEC4) {
        *elem = 2;
        *components = type - RL_SHADER_UNIFORM_UINT + 1;
        return;
    }
    if (family == JRL_UNIFORM_RLGL && type == RL_SHADER_UNIFORM_SAMPLER2D) {
        *elem = 1;
        *components = 1;
        return;
    }
    janet_panicf("unsupported uniform data type %d", type);
}

static void uniform_write(int elem, void *out, int32_t index, Janet v, const char *what) {
    if (elem == 0) ((float *) out)[index] = (float) number_of(v, what);
    else if (elem == 1) ((int *) out)[index] = (int) integer_in(v, INT32_MIN, INT32_MAX, what);
    else ((unsigned int *) out)[index] = (unsigned int) integer_in(v, 0, UINT32_MAX, what);
}

void *jrl_get_uniform(const Janet *argv, int32_t n, int family, int type, int count) {
    int elem, components;
    uniform_layout(family, type, &elem, &components);
    if (count < 1) janet_panicf("uniform count must be positive, got %d", count);
    int32_t total = components * count;
    void *out = janet_smalloc((size_t) total * 4);
    const char *what = argument_label(n);
    Janet v = argv[n];
    const uint8_t *bytes;
    const Janet *items;
    int32_t len;
    if (janet_checktype(v, JANET_NUMBER)) {
        if (total != 1) janet_panicf("%s: uniform needs %d values, got one number", what, total);
        uniform_write(elem, out, 0, v, what);
        return out;
    }
    if (janet_checktypes(v, JANET_TFLAG_BYTES) && janet_bytes_view(v, &bytes, &len)) {
        if (len != total * 4) janet_panicf("%s: uniform needs %d bytes, got %d", what, total * 4, len);
        memcpy(out, bytes, (size_t) len);
        return out;
    }
    if (!janet_indexed_view(v, &items, &len))
        janet_panicf("%s: expected a number, tuple, or buffer for the uniform, got %q", what, v);
    if (len == total) {
        for (int32_t i = 0; i < len; i++) uniform_write(elem, out, i, items[i], what);
        return out;
    }
    if (len == count) {
        for (int32_t i = 0; i < len; i++) {
            const Janet *inner;
            int32_t inner_len;
            if (!janet_indexed_view(items[i], &inner, &inner_len) || inner_len != components)
                janet_panicf("%s: uniform element %d needs %d values, got %q", what, i, components, items[i]);
            for (int32_t j = 0; j < components; j++) uniform_write(elem, out, i * components + j, inner[j], what);
        }
        return out;
    }
    janet_panicf("%s: uniform needs %d values (or %d vectors of %d), got %d", what, total, count, components, len);
}

/* ---------------------------------------------------------------------------
 * Returned C memory
 * ------------------------------------------------------------------------- */

Janet jrl_wrap_carray(JrlKind kind, const JrlType *t, const void *ptr, int32_t count) {
    if (ptr == NULL) return janet_wrap_nil();
    size_t size = kind_size(kind, t);
    Janet *tuple = janet_tuple_begin(count);
    for (int32_t i = 0; i < count; i++)
        tuple[i] = read_elem(kind, t, (const char *) ptr + (size_t) i * size, janet_wrap_nil());
    return janet_wrap_tuple(janet_tuple_end(tuple));
}

Janet jrl_wrap_bytes(const void *ptr, int32_t size) {
    if (ptr == NULL) return janet_wrap_nil();
    JanetBuffer *b = janet_buffer(size);
    janet_buffer_push_bytes(b, ptr, size);
    return janet_wrap_buffer(b);
}
