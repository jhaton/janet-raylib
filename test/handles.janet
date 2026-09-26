# Resource handles, field views, and unload guards. Runs without a window.
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

# fields and in-place edits
(def image (rl/gen-image-color 4 2 :red))
(check "fields read by keyword" [(image :width) (image :height) (image :format)]
       [4 2 rl/pixelformat-uncompressed-r8g8b8a8])
(check "keys lists visible fields" (keys image) @[:data :width :height :mipmaps :format])
(check "data is a byte copy sized from the pixel format" (length (image :data)) 32)
(check-error "fields that size memory are read-only" (put image :width 8) "Image field :width is read-only")
(def copy (rl/image-copy image))
(rl/image-resize copy 8 4)
(check "T* parameters edit the handle in place" [(copy :width) (image :width)] [8 4])
(rl/image-draw-pixel image 0 0 :blue)
(check "drawing into an image" (take 2 (rl/load-image-colors image)) [[0 121 241 255] [230 41 55 255]])

# unload guards
(rl/unload-image image)
(check "handle-live? after unload" [(rl/handle-live? image) (rl/handle-live? copy)] [false true])
(check-error "field access after unload" (image :width) "Image was already unloaded")
(check-error "call after unload" (rl/image-copy image) "Image was already unloaded")
(check-error "second unload" (rl/unload-image image) "already unloaded")
(check "unloaded handles print as unloaded" (string image) "unloaded")
(check-error "type checking" (rl/unload-image (rl/load-directory-files "test/fixtures")) "expected Image")
(rl/unload-image copy)

# arrays viewing handle memory
(def files (rl/load-directory-files "test/fixtures"))
(def paths (files :paths))
(check "array length follows the owner's count field" (length paths) (files :count))
(check "arrays iterate" (sort (map |(last (string/split "/" $)) paths)) @["a.txt" "b.txt"])
(check "out-of-range index is absent" (get paths 99) nil)
(check-error "string arrays are read-only" (put paths 0 "x") "read-only")
(check-error "count fields are read-only" (put files :count 99) "read-only")
(rl/unload-directory-files files)
(check-error "views die with their owner" (length paths) "unloaded")
(check "views report not live" (rl/handle-live? paths) false)

(if (zero? failures) (print "handles: ok") (do (eprintf "handles: %d failure(s)" failures) (os/exit 1)))
