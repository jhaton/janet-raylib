(declare-project
  :name "janet-raylib"
  :description "Generated Janet bindings for raylib 5.5 (raylib.h, raymath.h, rlgl.h)"
  :version "0.1.0")

# The Makefile is the source of truth for development builds; this declaration
# builds the same sources for janet-pm installs. raylib is compiled from the
# vendor/raylib submodule (git submodule update --init).

(def- raylib-sources
  (map |(string "vendor/raylib/src/" $ ".c")
       ["rcore" "rshapes" "rtextures" "rtext" "rmodels" "raudio" "utils" "rglfw"]))

(def- binding-sources
  ["src/jrl.c" "src/manual.c" "src/register.c" "src/module.c"
   "src/gen/types.c" "src/gen/raylib.c" "src/gen/raymath.c" "src/gen/rlgl.c"])

(def- os-defines
  (case (os/which)
    :linux {"_GLFW_X11" true}
    {}))

(def- os-lflags
  (case (os/which)
    :linux ["-lm" "-lpthread" "-ldl"]
    :macos ["-framework" "OpenGL" "-framework" "Cocoa" "-framework" "IOKit"
            "-framework" "CoreAudio" "-framework" "CoreVideo"]
    []))

(declare-native
  :name "raylib/native"
  :source [;binding-sources ;raylib-sources]
  :defines (merge {"PLATFORM_DESKTOP_GLFW" true "GRAPHICS_API_OPENGL_33" true "_GNU_SOURCE" true}
                  os-defines)
  :cflags ["-std=gnu99" "-Isrc" "-Iinclude" "-Ivendor/raylib/src"
           "-Ivendor/raylib/src/external/glfw/include"]
  :lflags os-lflags)

(declare-source
  :prefix "raylib"
  :source ["lib/raylib/init.janet"])
