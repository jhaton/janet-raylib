# Convert raylib_parser JSON output into committed JDN.
#
# usage: janet gen/api.janet INPUT.json OUTPUT.jdn
#
# The JDN keeps raylib_parser's field names as keywords and writes one
# record per line so that raylib version bumps produce reviewable diffs.

(def- json-grammar
  (peg/compile
    ~{:ws (any (set " \t\r\n"))
      :escape (* "\\" (+ (/ `"` `"`) (/ "\\" "\\") (/ "/" "/")
                         (/ "b" "\b") (/ "f" "\f") (/ "n" "\n")
                         (/ "r" "\r") (/ "t" "\t")
                         (/ (* "u" (<- (4 :h))) ,|(string/from-bytes (scan-number $ 16)))))
      :string (* `"` (% (any (+ :escape (<- (if-not (set "\"\\") 1))))) `"`)
      :number (/ (<- (* (? "-") :d+ (? (* "." :d+)) (? (* (set "eE") (? (set "+-")) :d+))))
                 ,scan-number)
      :true (/ "true" true)
      :false (/ "false" false)
      :null (/ "null" :null)
      :pair (* :ws (/ :string ,keyword) :ws ":" :value)
      :object (/ (* "{" (? (* :pair (any (* "," :pair)))) :ws "}") ,struct)
      :array (/ (* "[" (? (* :value (any (* "," :value)))) :ws "]") ,tuple)
      :value (* :ws (+ :object :array :string :number :true :false :null) :ws)
      :main (* :value -1)}))

(defn decode
  "Decode a JSON document into immutable Janet data with keyword keys."
  [text]
  (def result (peg/match json-grammar text))
  (unless result (error "invalid JSON input"))
  (first result))

(defn- write-section
  [out name records]
  (buffer/push out " " (string/format "%j" name) "\n  [")
  (var first? true)
  (each record records
    (buffer/push out (if first? "" "\n   ") (string/format "%j" record))
    (set first? false))
  (buffer/push out "]\n"))

(defn render
  "Render a decoded API description as line-per-record JDN."
  [api]
  (def out @"{\n")
  (each section [:defines :structs :aliases :enums :callbacks :functions]
    (write-section out section (get api section [])))
  (buffer/push out "}\n")
  out)

(defn main
  [_ input output]
  (def api (decode (slurp input)))
  (def text (render api))
  (unless (deep= (parse text) api)
    (error "rendered JDN does not round-trip"))
  (spit output text))
