# Window smoke test: opens a window, exercises 2D, 3D, render targets, shaders,
# model field views, and resource guards, then saves a screenshot.
#
# usage: janet examples/smoke.janet OUTPUT.png

(import raylib :as rl)

(def fragment-shader
  ``
  #version 330
  in vec2 fragTexCoord;
  in vec4 fragColor;
  uniform sampler2D texture0;
  uniform vec4 colDiffuse;
  uniform float tint;
  out vec4 finalColor;
  void main() {
    vec4 c = texture(texture0, fragTexCoord) * colDiffuse * fragColor;
    finalColor = vec4(c.rgb * vec3(1.0, tint, tint), c.a);
  }
  ``)

(defn- expect [ok what]
  (unless ok (error (string "smoke check failed: " what))))

(defn- errors? [f]
  (try (do (f) false) ([_] true)))

(defn main [_ output]
  (rl/set-trace-log-level :warning)
  (rl/set-config-flags [:window-hidden :msaa-4x-hint])
  (rl/with-window 320 240 "janet-raylib smoke"
    (rl/set-target-fps 60)
    (def checker (rl/gen-image-checked 64 64 8 8 :orange :dark-blue))
    (def texture (rl/load-texture-from-image checker))
    (rl/unload-image checker)
    (def target (rl/load-render-texture 64 64))
    (def shader (rl/load-shader-from-memory nil fragment-shader))
    (def tint-loc (rl/get-shader-location shader "tint"))
    (def model (rl/load-model-from-mesh (rl/gen-mesh-cube 1 1 1)))
    # Model internals are reachable: set the diffuse map through a material view,
    # and move the model through its transform field.
    (def material (get-in model [:materials 0]))
    (rl/set-material-texture material :albedo texture)
    (put model :transform (rl/matrix-rotate-y 0.6))
    (expect (= 24 ((get-in model [:meshes 0]) :vertex-count)) "cube mesh has 24 vertices")
    (expect (= (texture :id) (get-in material [:maps 0 :texture :id])) "material view points at texture")
    (def camera {:position [2.5 2 2.5] :target [0 0 0] :up [0 1 0] :fovy 45 :projection :perspective})
    (for frame 0 5
      (rl/with-texture-mode target
        (rl/clear-background :blank)
        (rl/draw-circle 32 32 24 :red))
      (rl/with-drawing
        (rl/clear-background :ray-white)
        (rl/with-mode-3d camera
          (rl/draw-model model [0 0 0] 1 :white)
          (rl/draw-grid 10 1))
        (rl/set-shader-value shader tint-loc 0.2 :float)
        (rl/with-shader-mode shader
          (rl/draw-texture texture 8 8 :white))
        (rl/draw-texture-rec (target :texture) [0 0 64 -64] [248 8] :white)
        (rl/draw-line-strip [[10 200] [60 180] [110 220] [160 190]] :dark-green)
        (rl/draw-text (string "frame " frame) 10 220 10 :black)))
    (def screen (rl/load-image-from-screen))
    (def scale (/ (screen :width) 320))
    (def colors (rl/load-image-colors screen))
    (defn pixel [x y] (colors (+ (* (math/floor (* y scale)) (screen :width)) (math/floor (* x scale)))))
    (expect (= [245 245 245] (take 3 (pixel 1 1))) "background is ray-white")
    (expect (let [[r g b] (pixel 12 12)] (> r (* 2 g))) "shader tint reduced green and blue")
    (expect (let [[r g b] (pixel 280 40)] (and (> r 200) (< g 80))) "render texture circle is drawn red")
    (rl/export-image screen output)
    (rl/unload-image screen)
    # Guards: views die with their owner, and nothing unloads twice.
    (def mesh-view (get-in model [:meshes 0]))
    (rl/unload-model model)
    (expect (errors? |(mesh-view :vertex-count)) "mesh view errors after unload-model")
    (expect (errors? |(rl/unload-model model)) "second unload-model errors")
    (expect (errors? |(rl/unload-texture (target :texture))) "render texture's texture cannot be unloaded alone")
    # unload-model-resources frees material textures that unload-model leaves behind.
    (def model-image (rl/gen-image-color 4 4 :green))
    (def model-texture (rl/load-texture-from-image model-image))
    (def kept-texture (rl/load-texture-from-image model-image))
    (rl/unload-image model-image)
    (def shared (rl/load-model-from-mesh (rl/gen-mesh-cube 1 1 1)))
    (rl/set-material-texture (get-in shared [:materials 0]) :albedo model-texture)
    (rl/set-material-texture (get-in shared [:materials 0]) :metalness model-texture)
    (expect (= 1 (rl/unload-model-resources shared)) "a texture used by two maps is unloaded once")
    (expect (errors? |(rl/unload-model-resources shared)) "unload-model-resources refuses an unloaded model")
    (def keeper (rl/load-model-from-mesh (rl/gen-mesh-cube 1 1 1)))
    (rl/set-material-texture (get-in keeper [:materials 0]) :albedo kept-texture)
    (expect (= 0 (rl/unload-model-resources keeper [kept-texture])) "textures in keep are left alone")
    (rl/unload-texture kept-texture)
    (rl/unload-shader shader)
    (rl/unload-render-texture target)
    (rl/unload-texture texture)
    (printf "SMOKE_OK screenshot=%s frames=5" output)))
