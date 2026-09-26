#include "janet_raylib.h"
#include "jrl.h"

void janet_raylib_register(JanetTable *env) {
    jrl_register_types(env);
    jrl_register_raylib(env);
    jrl_register_raymath(env);
    jrl_register_rlgl(env);
    jrl_register_manual(env);
}
