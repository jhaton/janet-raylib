# Generate the quick-reference cheatsheets in docs/ (GitHub Pages ready).
#
# usage: janet gen/cheatsheet.janet
#
# Signatures, return shapes, notes, and exclusions come from the same plans that
# generate the C bindings, so the cheatsheets cannot drift from the API. Module
# and section grouping is read from the raylib headers themselves.

(import ./gen)

(def version "0.1.0")
(def raylib-version "5.5")

# ---------------------------------------------------------------------------
# Header layout: module and section for every function, in header order
# ---------------------------------------------------------------------------

(def- module-of-banner
  {"core" "core" "rgestures" "core" "rcamera" "core" "shapes" "shapes"
   "textures" "textures" "text" "text" "models" "models" "audio" "audio"})

(defn- c-name-of [line]
  (def head (first (string/split "(" line)))
  (last (filter |(not (empty? $)) (string/split " " (string/replace-all "*" " " head)))))

(defn- comment-text [line]
  (string/trim (string/slice line 2)))

(defn header-layout
  "Records {:module :section :c-name} for each declaration, in header order.
  mode :comments uses the first line of a // comment run as the section;
  mode :banners uses raymath's 'Module Functions Definition - X' banners."
  [path decl mode default-module]
  (def out @[])
  (var module default-module)
  (var section nil)
  (var previous-comment? false)
  (var last-comment nil)
  (var done false)
  (each raw (string/split "\n" (slurp path))
    (def line (string/trim raw))
    (when (string/find "RLGL IMPLEMENTATION" line) (set done true))
    (unless done
      (def comment? (and (string/has-prefix? "//" line) (not (string/has-prefix? "//-" line))))
      (cond
        (and comment? (string/find "(Module: " line))
        (let [[title banner] (peg/match ~(* "//" (any " ") (<- (to " (Module: ")) " (Module: " (<- (to ")"))) line)]
          (set module (get module-of-banner banner module))
          (set section title))
        (and (= mode :banners) comment? (string/find "Module Functions Definition - " line))
        (set section (string/slice line (+ (string/find " - " line) 3)))
        (and (= mode :comments) comment? (not previous-comment?)
             (not (string/has-prefix? (comment-text line) "NOTE")))
        (set section (comment-text line))
        (string/has-prefix? decl line)
        (array/push out {:module module :section section :c-name (c-name-of line)
                         :comment (when previous-comment? last-comment)}))
      (when comment? (set last-comment (comment-text line)))
      (set previous-comment? comment?)))
  out)

# ---------------------------------------------------------------------------
# Janet-facing shapes
# ---------------------------------------------------------------------------

(defn- tuple-shape [name]
  (def st (gen/structs (gen/canonical name)))
  (def fixed? (some |((gen/parse-ctype ($ :type)) :fixed) (st :fields)))
  (def names (mapcat (fn [f]
                       (def ct (gen/parse-ctype (f :type)))
                       (if (ct :fixed) (array/new-filled (ct :fixed) "_") [(f :name)]))
                     (st :fields)))
  (cond
    (= (gen/canonical name) "Rectangle") "[x y w h]"
    (or fixed? (> (length names) 4)) (string "[" (length names) " numbers]")
    (string "[" (string/join names " ") "]")))

(defn shape-of-ctype
  "How a C type looks on the Janet side."
  [ctype]
  (def ct (gen/parse-ctype ctype))
  (def base (ct :base))
  (cond
    (= ctype "void") nil
    (and (= base "char") (= 1 (ct :ptr))) "string"
    (pos? (ct :ptr)) "pointer"
    (= base "bool") "bool"
    (gen/scalar-kinds base) "number"
    (= base "long") "number"
    (not (gen/value-type? base)) base
    (= :tuple (gen/shape-of base)) (tuple-shape base)
    (gen/handle? base) (gen/canonical base)
    (string "{" (gen/canonical base) "}")))

(defn return-shape
  "The Janet value a planned function returns, or nil."
  [plan]
  (def rspec (plan :returns))
  (def rct (gen/parse-ctype (plan :return)))
  (def main
    (case (rspec :kind)
      :array (string "[" (or (shape-of-ctype (string (rct :base))) "?") " ...]")
      :bytes "buffer"
      :string "string"
      :handle-array (string (gen/canonical (rct :base)) " array")
      :borrowed (string (gen/canonical (rct :base)) " (borrowed)")
      :pointer "pointer"
      (shape-of-ctype (plan :return))))
  (def outs
    (seq [p :in (plan :plans)
          :when (or (and (= (p :kind) :out) (not (p :consumed)))
                    (= (p :kind) :inout) (= (p :kind) :out-bytes))]
      (if (= (p :kind) :out-bytes) "buffer" (shape-of-ctype ((p :ct) :base)))))
  (def all (filter identity [main ;outs]))
  (case (length all)
    0 nil
    1 (first all)
    (string "[" (string/join all " ") "]")))

# ---------------------------------------------------------------------------
# HTML
# ---------------------------------------------------------------------------

(defn- esc [s]
  (->> (string s)
       (string/replace-all "&" "&amp;")
       (string/replace-all "<" "&lt;")
       (string/replace-all ">" "&gt;")
       (string/replace-all "\"" "&quot;")))

(defn- entry
  "One cheatsheet row: name, args, optional return shape, comment, hover text."
  [&named name args ret note hover excluded kind]
  @{:name name :args (or args []) :ret ret :comment note :hover hover
    :excluded excluded :kind (or kind :fn)})

(defn- entry-width [e]
  (+ 2 (length (e :name)) (sum (map |(inc (length $)) (e :args)))
     (if (e :ret) (+ 3 (length (e :ret))) 0)))

(defn- render-entry [e column]
  (def close (if (= (e :kind) :macro) " ...)" ")"))
  (def head
    (string "<span class=\"p\">(</span><span class=\"fn\">" (esc (e :name)) "</span>"
            (string/join (map |(string " <span class=\"ar\">" (esc $) "</span>") (e :args)))
            "<span class=\"p\">" close "</span>"
            (if (e :ret) (string " <span class=\"rt\">→ " (esc (e :ret)) "</span>") "")))
  (def width (+ (entry-width e) (if (= (e :kind) :macro) 4 0)))
  (def pad (string/repeat " " (max 2 (- column width))))
  (string "<div class=\"l" (if (e :excluded) " x" "") "\""
          (if (e :hover) (string " title=\"" (esc (e :hover)) "\"") "") ">"
          head pad "<span class=\"c\"># " (esc (e :comment)) "</span></div>\n"))

(defn- render-rows
  "Rows are entries or [:section text]; comments align per block, capped."
  [rows]
  (def widths (seq [r :in rows :when (dictionary? r)]
                (+ (entry-width r) (if (= (r :kind) :macro) 4 0))))
  (def column (+ 2 (min 76 (max 0 ;widths))))
  (def out @"")
  (var first-section true)
  (each r rows
    (if (dictionary? r)
      (buffer/push out (render-entry r column))
      (do
        (unless first-section (buffer/push out "<div class=\"l s gap\"></div>\n"))
        (set first-section false)
        (buffer/push out "<div class=\"l s\"><span class=\"c\"># " (esc (r 1)) "</span></div>\n"))))
  out)

(defn- block [id heading rows]
  (string "<section class=\"block " id "\" id=\"" id "\">\n"
          "<h2><a href=\"#" id "\">" (esc heading) " →</a></h2>\n"
          "<pre><code>" (render-rows rows) "</code></pre>\n</section>\n"))

(defn- page [&named title current body]
  (def nav
    (string/join
      (seq [[file link-text] :in [["index.html" "raylib"] ["raymath.html" "raymath"] ["rlgl.html" "rlgl"]]]
        (if (= file current)
          (string "<b>" link-text "</b>")
          (string "<a href=\"" file "\">" link-text "</a>")))
      " · "))
  (string
    "<!DOCTYPE html>\n<!-- Generated by gen/cheatsheet.janet. Do not edit. -->\n"
    "<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
    "<meta name=\"viewport\" content=\"width=device-width\">\n"
    "<title>" (esc title) "</title>\n"
    "<link rel=\"stylesheet\" href=\"style.css\">\n"
    "<script>if (localStorage.getItem('dark') === '1' || (localStorage.getItem('dark') === null && matchMedia('(prefers-color-scheme: dark)').matches)) document.documentElement.classList.add('dark');</script>\n"
    "</head>\n<body>\n<header>\n"
    "<div class=\"logo\"><span>janet</span><span>raylib</span></div>\n"
    "<div class=\"meta\">\n"
    "<p class=\"tagline\">raylib " raylib-version " for Janet: generated bindings, guarded resources, plain data</p>\n"
    "<p class=\"links\">[<a href=\"https://github.com/jhaton/janet-raylib\">github.com/jhaton/janet-raylib</a>]"
    "[<a href=\"https://github.com/jhaton/janet-raylib/blob/main/README.md\">README</a>]"
    "[<a href=\"https://github.com/jhaton/janet-raylib/blob/main/API.md\">API.md</a>]"
    "[<a href=\"https://www.raylib.com/cheatsheet/cheatsheet.html\">raylib C cheatsheet</a>]</p>\n"
    "<p class=\"version\">v" version " quick reference card: " nav "</p>\n"
    "</div>\n"
    "<div class=\"tools\"><input id=\"filter\" type=\"search\" placeholder=\"filter…\" autocomplete=\"off\">"
    "<button id=\"dark\" type=\"button\">dark mode</button></div>\n"
    "</header>\n<main>\n" body "</main>\n"
    "<footer><p>janet-raylib quick reference card. Hover a line for its C signature and conversion notes. "
    "raylib is Copyright (c) Ramon Santamaria (@raysan5); function descriptions come from raylib's headers.</p></footer>\n"
    "<script src=\"cheatsheet.js\"></script>\n"
    "</body>\n</html>\n"))

# ---------------------------------------------------------------------------
# Content
# ---------------------------------------------------------------------------

(defn- manual-docs
  "name -> [signature description] from the registrations in src/manual.c."
  []
  (def source (slurp "src/manual.c"))
  (def grammar
    ~{:str (* "\"" (% (any (+ (* "\\n" (constant "\n")) (* "\\\"" (constant "\""))
                              (<- (if-not (set "\"\\") 1))))) "\"")
      :ws (any (set " \t\r\n"))
      :reg (* "{" (<- (* "\"" (to "\""))) "\"," :ws (to ",") "," :ws
              (group (some (* :str :ws))) ",")
      :main (any (+ (group :reg) 1))})
  (tabseq [[quoted strs] :in (peg/match grammar source)]
    (string/slice quoted 1)
    (let [text (string ;strs)
          [signature rest] [(first (string/split "\n" text))
                            (get (string/split "\n\n" text) 1 "")]]
      [signature (first (string/split ". " (string/replace-all "\n" " " rest)))])))

(def manual (manual-docs))

(defn- sig-entry [name signature note &opt ret]
  (def words (string/split " " (string/slice signature 1 -2)))
  (entry :name name :args (slice words 1) :note note :ret ret))

(defn- plan-entry [plan &opt fallback-note]
  (cond
    (plan :skip)
    (entry :name (plan :name) :note (string "excluded: " (plan :skip))
           :excluded true :hover (string "C: " (gen/c-signature plan)))
    (plan :manual)
    (let [[signature desc] (manual (plan :name))]
      (sig-entry (plan :name) signature (string desc " (hand-written)")))
    (let [[_ signature notes] (gen/emit-function plan)
          args (slice (string/split " " (string/slice signature 1 -2)) 1)]
      (entry :name (plan :name) :args args :ret (return-shape plan)
             :note (if (empty? (plan :description)) (or fallback-note "") (plan :description))
             :hover (string "C: " (gen/c-signature plan)
                            (if (empty? notes) "" (string "\n" (string/join notes "\n"))))))))

(defn- grouped-rows
  "Section rows plus entries for the given layout records."
  [records by-name]
  (def rows @[])
  (var section nil)
  (each r records
    (when-let [plan (by-name (r :c-name))]
      (unless (= (r :section) section)
        (set section (r :section))
        (when section (array/push rows [:section section])))
      (array/push rows (plan-entry plan (r :comment)))))
  rows)

(defn- check-complete [header records by-name]
  (def seen (tabseq [r :in records :when (by-name (r :c-name))] (r :c-name) true))
  (def missing (seq [name :keys by-name :unless (seen name)] name))
  (unless (empty? missing)
    (error (string header ".h functions missing from the header layout: " (string/join (sort missing) ", ")))))

(defn- plans-by-name [h] (tabseq [p :in (gen/plans h)] (p :c-name) p))

(defn- layer-macros
  "Scoped forms from lib/raylib/init.janet."
  []
  (seq [form :in (parse-all (slurp "lib/raylib/init.janet"))
        :when (and (tuple? form) (= 'defmacro (first form)))]
    (def [_ name docstring params] form)
    (def args (seq [p :in params :until (= p '&)] (string p)))
    (entry :name (string name) :args args :note docstring :kind :macro)))

(defn- extras-rows []
  (def rows @[[:section "Scoped forms (raylib layer); the closing call runs even if body errors"]])
  (array/concat rows (layer-macros))
  (array/push rows [:section "Resources"])
  (array/push rows (entry :name "with" :args ["[x (load-...) unload-...]"] :note "Janet's own with: unload any handle when the body exits" :kind :macro))
  (each name ["handle-live?" "unload-model-resources" "unload-materials"]
    (def [signature desc] (manual name))
    (array/push rows (sig-entry name signature desc)))
  (array/push rows [:section "Logging (raylib logs from its audio thread, so no Janet callback)"])
  (each name ["set-trace-log-capture" "take-trace-logs"]
    (def [signature desc] (manual name))
    (array/push rows (sig-entry name signature desc (when (= name "take-trace-logs") "@[[level message] ...]"))))
  (array/push rows [:section "Constructors: C's (T){ .field = ... }; omitted fields are zero"])
  (each [type-name janet-name] gen/constructor-names
    (def [signature text] (gen/constructor-doc type-name))
    (array/push rows (entry :name janet-name :args ["{...}"] :ret type-name
                            :note (first (string/split ". " (first (string/split "\n\n" text))))
                            :hover (string/replace-all "\n\n" "\n" text))))
  (array/push rows [:section "Handle fields"])
  (array/push rows (entry :name "texture :width" :note "read a field by keyword; (keys handle) lists them"))
  (array/push rows (entry :name "put model :transform m" :note "write a field; fields that size memory are read-only"))
  (array/push rows (entry :name "get-in model [:materials 0 :maps :albedo]" :note "views into owned memory; they die with their owner. Material maps also take MaterialMapIndex keywords"))
  rows)

(defn- value-rows []
  @[[:section "Values crossing the boundary"]
    (entry :name "draw-circle-v [x y] r :red" :note "vectors and rectangles are tuples (arrays work too)")
    (entry :name "matrix-translate 1 2 3" :ret "[16 numbers]" :note "matrices are 16 numbers in raylib field order: m0 m4 m8 m12 m1 ... (row-major)")
    (entry :name "clear-background [245 245 245]" :note "colors: [r g b], [r g b a] with 0-255 integers, or a keyword")
    (entry :name "update-camera-pro {:position [0 2 4] ...} m r z" :note "plain structs are structs/tables with kebab keys; all fields required")
    (entry :name "key-down? :space" :note "enum parameters take member keywords or integers")
    (entry :name "set-config-flags [:vsync-hint :msaa-4x-hint]" :note "flag enums also take a tuple of keywords (OR-ed)")
    (entry :name "check-collision-lines a b c d" :ret "[bool [x y]]" :note "C out-parameters are returned, after the result")
    (entry :name "set camera (update-camera camera :orbital)" :note "in/out parameters come back updated; rebind them")
    (entry :name "draw-line-strip [[0 0] [10 5]] :red" :note "array + count parameters take one tuple; the count is implied")
    (entry :name "load-file-data \"f.bin\"" :ret "buffer" :note "C memory returned by Load* is copied into Janet and freed")])

(defn- structs-rows []
  (def rows @[[:section "tuples: [...] of numbers"]])
  (each name gen/struct-order
    (when (= :tuple (gen/shape-of name))
      (array/push rows (entry :name name :ret (tuple-shape name) :note
                              (get-in gen/structs [name :description] "")))))
  (array/push rows [:section "plain structs: {:key value}, every field required"])
  (each name gen/struct-order
    (when (= :struct (gen/shape-of name))
      (def [records] (gen/build-fields name))
      (array/push rows (entry :name name :args (map |(string ":" ($ :key)) records)
                              :note (get-in gen/structs [name :description] "")))))
  (array/push rows [:section "handles: guarded resources; fields by keyword, * = read-only"])
  (each name gen/struct-order
    (when (= :handle (gen/shape-of name))
      (def [records] (gen/build-fields name))
      (def fields (seq [r :in records :unless (= (r :shape) "JRL_FIELD_HIDDEN")]
                    (string ":" (r :key) (if (r :readonly) "*" ""))))
      (array/push rows (entry :name name :args fields :note (get-in gen/structs [name :description] "")))))
  rows)

(defn- colors-html []
  (def out @"<section class=\"block colors\" id=\"colors\">\n<h2><a href=\"#colors\">colors →</a></h2>\n<pre><code>")
  (each [key [r g b a]] gen/colors
    (buffer/push out "<div class=\"l\"><span class=\"sw\" style=\"background:rgba(" (string r) "," (string g) "," (string b) "," (string (/ a 255)) ")\"></span>"
                 "<span class=\"kw\">" (esc (string/format "%-13s" (string key))) "</span>"
                 "<span class=\"c\"># [" (string/join (map string [r g b a]) " ") "]</span></div>\n"))
  (buffer/push out "</code></pre>\n</section>\n")
  out)

(defn- enums-html [names]
  (def out @"")
  (each name names
    (def e (gen/enums name))
    (def keys (sort (map |(string ":" (gen/enum-key e ($ :name))) (e :values))))
    (buffer/push out "<div class=\"l enum\"><span class=\"fn\">" (esc name) "</span>"
                 (if (e :flags) " <span class=\"c\"># flags: tuple of keywords allowed</span>" "")
                 "<div class=\"kws\">" (string/join (map |(string "<span class=\"kw\">" (esc $) "</span>") keys) " ")
                 "</div></div>\n"))
  out)

(defn- enum-block [id heading names]
  (string "<section class=\"block " id "\" id=\"" id "\">\n<h2><a href=\"#" id "\">" heading " →</a></h2>\n"
          "<pre><code><div class=\"l s\"><span class=\"c\"># keywords for enum parameters; each member is also a constant, e.g. key-a, blend-additive</span></div>\n"
          (enums-html names) "</code></pre>\n</section>\n"))

(defn raylib-page []
  (def by-name (plans-by-name "raylib"))
  (def records (header-layout "vendor/raylib/src/raylib.h" "RLAPI " :comments "core"))
  (check-complete "raylib" records by-name)
  (def body @"")
  (each [id heading] [["core" "module: rcore"] ["shapes" "module: rshapes"] ["textures" "module: rtextures"]
                      ["text" "module: rtext"] ["models" "module: rmodels"] ["audio" "module: raudio"]]
    (buffer/push body (block id heading (grouped-rows (filter |(= ($ :module) id) records) by-name))))
  (buffer/push body (block "janet" "janet-raylib extras" (extras-rows)))
  (buffer/push body (block "values" "values" (value-rows)))
  (buffer/push body "<div class=\"pair\">\n" (block "structs" "structs" (structs-rows)) (colors-html) "</div>\n")
  (buffer/push body (enum-block "enums" "enums" (filter |(= "raylib" ((gen/enums $) :header)) gen/enum-order)))
  (page :title "janet-raylib cheatsheet" :current "index.html" :body body))

(defn raymath-page []
  (def by-name (plans-by-name "raymath"))
  (def records (header-layout "vendor/raylib/src/raymath.h" "RMAPI " :banners "raymath"))
  (check-complete "raymath" records by-name)
  (page :title "janet-raylib raymath cheatsheet" :current "raymath.html"
        :body (string (block "raymath" "raymath: vectors are tuples, matrices are 16 numbers" (grouped-rows records by-name))
                      (block "values" "values" (value-rows)))))

(defn rlgl-page []
  (def by-name (plans-by-name "rlgl"))
  (def records (header-layout "vendor/raylib/src/rlgl.h" "RLAPI " :comments "rlgl"))
  (check-complete "rlgl" records by-name)
  (page :title "janet-raylib rlgl cheatsheet" :current "rlgl.html"
        :body (string (block "rlgl" "rlgl: low-level OpenGL abstraction" (grouped-rows records by-name))
                      (enum-block "enums" "rlgl enums" (filter |(= "rlgl" ((gen/enums $) :header)) gen/enum-order)))))

(defn main [&]
  (os/mkdir "docs")
  (spit "docs/index.html" (raylib-page))
  (spit "docs/raymath.html" (raymath-page))
  (spit "docs/rlgl.html" (rlgl-page))
  (print "wrote docs/index.html docs/raymath.html docs/rlgl.html"))
