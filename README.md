# janet-raylib

Janet bindings for [raylib](https://www.raylib.com/) 5.5, generated from raylib's own API description. They cover `raylib.h`, `raymath.h`, and `rlgl.h`.

| Header | Functions | Bound | Excluded |
|---|---|---|---|
| raylib.h | 581 | 557 | 24 |
| raymath.h | 143 | 143 | 0 |
| rlgl.h | 156 | 152 | 4 |

Eight of the exclusions are `Unload*` functions for memory the binding frees itself. The remaining 20 are C callbacks, varargs, raw allocation, and rlgl calls that keep a pointer after they return. [API.md](API.md) gives the reason for each exclusion and lists every Janet signature. Log messages, the one callback worth having, are covered by `set-trace-log-capture` (see [Logging](#logging)).

The binding produces a Janet native module plus a static library that embeds raylib, the bindings, and the Janet layer into a C program.

Quick reference cards in the style of raylib's cheatsheet live in [`docs/`](docs/index.html): raylib (with janet-raylib's extras, value rules, structs, colors, and enum keywords), raymath, and rlgl. Hover a line for its C signature and conversion notes, and press `/` to filter.

## Layout

```text
api/*.jdn          raylib's API description (raylib_parser JSON -> JDN), committed
overrides.jdn      the policy headers cannot express: ownership, sizes, enums, exclusions
gen/gen.janet      generator: api + overrides -> src/gen/*.c and API.md
gen/cheatsheet.janet  the same plans -> docs/*.html quick reference cards
src/jrl.{h,c}      hand-written runtime: conversions, guarded handles, array views
src/manual.c       the few functions the generator cannot express
lib/raylib/        thin Janet layer: with-* forms for Begin/End pairs
include/           janet_raylib.h, for embedding
vendor/raylib      raylib 5.5 submodule
```

## Build

Requirements: a C compiler, [mise](https://mise.jdx.dev/) (it pins Janet 1.42.1), and on Linux the X11 development headers that GLFW needs. raylib is compiled from the submodule, so no system raylib is used.

```sh
git submodule update --init
mise install
mise exec -- make          # build/lib/raylib/{native.so,init.janet} and build/libjanet-raylib.a
mise exec -- make test     # headless tests
mise exec -- make smoke    # opens a hidden window, draws 2D/3D/shader/render-texture, writes build/smoke.png
mise exec -- make embed    # builds and runs examples/embed/main.c against the static library
```

Run scripts against the development build with `JANET_PATH=build/lib janet script.janet`.

To install with janet-pm instead, run `janet-pm install`. It compiles the same sources that `project.janet` declares.

raylib is built for OpenGL 3.3, with HDR image loading enabled. Set `JANET_RAYLIB_OPENGL=43` (for `make`, or in the environment of `janet-pm install`) to build for OpenGL 4.3 instead, which makes rlgl's compute shaders and shader storage buffers work. It needs a 4.3 driver, which macOS doesn't have. `make` rebuilds raylib when the setting changes.

## Using it

```janet
(import raylib :as rl)

(rl/with-window 800 450 "hello"
  (rl/set-target-fps 60)
  (with [texture (rl/load-texture "atlas.png") rl/unload-texture]
    (while (not (rl/window-should-close))
      (rl/with-drawing
        (rl/clear-background :ray-white)
        (rl/draw-texture texture 10 10 :white)
        (when (rl/key-down? :space)
          (rl/draw-text "space" 10 400 20 :maroon))))))
```

`raylib` re-exports every generated binding from `raylib/native` and adds a few scoped forms: `with-window`, `with-audio-device`, `with-drawing`, `with-mode-2d`, `with-mode-3d`, `with-texture-mode`, `with-shader-mode`, `with-blend-mode`, `with-scissor-mode`, `with-vr-stereo-mode`, and `with-matrix`. The closing call runs even if the body raises an error.

### Names

Every function name follows the same rule:

- kebab-case of the C name;
- `IsX` functions that return `bool` become `x?`;
- digits stay with the word they number, except in 2D/3D;
- the `rl` prefix of rlgl functions becomes `rl-`.

Examples: `key-down?`, `draw-texture-n-patch`, `begin-mode-2d`, `vector2-dot-product`, `rl-vertex2f`, `rlgl-init`. Enum members and `#define`s become constants with the same kebab rule (`key-a`, `flag-vsync-hint`, `pi`, `raylib-version`). `get-mouse-ray` remains as raylib's deprecated alias.

`load-image` shadows Janet's core `load-image` under `(use raylib)`. Prefer `(import raylib :as rl)`.

### Values

| C | Janet in | Janet out |
|---|---|---|
| `Vector2/3/4`, `Quaternion`, `Rectangle` | tuple or array of numbers | tuple |
| `Matrix` | 16 numbers in raylib's field order (`m0 m4 m8 m12 m1 …`, i.e. row-major) | tuple |
| `Color` | `[r g b]`, `[r g b a]`, or a keyword such as `:ray-white` or `:dark-blue` | `[r g b a]` |
| plain structs (`Camera3D`, `Ray`, `BoundingBox`, `NPatchInfo`, …) | struct or table with kebab keys; every field is required | struct |
| enum `int` parameters | integer or member keyword (`:a`, `:left`, `:perspective`) | integer |
| flag parameters (`ConfigFlags`, `Gesture`) | integer, keyword, or a tuple of keywords (OR-ed) | integer |
| `bool` | `true`/`false` only (Janet treats `0` as truthy) | boolean |
| `unsigned int` | integer `0`…`4294967295`; `get-color` also takes the negative packed colors `color-to-int` returns, as C converts them | number |

`set-shader-value` and `set-shader-value-v` take rlgl's uniform types (`:float` … `:ivec4`, `:uint` … `:uivec4`, `:sampler2d`), because raylib passes the type straight to `rlSetUniform`. The integer constant `shader-uniform-sampler2d` (8) is rlgl's `uint` in raylib 5.5, so it fails for samplers in C too; use `:sampler2d`.

Pointer parameters follow the rules in `overrides.jdn`:

- **Arrays** (`const Vector2 *points, int pointCount`): pass a tuple. The count parameter disappears from the Janet signature. Where C accepts `NULL` (such as the codepoints of `load-font-data`), `nil` and an empty tuple both pass `NULL`.
- **Byte data** (`const void *data, int dataSize`): pass a string or buffer. Where raylib reads a fixed amount (such as `update-texture`), the length is checked first.
- **Outputs**: returned instead of passed. A function with a return value and outputs returns a tuple, e.g. `(check-collision-lines a b c d)` → `[true [1 1]]`.
- **In/out** (`UpdateCamera(Camera *camera, int mode)`): the updated value is returned, so write `(set camera (rl/update-camera camera :orbital))`.
- **Returned C memory** (`load-image-colors`, `load-file-data`, `load-codepoints`, …): copied into Janet and freed immediately.

### Resources

Images, textures, fonts, meshes, shaders, materials, models, animations, waves, sounds, music, and file lists are handles: abstract values that own their C struct.

- **Explicit unload.** The garbage collector never frees GPU or audio memory, since it could run after `close-window`. Call the matching `unload-*` function, or scope the resource with Janet's `with`.
- **Guarded.** Using a handle after unloading it, or unloading it twice, raises a Janet error instead of crashing. `(handle-live? x)` checks without raising. Handles raylib owns (`get-font-default`, `get-shapes-texture`) cannot be unloaded; `unload-font` on the default font does nothing, as in C.
- **Fields.** Handles expose their fields by keyword: `(texture :width)`, `(keys model)`. Writable fields accept `put`, e.g. `(put model :transform (rl/matrix-rotate-y 0.6))` or `(put music :looping false)`. Fields that size memory (`:width` of an image, `:mesh-count`, …) are read-only.
- **Views.** Struct-valued and array fields return views into the owner's memory: `(model :materials)`, `(get-in model [:materials 0 :maps 0 :texture])`, `(shader :locs)`, `(font :glyphs)`. Views support `get`, `put`, `length`, and `each`. They die with their owner, and they cannot be unloaded on their own. Material maps also take `MaterialMapIndex` keywords: `(get-in model [:materials 0 :maps :albedo])`.
- **Adoption.** `load-model-from-mesh` takes ownership of its mesh, so unloading the mesh afterwards raises an error. `load-sound-alias` keeps its source sound tied to the alias.
- **Arrays of resources.** `load-model-animations` and `load-font-data` return arrays that are freed by `unload-model-animations` and `unload-font-data`. `load-materials` returns an array freed by `unload-materials`.
- **Animated images.** `(load-image-anim path)` returns `[image frames]`, and the image's `:data` holds every frame, as C's `image.data` does. Pass one frame to `update-texture` with `(buffer/slice data offset (+ offset frame-size))`.

#### Constructors

C code sometimes fills a struct by hand, e.g. a texture around an id from `rlLoadTextureDepth`, or a mesh from vertex arrays. `make-texture`, `make-render-texture`, `make-mesh`, `make-font`, `make-image`, and `make-wave` do that. Each takes a struct or table of fields, like C's `(Mesh){ .vertexCount = 3, ... }`:

```janet
(def mesh (rl/make-mesh {:triangle-count 1
                         :vertices [0 0 0  1 0 2  2 0 0]
                         :normals [0 1 0  0 1 0  0 1 0]
                         :texcoords [0 0  0.5 1  1 0]}))   # :vertex-count 3 comes from :vertices
(rl/upload-mesh mesh false)

(def depth (rl/make-texture {:id (rl/rl-load-texture-depth w h false)
                             :width w :height h :mipmaps 1 :format 19}))
(def target (rl/make-render-texture {:id fbo :texture color :depth depth}))  # adopts both textures
```

- Omitted fields are zero, as in C; unknown fields are errors.
- Arrays (tuples, arrays, or views into another handle) and bytes are copied into memory from raylib's allocator, so the usual `unload-*` function frees them. A count field you leave out is taken from its array's length; arrays that share a count must agree. Mesh arrays are flat: three numbers per vertex for `:vertices`.
- Handle fields (`:texture`, `:depth`) and an owned array of handles (`load-font-data`'s glyphs for `make-font`) are adopted: afterwards only the new value can unload them.
- Everything is checked before anything is allocated or adopted, so a failed call leaves its arguments as they were.
- `make-image` copies one mip level; set `:mipmaps 1` for ordinary images.

The binding does not model raylib's implicit sharing between materials and the textures and shaders they reference. As in C, `unload-model` frees the meshes and material arrays but not the materials' shaders or textures. `unload-material` does unload its shader and every non-default map texture, including ones you attached with `set-material-texture`.

`(unload-model-resources model &opt keep)` unloads a model together with its textures. Use it for models loaded from files, whose textures `unload-model` would otherwise leak.

- Each distinct non-default texture is unloaded once, even when several maps share it.
- Pass textures you still own in `keep`, e.g. `(unload-model-resources model [my-texture])`. Any texture it unloads is gone even if a Janet handle to it remains, so a later `unload-texture` on that handle deletes the OpenGL id a second time.
- Material shaders are never unloaded, because raylib's loaders don't create them.
- Returns the number of textures unloaded.

### Logging

raylib logs from its audio thread as well as the main thread, so a Janet log callback cannot be allowed. Instead, `(set-trace-log-capture true)` queues messages in C, and `(take-trace-logs)` drains them as `[level message]` tuples, oldest first.

- `set-trace-log-level` still filters what gets logged.
- The queue keeps the newest 512 messages. When older ones were dropped, the first entry says how many.
- `(set-trace-log-capture false)` restores raylib's own printing.

```janet
(rl/set-trace-log-capture true)
# ... once per frame:
(each [level message] (rl/take-trace-logs)
  (when (>= level rl/log-warning) (eprint message)))
```

## Embedding in C

```c
#include "janet_raylib.h"

janet_init();
JanetTable *env = janet_core_env(NULL);
janet_raylib_preload(env);                 /* (import raylib) now works with no files */
janet_dostring(env, "(import raylib :as rl) ...", "main", NULL);
```

Link `build/libjanet-raylib.a` (the bindings, the Janet layer, and raylib), `libjanet.a`, and `-lm -lpthread -ldl`. `janet_raylib_register(env)` defines the bindings directly into a table instead. [examples/embed/main.c](examples/embed/main.c) is a complete program.

## Regenerating

```sh
mise exec -- make api        # api/*.jdn from the submodule's headers (after bumping vendor/raylib)
mise exec -- make gen        # src/gen/*.c, API.md, and docs/*.html
mise exec -- make check-gen  # fails if the committed generated files are stale
```

The generator stops and lists every pointer parameter, pointer field, or pointer return that neither a rule nor `overrides.jdn` explains. A raylib version bump therefore shows up as reviewable diffs in `api/`, `src/gen/`, and `API.md`, plus a list of new signatures that need a policy decision.

### Cheatsheets on GitHub Pages

`docs/` is a static site with no build step: generated HTML plus `style.css`, `cheatsheet.js`, and `.nojekyll`. To publish it, set Settings → Pages → Source to "Deploy from a branch", branch `main`, folder `/docs`.

## Platform notes

- Linux builds GLFW's X11 backend, which also runs under XWayland. The Wayland backend needs `wayland-scanner`-generated protocol headers and is not built.
- The Makefile and `project.janet` have macOS branches, but they are untested.
