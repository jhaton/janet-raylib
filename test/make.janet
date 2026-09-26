# make-<type> constructors, animated images, and raylib-owned unloads. Runs without a window.
(import raylib :as rl)

(var failures 0)
(defmacro check [what expr expected]
  ~(let [actual (try ,expr ([err] [:error err]))]
     (unless (deep= actual ,expected)
       (++ failures)
       (eprintf "FAIL %s\n  expected %q\n  got      %q" ,what ,expected actual))))
(defmacro check-error [what expr pattern]
  ~(let [result (try (do ,expr :no-error) ([err] err))]
     (unless (and (string? result) (string/find ,pattern result))
       (++ failures)
       (eprintf "FAIL %s\n  expected error containing %q\n  got %q" ,what ,pattern result))))

# bytes fields are sized by the scalar fields
(def image (rl/make-image {:data (string/repeat "\x01\x02\x03\xff" 6) :width 3 :height 2 :mipmaps 1
                           :format :uncompressed-r8g8b8a8}))
(check "image built around pixel data" [(image :width) (rl/get-image-color image 2 1)] [3 [1 2 3 255]])
(check-error "byte size must match the fields" (rl/make-image {:data "abc" :width 3 :height 2 :format 7})
             "field :data needs 24 bytes for the other fields, got 3")
(check-error "unknown fields are errors" (rl/make-image {:width 1 :colour 2}) "Image has no field :colour")
(check "omitted fields are zero, as in C" [((rl/make-image {}) :width) ((rl/make-image {}) :data)] [0 nil])
(rl/unload-image image)

# array fields fill their count fields, or are checked against them
(def mesh (rl/make-mesh {:vertices [0 0 0 1 0 2 2 0 0] :texcoords [0 0 0.5 1 1 0] :triangle-count 1}))
(check "count filled from the array" [(mesh :vertex-count) (length (mesh :texcoords))] [3 6])
(check-error "arrays sharing a count must agree"
             (rl/make-mesh {:vertices [0 0 0 1 1 1] :normals [0 1 0]})
             "field :normals has 3 elements, but :vertex-count 2 needs 6")
(check-error "explicit count must match" (rl/make-mesh {:vertex-count 2 :vertices [0 0 0]})
             ":vertex-count 2 needs 6")
(check-error "flat arrays come in whole units" (rl/make-mesh {:vertices [0 0 0 1]})
             "needs a multiple of 3 elements, got 4")
(def copy (rl/make-mesh {:vertices (mesh :vertices)}))
(check "views are copied, not shared" (do (put (copy :vertices) 0 9) [((copy :vertices) 0) ((mesh :vertices) 0)]) [9 0])
(rl/unload-mesh copy)
(rl/unload-mesh mesh)

# owned arrays of handles are adopted whole; a failed make adopts nothing
(def glyphs (rl/load-font-data (slurp "vendor/raylib/examples/text/resources/anonymous_pro_bold.ttf") 16 nil :default))
(check-error "counts are checked before anything is adopted"
             (rl/make-font {:glyphs glyphs :recs [[0 0 1 1]]}) "field :glyphs has 95 elements, but :glyph-count 1")
(check "a failed make leaves its inputs usable" (length glyphs) 95)
(def font (rl/make-font {:base-size 16 :glyphs glyphs}))
(check "the font owns the glyphs" [(font :glyph-count) ((get (font :glyphs) 33) :value)] [95 65])
(check-error "an adopted array cannot be unloaded" (rl/unload-font-data glyphs) "adopted by another resource")
(check-error "handle elements cannot be copied out of another resource's view"
             (rl/make-font {:glyphs (font :glyphs)}) "takes an owned array of GlyphInfo")

# animated images: :data spans every frame
(def [anim frames] (rl/load-image-anim "vendor/raylib/examples/textures/resources/scarfy_run.gif"))
(check "anim data covers all frames" (length (anim :data)) (* (anim :width) (anim :height) 4 frames))
(def first-frame (rl/image-copy anim))
(check "a copy holds the first frame only" (length (first-frame :data)) (* (anim :width) (anim :height) 4))
(rl/unload-image first-frame)
(rl/unload-image anim)

# raylib-owned handles: unload-font leaves the default font alone, as C does
(check "unloading the default font is a no-op" (rl/unload-font (rl/get-font-default)) nil)
(check-error "other raylib-owned handles still refuse" (rl/unload-texture (rl/get-shapes-texture)) "cannot be unloaded")

(if (zero? failures) (print "make: ok") (do (eprintf "make: %d failure(s)" failures) (os/exit 1)))
