# Embed lib/raylib/init.janet as a C byte array for static builds.
#
# usage: janet gen/embed-layer.janet INPUT.janet OUTPUT.c

(defn main
  [_ input output]
  (def source (slurp input))
  (def out @"/* Generated from lib/raylib/init.janet by gen/embed-layer.janet. */\n#include <stdint.h>\n\n")
  (buffer/push out "const unsigned char jrl_layer_source[] = {")
  (eachp [i byte] source
    (buffer/push out (if (zero? (% i 16)) "\n    " " ") (string byte) ","))
  (buffer/push out "\n    0\n};\nconst int32_t jrl_layer_source_length = " (string (length source)) ";\n")
  (spit output out))
