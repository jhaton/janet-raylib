# Value conversion across the C boundary. Runs without a window.
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

# tuple types
(check "vector2 tuple round trip" (rl/vector2-add [1 2] [3 4]) [4 6])
(check "vector arrays accepted" (rl/vector3-add @[1 2 3] @[1 1 1]) [2 3 4])
(check "matrix is 16 floats in raylib field order"
       (rl/matrix-translate 1 2 3) [1 0 0 1 0 1 0 2 0 0 1 3 0 0 0 1])
(check-error "vector wrong width" (rl/vector2-add [1 2 3] [0 0]) "expected Vector2 as a tuple of 2 numbers")
(check-error "vector non-number" (rl/vector2-add [1 :x] [0 0]) "expected number")

# colors
(check "color keyword" (rl/color-to-int :ray-white) (rl/color-to-int [245 245 245 255]))
(check "color 3-tuple defaults alpha to 255" (rl/color-to-int [1 2 3]) (rl/color-to-int [1 2 3 255]))
(check "color returned as tuple" (rl/fade :red 0.5) [230 41 55 127])
(check-error "color component range" (rl/color-to-int [256 0 0]) "range [0, 255]")
(check-error "unknown color keyword" (rl/color-to-int :no-such-color) "unknown color :no-such-color")

# plain structs
(def camera {:position [0 2 4] :target [0 0 0] :up [0 1 0] :fovy 45 :projection :perspective})
(check "struct in, struct out; enum field keyword stored as integer"
       (rl/update-camera-pro camera [0 0 0] [0 0 0] 0)
       {:position [0 2 4] :target [0 0 0] :up [0 1 0] :fovy 45 :projection rl/camera-perspective})
(check "tables accepted for structs"
       ((rl/update-camera-pro (table ;(kvs camera)) [0 0 0] [0 0 0] 0) :fovy) 45)
(check-error "struct missing field" (rl/update-camera-pro {:position [0 0 0]} [0 0 0] [0 0 0] 0)
             "Camera3D is missing field :target")
(check "bounding box struct" (rl/check-collision-boxes {:min [0 0 0] :max [2 2 2]} {:min [1 1 1] :max [3 3 3]}) true)

# enums and constants
(check "enum keyword equals member constant"
       (rl/get-pixel-data-size 2 2 :uncompressed-r8g8b8a8)
       (rl/get-pixel-data-size 2 2 rl/pixelformat-uncompressed-r8g8b8a8))
(check "enum integers pass through" (rl/get-pixel-data-size 2 2 7) 16)
(check-error "unknown enum keyword" (rl/get-pixel-data-size 2 2 :nope) "unknown PixelFormat member :nope")
(check "defines are constants" [rl/key-a rl/rl-triangles rl/raylib-version] [65 4 "5.5"])
(check "deprecated alias bound to the same function" rl/get-mouse-ray rl/get-screen-to-world-ray)

# out and inout parameters
(check "bool result plus out point" (rl/check-collision-lines [0 0] [2 2] [0 2] [2 0]) [true [1 1]])
(check "out params only" (rl/quaternion-to-axis-angle (rl/quaternion-identity)) [[1 0 0] 0])
(check "inout parameters returned updated" (rl/vector3-ortho-normalize [1 0 0] [1 1 0]) [[1 0 0] [0 1 0]])

# arrays in
(check "point tuple array fills the count parameter"
       (rl/check-collision-point-poly [1 1] [[0 0] [2 0] [2 2] [0 2]]) true)
(check "string arrays" (rl/text-join ["a" "b" "c"] "-") "a-b-c")
(check-error "string array element type" (rl/text-join ["a" 1] "-") "element 1 must be a string")
(check-error "array argument type" (rl/check-collision-point-poly [1 1] 5) "expected a tuple or array")

# bytes
(check "buffer written in place"
       (let [b (buffer/new-filled 4)] (rl/set-pixel-color b :blue :uncompressed-r8g8b8a8) b)
       @"\0y\xF1\xFF")
(check "bytes read" (rl/get-pixel-color "\x01\x02\x03\x04" :uncompressed-r8g8b8a8) [1 2 3 4])
(check-error "minimum byte length enforced" (rl/get-pixel-color "ab" :uncompressed-r8g8b8a8)
             "expected at least 4 bytes, got 2")

# C memory returned and freed by the binding
(check "codepoints round trip" (rl/load-utf8 (rl/load-codepoints "héllo")) "héllo")
(check "base64 round trip" (string (rl/decode-data-base64 (rl/encode-data-base64 "hello"))) "hello")
(check "compression round trip"
       (string (rl/decompress-data (rl/compress-data (string/repeat "ab" 64)))) (string/repeat "ab" 64))
(check "static string arrays" (rl/text-split "a,b,c" ",") ["a" "b" "c"])
(check "sized unsigned arrays" (length (rl/compute-sha1 "abc")) 5)

# argument checking
(check-error "arity" (rl/vector2-add [1 2]) "arity mismatch")
(check-error "strict booleans" (rl/image-flip-vertical nil) "expected Image")

(if (zero? failures) (print "values: ok") (do (eprintf "values: %d failure(s)" failures) (os/exit 1)))
