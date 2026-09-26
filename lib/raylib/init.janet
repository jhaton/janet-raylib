# raylib: the generated 1:1 bindings plus scoped forms for raylib's paired
# Begin*/End* and Init*/Close* calls.
#
# Everything from raylib/native is re-exported unchanged. Resources are scoped
# with Janet's own `with`:
#
#   (with [texture (load-texture "atlas.png") unload-texture]
#     ...)

(import raylib/native :prefix "" :export true)

(defn- scoped
  "Code for (begin ...args) body (end), with end run even when body errors.
  begin and end are embedded as function values, so local shadowing is harmless."
  [begin args end body]
  ~(do (,begin ,;args) (defer (,end) ,;body)))

(defmacro with-window
  "Open a window, run body, and close the window afterwards."
  [width height title & body]
  (scoped init-window [width height title] close-window body))

(defmacro with-audio-device
  "Initialize the audio device around body."
  [& body]
  (scoped init-audio-device [] close-audio-device body))

(defmacro with-drawing
  "Run body between begin-drawing and end-drawing."
  [& body]
  (scoped begin-drawing [] end-drawing body))

(defmacro with-mode-2d
  "Run body inside begin-mode-2d with camera."
  [camera & body]
  (scoped begin-mode-2d [camera] end-mode-2d body))

(defmacro with-mode-3d
  "Run body inside begin-mode-3d with camera."
  [camera & body]
  (scoped begin-mode-3d [camera] end-mode-3d body))

(defmacro with-texture-mode
  "Draw body into the render texture target."
  [target & body]
  (scoped begin-texture-mode [target] end-texture-mode body))

(defmacro with-shader-mode
  "Draw body with shader active."
  [shader & body]
  (scoped begin-shader-mode [shader] end-shader-mode body))

(defmacro with-blend-mode
  "Draw body with a BlendMode (keyword or integer)."
  [mode & body]
  (scoped begin-blend-mode [mode] end-blend-mode body))

(defmacro with-scissor-mode
  "Clip drawing in body to the rectangle x, y, width, height."
  [x y width height & body]
  (scoped begin-scissor-mode [x y width height] end-scissor-mode body))

(defmacro with-vr-stereo-mode
  "Draw body in VR stereo mode with config."
  [config & body]
  (scoped begin-vr-stereo-mode [config] end-vr-stereo-mode body))

(defmacro with-matrix
  "Run body between rl-push-matrix and rl-pop-matrix."
  [& body]
  (scoped rl-push-matrix [] rl-pop-matrix body))
