# Generate the raylib binding from api/*.jdn and overrides.jdn.
#
# usage: janet gen/gen.janet
#
# Writes src/gen/{types.h,types.c,raylib.c,raymath.c,rlgl.c} and API.md.
# Every pointer parameter must be resolved by a rule below or by an entry in
# overrides.jdn; anything else stops generation with a list of what is missing.

(def header-names ["raylib" "raymath" "rlgl"])
(def overrides (parse (slurp "overrides.jdn")))
(def apis (tabseq [h :in header-names] h (parse (slurp (string "api/" h ".jdn")))))

(def problems @[])

(defn- bpush
  "buffer/push that writes numbers as decimal text instead of raw bytes."
  [buf & parts]
  (each p parts (buffer/push buf (if (number? p) (string p) p)))
  buf)
(defn- problem [& parts] (array/push problems (string ;parts)))

# ---------------------------------------------------------------------------
# Naming
# ---------------------------------------------------------------------------

(defn- char-class [c]
  (cond
    (<= 65 c 90) :upper
    (<= 97 c 122) :lower
    (<= 48 c 57) :digit
    :other))

(defn- runs
  "Split a C identifier into runs of upper, lower, and digit characters."
  [name]
  (def out @[])
  (each c name
    (def cls (char-class c))
    (if (= cls (get (last out) 0))
      (buffer/push-byte (get (last out) 1) c)
      (array/push out @[cls (buffer/from-bytes c)])))
  (map (fn [[cls text]] [cls (string text)]) out))

(defn camel-words
  "Lower-case words of a camelCase or PascalCase C identifier.
  Digits join the preceding word (Vector2, UTF8, Vertex2f) except in 2D/3D."
  [name]
  (def rs (runs name))
  (def words @[])
  (defn append-to-last [text]
    (if (empty? words)
      (array/push words text)
      (put words (dec (length words)) (string (last words) text))))
  (var i 0)
  (while (< i (length rs))
    (def [cls text] (rs i))
    (def [ncls ntext] (get rs (inc i) [nil nil]))
    (def [nncls _] (get rs (+ i 2) [nil nil]))
    (case cls
      :upper
      (if (= ncls :lower)
        (do
          (when (> (length text) 1)
            (array/push words (string/ascii-lower (string/slice text 0 -2))))
          (array/push words (string/ascii-lower (string (string/slice text -2) ntext)))
          (++ i))
        (array/push words (string/ascii-lower text)))
      :lower (array/push words text)
      :digit
      (cond
        (and (= ncls :upper) (= ntext "D") (not= nncls :lower))
        (do (array/push words (string text "d")) (++ i))
        (and (= ncls :lower) (<= (length ntext) 2) (not= nncls :upper))
        (do (append-to-last (string text ntext)) (++ i))
        (append-to-last text))
      (append-to-last text))
    (++ i))
  words)

(defn kebab [name] (string/join (camel-words name) "-"))

(defn function-name
  "raylib function name -> Janet name: kebab-case, IsX -> x? for bool returns."
  [c-name return-type]
  (def rl? (and (string/has-prefix? "rl" c-name)
                (> (length c-name) 2)
                (= :upper (char-class (c-name 2)))))
  (def stem (if rl? (string/slice c-name 2) c-name))
  (def predicate? (and (= return-type "bool")
                       (string/has-prefix? "Is" stem)
                       (> (length stem) 2)
                       (= :upper (char-class (stem 2)))))
  (def core (kebab (if predicate? (string/slice stem 2) stem)))
  (string (if rl? "rl-" "") core (if predicate? "?" "")))

(defn constant-name [c-name]
  (string/replace-all "_" "-" (string/ascii-lower c-name)))

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

(def structs @{})
(def struct-order @[])
(def aliases @{})
(def opaque (tabseq [n :in (overrides :opaque-types)] n true))

(each h header-names
  (each s ((apis h) :structs)
    (def name (s :name))
    (unless (opaque name)
      (if-let [prev (structs name)]
        (unless (deep= (map |[($ :type) ($ :name)] (prev :fields)) (map |[($ :type) ($ :name)] (s :fields)))
          (problem "struct " name " differs between headers"))
        (do (put structs name s) (array/push struct-order name)))))
  (each a ((apis h) :aliases) (put aliases (a :name) (a :type))))

(defn canonical [name] (get aliases name name))

(def scalar-kinds
  {"int" "JRL_K_INT" "unsigned int" "JRL_K_UINT" "unsigned char" "JRL_K_UCHAR"
   "unsigned short" "JRL_K_USHORT" "float" "JRL_K_FLOAT" "double" "JRL_K_DOUBLE"
   "bool" "JRL_K_BOOL"})

(defn parse-ctype
  "Split a C type into constness, base name, pointer depth, and fixed length."
  [t]
  (def const? (string/has-prefix? "const " t))
  (def t1 (if const? (string/slice t 6) t))
  (def fixed (peg/match ~(* (<- (to "[")) "[" (<- :d+) "]" -1) t1))
  (def base-text (if fixed (fixed 0) t1))
  (def ptr (count |(= $ (chr "*")) base-text))
  {:const const?
   :base (string/trim (string/replace-all "*" "" base-text))
   :ptr ptr
   :fixed (when fixed (scan-number (fixed 1)))})

(def tuple-types (tabseq [n :in (overrides :tuple-types)] n true))
(def forced-handles (tabseq [n :in (overrides :handle-types)] n true))
(def shapes @{})

(defn shape-of [name]
  (def n (canonical name))
  (when-let [s (shapes n)] (break s))
  (def st (structs n))
  (unless st (break nil))
  (put shapes n :pending)
  (def result
    (cond
      (tuple-types n) :tuple
      (forced-handles n) :handle
      (some (fn [f]
              (def ct (parse-ctype (f :type)))
              (or (pos? (ct :ptr))
                  (and (structs (canonical (ct :base)))
                       (= :handle (shape-of (ct :base))))))
            (st :fields))
      :handle
      :struct))
  (put shapes n result)
  result)

(defn type-sym [name] (string "jrl_type_" (canonical name)))
(defn handle? [name] (= :handle (shape-of name)))
(defn value-type? [name] (not (nil? (structs (canonical name)))))

(defn elem-kind
  "JrlKind and JrlType pointer (as C text) for an element base type."
  [base]
  (cond
    (scalar-kinds base) [(scalar-kinds base) "NULL"]
    (value-type? base) ["JRL_K_TYPE" (string "&" (type-sym base))]
    (= base "char") ["JRL_K_CSTRING" "NULL"]
    (do (problem "no element kind for C type " base) ["JRL_K_INT" "NULL"])))

# ---------------------------------------------------------------------------
# Enums, colors, constants
# ---------------------------------------------------------------------------

(def enums @{})
(def enum-order @[])
(def flag-enums (tabseq [n :in (overrides :flag-enums)] n true))

(defn- common-prefix [names]
  (var prefix (first names))
  (each n names
    (while (not (string/has-prefix? prefix n))
      (set prefix (string/slice prefix 0 -2))))
  # cut back to the last underscore so whole words remain
  (def cut (last (string/find-all "_" prefix)))
  (if cut (string/slice prefix 0 (inc cut)) ""))

(each h header-names
  (each e ((apis h) :enums)
    (def names (map |($ :name) (e :values)))
    (def prefix (if (> (length names) 1) (common-prefix names) ""))
    (put enums (e :name)
         {:name (e :name) :header h :prefix prefix :flags (flag-enums (e :name))
          :values (e :values)})
    (array/push enum-order (e :name))))

(defn enum-key [enum member]
  (constant-name (string/slice member (length (enum :prefix)))))

(defn enum-sym [name]
  (unless (enums name) (problem "unknown enum " name))
  (string "jrl_enum_" name))

(def colors @[])
(each d ((apis "raylib") :defines)
  (when (= (d :type) "COLOR")
    (def rgba (map scan-number (peg/match ~(any (+ (<- :d+) 1)) (d :value))))
    (def key ((overrides :colors) (d :name)))
    (unless key (problem "color " (d :name) " has no keyword in overrides :colors"))
    (array/push colors [key rgba])))

# ---------------------------------------------------------------------------
# Struct field tables
# ---------------------------------------------------------------------------

(defn- field-override [struct-name field-name]
  (get-in overrides [:fields struct-name field-name] {}))

(defn- count-expr
  "C expression for a :count spec, plus the struct fields it reads."
  [st spec]
  (def field-names (tabseq [f :in (st :fields)] (f :name) true))
  (cond
    (string? spec)
    (if (field-names spec) [(string "s->" spec) [spec]] [spec []])
    (indexed? spec)
    (let [[f factor] spec] [(string "s->" f " * " factor) [f]])
    (do (problem "bad count spec " (string/format "%j" spec)) ["0" []])))

(defn build-fields
  "Field records for a struct, and C text for its count functions."
  [name]
  (def st (structs name))
  (def count-fns @[])
  (def readonly @{})
  (def records @[])
  (each f (st :fields)
    (def ct (parse-ctype (f :type)))
    (def fname (f :name))
    (def o (field-override name fname))
    (def enum-name (get-in overrides [:enum-fields name fname]))
    (def rec @{:key (kebab fname) :c fname :enum enum-name :readonly (o :readonly)})
    (defn count-fn [suffix expr]
      (def fn-name (string "jrl_count_" name "_" fname suffix))
      (array/push count-fns
                  (string "static int32_t " fn-name "(const void *self) {\n"
                          "    const " name " *s = self;\n"
                          "    (void) s;\n"
                          "    return (int32_t) (" expr ");\n}\n"))
      fn-name)
    (cond
      (o :hidden) (put rec :shape "JRL_FIELD_HIDDEN")
      (ct :fixed)
      (if (= (ct :base) "char")
        (merge-into rec {:shape "JRL_FIELD_CHARS" :fixed (ct :fixed) :kind ["JRL_K_UCHAR" "NULL"]})
        (merge-into rec {:shape "JRL_FIELD_FIXED" :fixed (ct :fixed) :kind (elem-kind (ct :base))}))
      (zero? (ct :ptr))
      (merge-into rec {:shape "JRL_FIELD_SCALAR" :kind (elem-kind (ct :base))})
      (o :bytes)
      (do
        (each r (o :reads) (put readonly r true))
        (merge-into rec {:shape "JRL_FIELD_BYTES" :kind ["JRL_K_UCHAR" "NULL"]
                         :count (count-fn "" (o :bytes))}))
      (and (= (ct :ptr) 2) (o :inner))
      (let [[outer oreads] (count-expr st (o :count))
            [inner ireads] (count-expr st (o :inner))]
        (each r [;oreads ;ireads] (put readonly r true))
        (merge-into rec {:shape "JRL_FIELD_POINTER2" :kind (elem-kind (ct :base))
                         :count (count-fn "" outer) :inner (count-fn "_inner" inner)}))
      (o :count)
      (let [[expr reads] (count-expr st (o :count))
            base (if (and (= (ct :base) "char") (= (ct :ptr) 2)) "char" (ct :base))]
        (each r reads (put readonly r true))
        (merge-into rec {:shape "JRL_FIELD_POINTER" :kind (elem-kind base)
                         :count (count-fn "" expr)}))
      (do
        (problem "struct field " name "." fname " (" (f :type) ") needs :count, :bytes, or :hidden")
        (put rec :shape "JRL_FIELD_HIDDEN")))
    (array/push records rec))
  (each rec records
    (when (readonly (rec :c)) (put rec :readonly true)))
  [records count-fns])

# ---------------------------------------------------------------------------
# Function plans
# ---------------------------------------------------------------------------

(defn- int-type? [ct] (and (zero? (ct :ptr)) (or (= (ct :base) "int") (= (ct :base) "unsigned int"))))
(defn- suffix? [name & suffixes] (some |(string/has-suffix? $ name) suffixes))

(defn- enum-for [fn-name param-name]
  (or (get-in overrides [:enum-params-by-fn fn-name param-name])
      (get-in overrides [:enum-params param-name])))

(defn- unload-fn? [c-name params]
  (and (peg/match ~(* (? "rl") "Unload") c-name)
       (= 1 (length params))
       (let [ct (parse-ctype ((first params) :type))]
         (and (zero? (ct :ptr)) (value-type? (ct :base)) (handle? (ct :base))))))

(defn classify-param
  "Decide how one C parameter crosses the boundary."
  [fn-name params i spec unload?]
  (def p (params i))
  (def ct (parse-ctype (p :type)))
  (def o (get-in spec [:params (p :name)] {}))
  (def nxt (get params (inc i)))
  (def nct (when nxt (parse-ctype (nxt :type))))
  (def base (ct :base))
  (def kind (o :kind))
  (def rec (merge o {:c-name (p :name) :c-type (p :type) :ct ct}))
  (cond
    (= (p :type) "...") (put rec :kind :varargs)
    kind rec
    (o :consumed) (put rec :kind :handle)
    (and unload? (zero? (ct :ptr))) (put rec :kind :unload)
    (zero? (ct :ptr))
    (cond
      (and (int-type? ct) (enum-for fn-name (p :name)))
      (merge-into rec {:kind :enum :enum (enum-for fn-name (p :name))})
      (scalar-kinds base) (put rec :kind :scalar)
      (= base "char") (put rec :kind :char)
      (and (value-type? base) (handle? base)) (put rec :kind :handle)
      (value-type? base) (put rec :kind :value)
      (do (problem fn-name ": parameter " (p :name) " has unsupported type " (p :type))
        (put rec :kind :unresolved)))
    (and (= base "char") (= 1 (ct :ptr)) (ct :const)) (put rec :kind :string)
    # const T *items followed by int *Count -> array
    (and (ct :const) (= 1 (ct :ptr)) nxt (int-type? nct)
         (suffix? (nxt :name) "count" "Count")
         (or (scalar-kinds base) (value-type? base)))
    (merge-into rec {:kind :array :count (nxt :name) :rule "const T* + count"})
    (and (ct :const) (= 2 (ct :ptr)) (= base "char") nxt (int-type? nct)
         (suffix? (nxt :name) "count" "Count"))
    (merge-into rec {:kind :array :count (nxt :name) :rule "const char** + count"})
    # const void/unsigned char *data followed by int *Size -> bytes
    (and (ct :const) (= 1 (ct :ptr)) (or (= base "void") (= base "unsigned char")) nxt
         (int-type? nct) (suffix? (nxt :name) "size" "Size"))
    (merge-into rec {:kind :bytes :size (nxt :name) :rule "const void* + size"})
    (and (= 1 (ct :ptr)) (value-type? base) (handle? base))
    (merge-into rec {:kind :handle-ptr :rule "T* resource, edited in place"})
    (and (not (ct :const)) (= 1 (ct :ptr)) (or (scalar-kinds base) (value-type? base)))
    (merge-into rec {:kind :out :rule "non-const T* output"})
    (do (problem fn-name ": pointer parameter " (p :name) " (" (p :type) ") needs an override")
      (put rec :kind :unresolved))))

(def janet-arg-kinds
  {:scalar true :enum true :char true :string true :value true :handle true
   :handle-ptr true :unload true :unload-array true :array true :bytes true
   :buffer true :uniform true :raw-pointer true :inout true})

(defn plan-function [header f]
  (def c-name (f :name))
  (def spec (get-in overrides [:functions c-name] {}))
  (def params (or (f :params) []))
  (def ret (f :returnType))
  (def base {:c-name c-name :header header :return ret :params params
             :description (f :description)
             :name (function-name c-name ret)})
  (cond
    (spec :skip) (merge base {:skip (spec :skip)})
    (spec :manual) (merge base {:manual (spec :manual)})
    (do
      (def unload? (unload-fn? c-name params))
      (def plans (seq [i :range [0 (length params)]] (classify-param c-name params i spec unload?)))
      (def by-name (tabseq [p :in plans] (p :c-name) p))
      # parameters filled from another argument's length
      (each p plans
        (when-let [src (and (get {:array true :bytes true :unload-array true} (p :kind)) (p :size))]
          (put p :count src))
        (when-let [target (and (get {:array true :bytes true :unload-array true} (p :kind)) (p :count))]
          (when-let [tp (by-name target)]
            (put tp :kind :computed)
            (put tp :source (p :c-name)))))
      (def rspec (get spec :returns {}))
      # out parameters that only size the return value are not returned
      (each key [:count :size]
        (when-let [target (rspec key)]
          (when-let [tp (by-name target)]
            (when (= (tp :kind) :out) (put tp :consumed true)))))
      (when (and (some |(= ($ :kind) :varargs) plans) (not= (spec :varargs) :string))
        (problem c-name ": varargs need an override"))
      (var index 0)
      (each p plans
        (when (janet-arg-kinds (p :kind))
          (put p :index index)
          (++ index)))
      (merge base {:plans plans :arity index :returns rspec :varargs (spec :varargs)}))))

# ---------------------------------------------------------------------------
# C emission for one function
# ---------------------------------------------------------------------------

(defn- ctype-decl
  "C declaration type for a local holding a parameter (constness dropped for values)."
  [ct]
  (string (if (ct :const) "const " "") (ct :base) (string/repeat "*" (ct :ptr))))

(defn- value-decl [ct] (canonical (ct :base)))

(def uniform-families {:raylib "JRL_UNIFORM_RAYLIB" :rlgl "JRL_UNIFORM_RLGL" :attrib "JRL_UNIFORM_ATTRIB"})

(defn emit-function
  "C source for one wrapper. Returns [c-text janet-signature notes]."
  [plan]
  (def out @"")
  (def post @[])
  (def results @[])
  (def notes @[])
  (def c-name (plan :c-name))
  (def plans (plan :plans))
  (defn line [& parts] (bpush out "    " ;parts "\n"))
  (bpush out "static Janet jrl_cfun_" c-name "(int32_t argc, Janet *argv) {\n")
  (line "janet_fixarity(argc, " (plan :arity) ");")
  (when (zero? (plan :arity)) (line "(void) argv;"))
  # phase 1: arguments that depend on nothing else
  (each p plans
    (def ct (p :ct))
    (def n (p :c-name))
    (def i (p :index))
    (case (p :kind)
      :scalar
      (line (ct :base) " " n " = "
            (case (ct :base)
              "int" "jrl_get_int" "unsigned int" "jrl_get_uint" "unsigned char" "jrl_get_uchar"
              "unsigned short" "(unsigned short) jrl_get_uint" "float" "jrl_get_float"
              "double" "jrl_get_double" "bool" "jrl_get_bool")
            "(argv, " i ");")
      :char (line "char " n " = jrl_get_char(argv, " i ");")
      :enum (line (ct :base) " " n " = (" (ct :base) ") jrl_get_enum(argv, " i ", &" (enum-sym (p :enum)) ");")
      :string (line "const char *" n " = " (if (p :nullable) "jrl_opt_cstring" "jrl_get_cstring") "(argv, " i ");")
      :value (do (line (value-decl ct) " " n ";")
               (line "jrl_get_value(argv, " i ", &" (type-sym (ct :base)) ", &" n ");"))
      :handle (line (ct :base) " " n " = *(" (ct :base) " *) jrl_get_handle(argv, " i ", &" (type-sym (ct :base)) ");")
      :handle-ptr (line (ct :base) " *" n " = (" (ct :base) " *) jrl_get_handle(argv, " i ", &" (type-sym (ct :base)) ");")
      :unload (do (line (ct :base) " " n " = *(" (ct :base) " *) jrl_unload_handle(argv, " i ", &" (type-sym (ct :base)) ");")
                (array/push post (string "jrl_mark_unloaded(argv[" i "]);")))
      :raw-pointer (line "void *" n " = jrl_get_raw_pointer(argv, " i ");")
      :computed (line (ct :base) " " n " = 0;")
      :out (do
             (def local-type (if (scalar-kinds (ct :base)) (ct :base) (value-decl ct)))
             (line local-type " " n (if (scalar-kinds (ct :base)) " = 0;" " = {0};"))
             (unless (p :consumed)
               (array/push results
                           (if (scalar-kinds (ct :base))
                             (string (case (ct :base) "unsigned int" "janet_wrap_number((double) "
                                       "float" "janet_wrap_number(" "double" "janet_wrap_number("
                                       "bool" "janet_wrap_boolean(" "janet_wrap_integer(")
                                     n ")")
                             (string "jrl_to_janet(&" (type-sym (ct :base)) ", &" n ", janet_wrap_nil())")))))
      :inout (do
               (line (value-decl ct) " " n ";")
               (line "jrl_get_value(argv, " i ", &" (type-sym (ct :base)) ", &" n ");")
               (array/push results (string "jrl_to_janet(&" (type-sym (ct :base)) ", &" n ", janet_wrap_nil())")))))
  # phase 2: arguments whose conversion reads other arguments
  (each p plans
    (def ct (p :ct))
    (def n (p :c-name))
    (def i (p :index))
    (case (p :kind)
      :array
      (let [[kind tptr] (elem-kind (ct :base))
            count-var (string "jrl_n_" n)
            elem-enum (if (p :enum) (string "&" (enum-sym (p :enum))) "NULL")]
        (line "int32_t " count-var " = 0;")
        (line (ctype-decl ct) " " n " = (" (ctype-decl ct) ") jrl_get_carray(argv, " i ", " kind ", " tptr ", "
              elem-enum ", " (if (p :nullable) 1 0) ", " (or (p :length) 0) ", &" count-var ");")
        (when-let [target (p :count)]
          (line target " = " count-var ";"))
        (array/push post (string "if (" n ") janet_sfree((void *) " n ");")))
      :bytes
      (let [view (string "jrl_v_" n)]
        (line "JanetByteView " view " = jrl_get_bytes(argv, " i ", " (if (p :nullable) 1 0) ");")
        (line (ctype-decl ct) " " n " = (" (ctype-decl ct) ") " view ".bytes;")
        (when-let [target (p :count)] (line target " = " view ".len;"))
        (when-let [m (p :min)]
          (line "if (" view ".bytes != NULL && " view ".len < (int32_t) (" m "))")
          (line "    janet_panicf(\"argument %d: expected at least %d bytes, got %d\", " i ", (int32_t) (" m "), " view ".len);")))
      :buffer
      (let [b (string "jrl_b_" n)]
        (line "JanetBuffer *" b " = janet_getbuffer(argv, " i ");")
        (line (ctype-decl ct) " " n " = " b "->data;")
        (when-let [m (p :min)]
          (line "if (" b "->count < (int32_t) (" m "))")
          (line "    janet_panicf(\"argument %d: expected at least %d bytes, got %d\", " i ", (int32_t) (" m "), " b "->count);")))
      :out-bytes
      (let [b (string "jrl_ob_" n)]
        (line "int32_t jrl_size_" n " = (int32_t) (" (p :size) ");")
        (line "JanetBuffer *" b " = janet_buffer(jrl_size_" n ");")
        (line (ctype-decl ct) " " n " = " b "->data;")
        (array/push post (string b "->count = jrl_size_" n ";"))
        (array/push results (string "janet_wrap_buffer(" b ")")))
      :uniform
      (do
        (line "const void *" n " = jrl_get_uniform(argv, " i ", " (uniform-families (p :family)) ", (int) ("
              (p :type) "), (int) (" (p :count) "));")
        (array/push post (string "janet_sfree((void *) " n ");")))
      :unload-array
      (let [count-var (string "jrl_n_" n)]
        (line "int32_t " count-var " = 0;")
        (line (ct :base) " *" n " = (" (ct :base) " *) jrl_unload_array(argv, " i ", &" (type-sym (ct :base)) ", &" count-var ");")
        (when-let [target (p :count)] (line target " = " count-var ";"))
        (array/push post (string "jrl_mark_unloaded(argv[" i "]);")))))
  # the call
  (def call-args
    (seq [p :in plans :when (not= (p :kind) :varargs)]
      (case (p :kind)
        :out (string "&" (p :c-name))
        :inout (string "&" (p :c-name))
        :string (if (= (p :c-type) "const char *") (p :c-name) (string "(" (p :c-type) ") " (p :c-name)))
        (p :c-name))))
  (when (= (plan :varargs) :string)
    (def last-arg (array/pop call-args))
    (array/push call-args "\"%s\"" last-arg))
  (def call (string c-name "(" (string/join call-args ", ") ")"))
  (def ret (plan :return))
  (def rct (parse-ctype ret))
  (def rspec (plan :returns))
  (def rkind (rspec :kind))
  (def ret-expr
    (cond
      (= ret "void") (do (line call ";") nil)
      rkind
      (do
        (line (ctype-decl rct) " jrl_ret = " call ";")
        (case rkind
          :pointer "(jrl_ret ? janet_wrap_pointer((void *) jrl_ret) : janet_wrap_nil())"
          :borrowed (string "jrl_handle_new(&" (type-sym (rct :base)) ", &jrl_ret, 1)")
          :array
          (let [[kind tptr] (elem-kind (rct :base))]
            (line "Janet jrl_result = jrl_wrap_carray(" kind ", " tptr ", jrl_ret, (int32_t) (" (rspec :count) "));")
            (when (rspec :free) (line "if (jrl_ret) " (rspec :free) "(jrl_ret);"))
            "jrl_result")
          :bytes
          (do
            (line "Janet jrl_result = jrl_wrap_bytes(jrl_ret, (int32_t) (" (rspec :size) "));")
            (when (rspec :free) (line "if (jrl_ret) " (rspec :free) "(jrl_ret);"))
            "jrl_result")
          :string
          (do
            (line "Janet jrl_result = "
                  (if (rspec :size)
                    (string "jrl_ret ? janet_stringv((const uint8_t *) jrl_ret, (int32_t) (" (rspec :size) ")) : janet_wrap_nil();")
                    "jrl_wrap_cstring(jrl_ret);"))
            (when (rspec :free) (line "if (jrl_ret) " (rspec :free) "(jrl_ret);"))
            "jrl_result")
          :handle-array
          (string "(jrl_ret ? jrl_array_owned(JRL_K_TYPE, &" (type-sym (rct :base))
                  ", jrl_ret, (int32_t) (" (rspec :count) ")) : janet_wrap_nil())")
          (do (problem c-name ": unknown return kind " rkind) "janet_wrap_nil()")))
      (pos? (rct :ptr))
      (if (and (= (rct :base) "char") (= 1 (rct :ptr)) (rct :const))
        (do (line "const char *jrl_ret = " call ";") "jrl_wrap_cstring(jrl_ret)")
        (do (problem c-name ": pointer return " ret " needs an override") "janet_wrap_nil()"))
      (= (rct :base) "long")
      (do (line "long jrl_ret = " call ";") "janet_wrap_number((double) jrl_ret)")
      (scalar-kinds (rct :base))
      (do
        (line (rct :base) " jrl_ret = " call ";")
        (case (rct :base)
          "bool" "janet_wrap_boolean(jrl_ret)"
          "int" "janet_wrap_integer(jrl_ret)"
          "unsigned char" "janet_wrap_integer(jrl_ret)"
          "janet_wrap_number((double) jrl_ret)"))
      (value-type? (rct :base))
      (do
        (line (canonical (rct :base)) " jrl_ret = " call ";")
        (if (handle? (rct :base))
          (string "jrl_handle_new(&" (type-sym (rct :base)) ", &jrl_ret, 0)")
          (string "jrl_to_janet(&" (type-sym (rct :base)) ", &jrl_ret, janet_wrap_nil())")))
      (do (problem c-name ": unsupported return type " ret) "janet_wrap_nil()")))
  (when ret-expr (line "Janet jrl_value = " ret-expr ";"))
  (when-let [owner (rspec :owner)]
    (line "jrl_handle_attach(jrl_value, argv[" ((find |(= ($ :c-name) owner) plans) :index) "]);")
    (array/push notes (string "keeps " (kebab owner) " alive")))
  (each p plans
    (when (p :consumed)
      (when (= (p :kind) :handle)
        (line "jrl_adopt(argv[" (p :index) "], jrl_value);")
        (array/push notes (string (kebab (p :c-name)) " becomes owned by the result")))))
  (each s post (line s))
  (def all-results (if ret-expr [(string "jrl_value") ;results] results))
  (cond
    (empty? all-results) (line "return janet_wrap_nil();")
    (one? (length all-results)) (line "return " (first all-results) ";")
    (do
      (line "Janet jrl_results[" (length all-results) "] = {" (string/join all-results ", ") "};")
      (line "return janet_wrap_tuple(janet_tuple_n(jrl_results, " (length all-results) "));")))
  (bpush out "}\n")
  # documentation
  (def args (seq [p :in plans :when (p :index)] (kebab (p :c-name))))
  (def signature (string "(" (plan :name) (if (empty? args) "" (string " " (string/join args " "))) ")"))
  (def ret-names
    (let [outs (seq [p :in plans
                     :when (or (and (= (p :kind) :out) (not (p :consumed)))
                               (= (p :kind) :inout) (= (p :kind) :out-bytes))]
                 (kebab (p :c-name)))]
      (if (= ret "void") outs [(if rkind (string rkind) "result") ;outs])))
  (when (> (length ret-names) 1)
    (array/push notes (string "returns [" (string/join ret-names " ") "]")))
  (each p plans
    (case (p :kind)
      :unload (array/push notes (string (kebab (p :c-name)) " is unloaded; later use raises an error"))
      :unload-array (array/push notes (string (kebab (p :c-name)) " (an array from a Load* call) is unloaded"))
      :handle-ptr (array/push notes (string (kebab (p :c-name)) " is edited in place"))
      :inout (array/push notes (string (kebab (p :c-name)) " is returned updated"))
      :array (when (p :count) (array/push notes (string (kebab (p :c-name)) " is a tuple/array; its length fills " (kebab (p :count)))))
      :bytes (when (p :count) (array/push notes (string (kebab (p :c-name)) " is bytes; its length fills " (kebab (p :count)))))
      :enum (array/push notes (string (kebab (p :c-name)) " accepts " (p :enum) " keywords"))))
  [(string out) signature notes])

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

(defn c-string [s]
  (string "\"" (string/replace-all "\n" "\\n" (string/replace-all "\"" "\\\"" (string/replace-all "\\" "\\\\" s))) "\""))

(defn c-signature [f]
  (string (f :return) " " (f :c-name) "("
          (string/join (map |(string ($ :type) (if (= ($ :type) "...") "" (string " " ($ :name)))) (f :params)) ", ")
          ")"))

(def header-banner "/* Generated by gen/gen.janet from the api directory and overrides.jdn. Do not edit. */\n")

(def plans @{})
(def all-names @{})
(defn- claim-name [name what]
  (when-let [prev (all-names name)]
    (problem "Janet name " name " is used by both " prev " and " what))
  (put all-names name what))

(each h header-names
  (put plans h (map |(plan-function h $) ((apis h) :functions))))

(defn emit-header-file [h]
  (def out @"")
  (bpush out header-banner "#include \"jrl.h\"\n#include \"types.h\"\n\n")
  (def regs @[])
  (def docs @[])
  (each plan (plans h)
    (cond
      (plan :skip) (array/push docs [plan nil nil])
      (plan :manual) (do (claim-name (plan :name) (plan :c-name)) (array/push docs [plan nil nil]))
      (let [[text signature notes] (emit-function plan)]
        (claim-name (plan :name) (plan :c-name))
        (bpush out "/* " (c-signature plan) " */\n" text "\n")
        (def docstring (string signature "\n\n" (plan :description)
                         (if (empty? notes) "" (string "\n\n" (string/join notes "; ") "."))
                         "\n\nC: " (c-signature plan)))
        (array/push regs [(plan :name) (string "jrl_cfun_" (plan :c-name)) docstring])
        (array/push docs [plan signature notes]))))
  # deprecated function aliases declared as macros in raylib.h (GetMouseRay)
  (each d ((apis h) :defines)
    (when (and (= (d :type) "UNKNOWN") (= :upper (char-class ((d :name) 0)))
               (not (string/find "_" (d :name))) (not= (d :name) "RLAPI") (not= (d :name) "RMAPI"))
      (def target (find |(= ($ :c-name) (d :value)) (plans h)))
      (when (and target (not (target :skip)) (not (target :manual)))
        (def name (function-name (d :name) (target :return)))
        (claim-name name (d :name))
        (array/push regs [name (string "jrl_cfun_" (target :c-name))
                          (string "(" name " ...)\n\nDeprecated raylib alias of " (target :name) ".")]))))
  (bpush out "static const JanetRegExt jrl_" h "_cfuns[] = {\n")
  (each [name cfun docstring] regs
    (bpush out "    {" (c-string name) ", " cfun ", " (c-string docstring) ", __FILE__, __LINE__},\n"))
  (bpush out "    {NULL, NULL, NULL, NULL, 0}\n};\n\n")
  (bpush out "void jrl_register_" h "(JanetTable *env) {\n"
               "    janet_cfuns_ext(env, NULL, jrl_" h "_cfuns);\n}\n")
  [out docs])

(defn emit-types []
  (def h @"")
  (def c @"")
  (bpush h header-banner "#ifndef JRL_GEN_TYPES_H\n#define JRL_GEN_TYPES_H\n#include \"jrl.h\"\n\n")
  (bpush c header-banner "#include \"jrl.h\"\n#include \"types.h\"\n\n")
  (each name enum-order
    (bpush h "extern const JrlEnum jrl_enum_" name ";\n"))
  (bpush h "\n")
  (each name struct-order
    (bpush h "extern const JrlType jrl_type_" name ";\n"))
  (bpush h "\n#endif\n")
  # enums
  (each name enum-order
    (def e (enums name))
    (bpush c "static const JrlEnumMember jrl_enum_members_" name "[] = {\n")
    (each v (e :values)
      (bpush c "    {" (c-string (enum-key e (v :name))) ", " (v :name) "},\n"))
    (bpush c "};\nconst JrlEnum jrl_enum_" name " = {" (c-string name) ", jrl_enum_members_" name ", "
                 (length (e :values)) ", " (if (e :flags) 1 0) "};\n\n"))
  # colors
  (bpush c "const JrlColorName jrl_color_names[] = {\n")
  (each [key [r g b a]] colors
    (bpush c "    {" (c-string (string key)) ", {" r ", " g ", " b ", " a "}},\n"))
  (bpush c "};\nconst int32_t jrl_color_name_count = " (length colors) ";\n\n")
  # structs
  (each name struct-order
    (def shape (shape-of name))
    (def [records count-fns] (build-fields name))
    (each f count-fns (bpush c f))
    (bpush c "static const JrlField jrl_fields_" name "[] = {\n")
    (each r records
      (def [kind tptr] (or (r :kind) ["JRL_K_INT" "NULL"]))
      (bpush c "    {" (c-string (r :key)) ", " (r :shape) ", " kind ", " tptr ", "
                   (if (r :enum) (string "&" (enum-sym (r :enum))) "NULL") ", "
                   "offsetof(" name ", " (r :c) "), " (or (r :fixed) 0) ", "
                   (or (r :count) "NULL") ", " (or (r :inner) "NULL") ", " (if (r :readonly) 1 0) "},\n"))
    (bpush c "};\n")
    (when (= shape :handle)
      (bpush c "static const JanetAbstractType jrl_at_" name " = {\n"
                   "    \"raylib/" name "\", NULL, jrl_handle_gcmark, jrl_handle_get, jrl_handle_put,\n"
                   "    NULL, NULL, jrl_handle_tostring, NULL, NULL, jrl_handle_next, NULL, NULL, NULL, NULL\n};\n"))
    (bpush c "const JrlType jrl_type_" name " = {" (c-string name) ", sizeof(" name "), "
                 (case shape :tuple "JRL_SHAPE_TUPLE" :handle "JRL_SHAPE_HANDLE" "JRL_SHAPE_STRUCT") ", "
                 "jrl_fields_" name ", " (length records) ", "
                 (if (= shape :handle) (string "&jrl_at_" name) "NULL") "};\n\n"))
  # constants
  (bpush c "void jrl_register_types(JanetTable *env) {\n")
  (defn def-const [name expr docstring]
    (claim-name name docstring)
    (bpush c "    janet_def(env, " (c-string name) ", " expr ", " (c-string docstring) ");\n"))
  (each name enum-order
    (each v ((enums name) :values)
      (def-const (constant-name (v :name)) (string "janet_wrap_number((double) " (v :name) ")")
                 (string name " member " (v :name) (if (empty? (v :description)) "" (string ": " (v :description)))))))
  (def seen @{})
  (each h header-names
    (each d ((apis h) :defines)
      (def name (d :name))
      (def value
        (case (d :type)
          "INT" (string "janet_wrap_number((double) (" name "))")
          "FLOAT" (string "janet_wrap_number((double) (" name "))")
          "FLOAT_MATH" (string "janet_wrap_number((double) (" name "))")
          "DOUBLE" (string "janet_wrap_number((double) (" name "))")
          "STRING" (string "janet_cstringv(" name ")")
          "UNKNOWN" (when (and (string/find "_" name) (not= name "RLAPI") (not= name "RMAPI"))
                      (string "janet_wrap_number((double) (" name "))"))
          nil))
      (when (and value (not (seen name)))
        (put seen name true)
        (def-const (constant-name name) value
                   (string h ".h define " name
                           (if (= (d :type) "UNKNOWN") (string ", alias of " (d :value)) "")
                           (if (empty? (d :description)) "" (string ": " (d :description))))))))
  (bpush c "}\n")
  [h c])

(defn emit-api-md [docs-by-header]
  (def out @"")
  (defn stats [h]
    (def ps (plans h))
    [(count |(not (or ($ :skip) ($ :manual))) ps) (count |($ :manual) ps) (count |($ :skip) ps) (length ps)])
  (bpush out "# API\n\nGenerated by `gen/gen.janet` from raylib 5.5's headers (`api/*.jdn`) and `overrides.jdn`. Do not edit.\n\n")
  (bpush out "| Header | Generated | Hand-written | Excluded | Total |\n|---|---|---|---|---|\n")
  (each h header-names
    (def [g m s t] (stats h))
    (bpush out "| " h ".h | " g " | " m " | " s " | " t " |\n"))
  (def shadowed (sort (seq [name :keys all-names :when (in root-env (symbol name))] name)))
  (unless (empty? shadowed)
    (bpush out "\nThese names shadow Janet core bindings under `(use raylib)`; prefer `(import raylib :as rl)`: "
           (string/join (map |(string "`" $ "`") shadowed) ", ") ".\n"))
  (bpush out "\n## Excluded functions\n\n")
  (each h header-names
    (each p (plans h)
      (when (p :skip) (bpush out "- `" (p :c-name) "`: " (p :skip) "\n"))))
  (bpush out "\n## Hand-written functions\n\n")
  (each h header-names
    (each p (plans h)
      (when (p :manual) (bpush out "- `" (p :name) "` (`" (p :c-name) "`): " (p :manual) "\n"))))
  (eachp [name what] (overrides :extras)
    (bpush out "- `" name "`: " what "\n"))
  (each h header-names
    (bpush out "\n## " h ".h\n\n")
    (each [plan signature notes] (docs-by-header h)
      (unless (or (plan :skip) (plan :manual))
        (bpush out "- `" signature "`"
                     (if (empty? notes) "" (string " — " (string/join notes "; ")))
                     "\n"))))
  out)

(defn main [&]
  (os/mkdir "src/gen")
  (eachk name (overrides :extras) (claim-name name "src/manual.c"))
  (def docs @{})
  (def files @{})
  (each h header-names
    (def [text d] (emit-header-file h))
    (put docs h d)
    (put files (string "src/gen/" h ".c") text))
  (def [th tc] (emit-types))
  (put files "src/gen/types.h" th)
  (put files "src/gen/types.c" tc)
  (put files "API.md" (emit-api-md docs))
  (unless (empty? problems)
    (eprint "generation failed:")
    (each p (distinct problems) (eprint "  " p))
    (os/exit 1))
  (eachp [path text] files (spit path text))
  (def total (sum (map |(length (plans $)) header-names)))
  (def bound (sum (map (fn [h] (count |(not ($ :skip)) (plans h))) header-names)))
  (printf "generated %d of %d functions (%d excluded)" bound total (- total bound)))
