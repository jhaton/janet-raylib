/*
 * janet_raylib.h - embed the raylib binding in a C program.
 *
 * Link libjanet-raylib.a (which contains raylib) and libjanet, then:
 *
 *     janet_init();
 *     JanetTable *env = janet_core_env(NULL);
 *     janet_raylib_preload(env);
 *     janet_dostring(env, "(import raylib) ...", "main", NULL);
 */
#ifndef JANET_RAYLIB_H
#define JANET_RAYLIB_H

#include <janet.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Define every raylib, raymath, and rlgl binding and constant in env. */
void janet_raylib_register(JanetTable *env);

/* Preload the modules "raylib/native" (the generated bindings) and "raylib"
 * (the Janet convenience layer) into module/cache, so scripts can import them
 * without any files on disk. Returns 0 on success, nonzero if the layer failed
 * to compile. */
int janet_raylib_preload(JanetTable *env);

#ifdef __cplusplus
}
#endif

#endif
