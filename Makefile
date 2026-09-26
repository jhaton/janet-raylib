# janet-raylib: generated Janet bindings for raylib 5.5 (raylib.h, raymath.h, rlgl.h).
#
#   make            build the module (build/lib/raylib) and the static library
#   make test       headless tests
#   make smoke      open a window, draw, and capture build/smoke.png
#   make embed      build and run the C embedding example
#   make gen        regenerate src/gen, API.md, and the docs/ cheatsheets from api/ and overrides.jdn
#   make api        regenerate api/*.jdn from the raylib submodule's headers
#   make check-gen  fail if the committed generated files are stale

JANET ?= janet
CC ?= cc
AR ?= ar
JANET_PREFIX ?= $(abspath $(dir $(shell command -v $(JANET)))/..)
JANET_INCLUDE ?= $(JANET_PREFIX)/include
JANET_LIB ?= $(JANET_PREFIX)/lib

BUILD := build
RAYLIB := vendor/raylib/src
CFLAGS ?= -O2 -g
WARN := -Wall -Wextra
PIC := -fPIC
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Linux)
  GLFW_DEFINES ?= -D_GLFW_X11
  SYSLIBS := -lm -lpthread -ldl
else ifeq ($(UNAME_S),Darwin)
  GLFW_DEFINES ?=
  SYSLIBS := -framework OpenGL -framework Cocoa -framework IOKit -framework CoreAudio -framework CoreVideo
endif

RAYLIB_DEFINES := -DPLATFORM_DESKTOP_GLFW -DGRAPHICS_API_OPENGL_33 -D_GNU_SOURCE $(GLFW_DEFINES)
RAYLIB_CFLAGS := $(CFLAGS) $(PIC) -std=gnu99 -w $(RAYLIB_DEFINES) -I$(RAYLIB) -I$(RAYLIB)/external/glfw/include
RAYLIB_MODULES := rcore rshapes rtextures rtext rmodels raudio utils rglfw
RAYLIB_OBJS := $(RAYLIB_MODULES:%=$(BUILD)/raylib/%.o)

BIND_CFLAGS := $(CFLAGS) $(PIC) -std=c99 $(WARN) -Isrc -Iinclude -I$(RAYLIB) -I$(JANET_INCLUDE)
BIND_SRCS := src/jrl.c src/manual.c src/register.c \
             src/gen/types.c src/gen/raylib.c src/gen/raymath.c src/gen/rlgl.c
BIND_OBJS := $(BIND_SRCS:src/%.c=$(BUILD)/obj/%.o)

MODULE_DIR := $(BUILD)/lib/raylib
MODULE := $(MODULE_DIR)/native.so
STATIC := $(BUILD)/libjanet-raylib.a

.PHONY: all module static test smoke embed gen api check-gen clean

all: module static

module: $(MODULE) $(MODULE_DIR)/init.janet

static: $(STATIC)

$(BUILD)/raylib/%.o: $(RAYLIB)/%.c | $(BUILD)/raylib
	$(CC) $(RAYLIB_CFLAGS) -c $< -o $@

$(BUILD)/obj/%.o: src/%.c src/jrl.h src/gen/types.h | $(BUILD)/obj/gen
	$(CC) $(BIND_CFLAGS) -c $< -o $@

$(MODULE): $(BIND_OBJS) $(BUILD)/obj/module.o $(RAYLIB_OBJS) | $(MODULE_DIR)
	$(CC) -shared -o $@ $^ $(SYSLIBS)

$(MODULE_DIR)/init.janet: lib/raylib/init.janet | $(MODULE_DIR)
	cp $< $@

$(BUILD)/layer.c: lib/raylib/init.janet gen/embed-layer.janet | $(BUILD)
	$(JANET) gen/embed-layer.janet $< $@

$(BUILD)/obj/layer.o: $(BUILD)/layer.c | $(BUILD)/obj
	$(CC) $(BIND_CFLAGS) -c $< -o $@

$(STATIC): $(BIND_OBJS) $(BUILD)/obj/embed.o $(BUILD)/obj/layer.o $(RAYLIB_OBJS)
	rm -f $@
	$(AR) rcs $@ $^

test: module
	@for t in test/*.janet; do \
	  echo "== $$t"; \
	  JANET_PATH=$(BUILD)/lib $(JANET) $$t || exit 1; \
	done

smoke: module
	JANET_PATH=$(BUILD)/lib $(JANET) examples/smoke.janet $(BUILD)/smoke.png

$(BUILD)/embed-example: examples/embed/main.c $(STATIC)
	$(CC) $(CFLAGS) -std=c99 $(WARN) -Iinclude -I$(JANET_INCLUDE) $< -o $@ \
	  $(STATIC) $(JANET_LIB)/libjanet.a $(SYSLIBS) -rdynamic

embed: $(BUILD)/embed-example
	./$(BUILD)/embed-example

gen:
	$(JANET) gen/gen.janet
	$(JANET) gen/cheatsheet.janet

$(BUILD)/raylib_parser: vendor/raylib/parser/raylib_parser.c | $(BUILD)
	$(CC) -O1 -w -o $@ $<

api: $(BUILD)/raylib_parser
	cd $(RAYLIB) && ../../../$(BUILD)/raylib_parser -i raylib.h -o ../../../$(BUILD)/raylib_api.json -f JSON -d RLAPI
	cd $(RAYLIB) && ../../../$(BUILD)/raylib_parser -i raymath.h -o ../../../$(BUILD)/raymath_api.json -f JSON -d RMAPI
	cd $(RAYLIB) && ../../../$(BUILD)/raylib_parser -i rlgl.h -o ../../../$(BUILD)/rlgl_api.json -f JSON -d RLAPI -t "RLGL IMPLEMENTATION"
	for h in raylib raymath rlgl; do $(JANET) gen/api.janet $(BUILD)/$${h}_api.json api/$$h.jdn || exit 1; done

check-gen: gen
	git diff --exit-code -- src/gen API.md docs

compile_flags.txt:
	printf -- '-std=c99\n-Wall\n-Wextra\n-Isrc\n-Iinclude\n-I$(RAYLIB)\n-I$(JANET_INCLUDE)\n' > $@

$(BUILD) $(BUILD)/raylib $(BUILD)/obj $(BUILD)/obj/gen $(MODULE_DIR):
	mkdir -p $@

clean:
	rm -rf $(BUILD)
