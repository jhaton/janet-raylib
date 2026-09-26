# The naming rule: kebab-case, IsX -> x? for bool returns, digits stay with the
# word they number except in 2D/3D, rl prefix kept as rl-.
(import raylib :as rl)

(def expected
  {"IsKeyDown" 'key-down?
   "WindowShouldClose" 'window-should-close
   "GetFPS" 'get-fps
   "ColorToHSV" 'color-to-hsv
   "DrawTextureNPatch" 'draw-texture-n-patch
   "BeginMode2D" 'begin-mode-2d
   "GetScreenToWorld2D" 'get-screen-to-world-2d
   "DrawCircle3D" 'draw-circle-3d
   "Vector2DotProduct" 'vector2-dot-product
   "MatrixRotateXYZ" 'matrix-rotate-xyz
   "LoadUTF8" 'load-utf8
   "ComputeSHA1" 'compute-sha1
   "rlVertex2f" 'rl-vertex2f
   "rlColor4ub" 'rl-color4ub
   "rlglInit" 'rlgl-init
   "rlIsStereoRenderEnabled" 'rl-stereo-render-enabled?
   "IsFileExtension" 'file-extension?})

(var failures 0)
(eachp [c-name sym] expected
  (def binding (get (curenv) (symbol "rl/" sym)))
  (unless (and binding (cfunction? (binding :value)))
    (++ failures)
    (eprintf "FAIL %s should be bound as %s" c-name sym)))

(if (zero? failures) (print "names: ok") (do (eprintf "names: %d failure(s)" failures) (os/exit 1)))
