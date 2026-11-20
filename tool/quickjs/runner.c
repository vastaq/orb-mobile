// The executable runs entirely in Wasm. WASI exposes only selected project
// files and streams. QuickJS receives no OS module, module loader, or host JS.
#include "quickjs.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

__attribute__((import_module("orb"), import_name("started"))) void orb_started(void);

enum { INPUT_LIMIT = 256 * 1024 };

static char *read_stream(FILE *stream, size_t *size) {
    char *text = malloc(INPUT_LIMIT + 1);
    if (!text) return NULL;
    *size = fread(text, 1, INPUT_LIMIT, stream);
    if (*size == INPUT_LIMIT || ferror(stream)) {
        free(text);
        return NULL;
    }
    text[*size] = '\0'; // JS_Eval also needs a terminator.
    return text;
}

static JSValue read_text(JSContext *ctx, JSValueConst self, int argc,
                         JSValueConst *argv, int from_stdin) {
    FILE *stream = stdin;
    if (!from_stdin) {
        if (argc != 1 || !JS_IsString(argv[0]))
            return JS_ThrowTypeError(ctx, "readText requires a selected file path");
        size_t length;
        const char *path = JS_ToCStringLen(ctx, &length, argv[0]);
        if (!path) return JS_EXCEPTION;
        stream = memchr(path, '\0', length) ? NULL : fopen(path, "rb");
        JS_FreeCString(ctx, path);
        if (!stream) return JS_ThrowReferenceError(ctx, "File not found in input_paths");
    }
    size_t length;
    char *text = read_stream(stream, &length);
    if (!from_stdin) fclose(stream);
    if (!text) return JS_ThrowInternalError(ctx, "Cannot read bounded UTF-8 input");
    JSValue value = JS_NewStringLen(ctx, text, length);
    free(text);
    return value;
}

static JSValue print_line(JSContext *ctx, JSValueConst self, int argc,
                          JSValueConst *argv, int is_error) {
    FILE *stream = is_error ? stderr : stdout;
    for (int i = 0; i < argc; i++) {
        size_t length;
        const char *text = JS_ToCStringLen(ctx, &length, argv[i]);
        if (!text) return JS_EXCEPTION;
        if (i) fputc(' ', stream);
        fwrite(text, 1, length, stream);
        JS_FreeCString(ctx, text);
    }
    fputc('\n', stream);
    return JS_UNDEFINED;
}

static void show_exception(JSContext *ctx) {
    JSValue error = JS_GetException(ctx);
    JSValue stack = JS_GetPropertyStr(ctx, error, "stack");
    const char *message = JS_ToCString(ctx, error);
    const char *trace = JS_IsString(stack) ? JS_ToCString(ctx, stack) : NULL;
    fprintf(stderr, "%s\n%s", message ? message : "JavaScript exception", trace ? trace : "");
    JS_FreeCString(ctx, trace);
    JS_FreeCString(ctx, message);
    JS_FreeValue(ctx, stack);
    JS_FreeValue(ctx, error);
}

static void track_rejection(JSContext *ctx, JSValueConst promise, JSValueConst reason,
                            JS_BOOL handled, void *opaque) {
    *(int *)opaque += handled ? -1 : 1;
}

int main(int argc, char **argv) {
    if (argc != 2) return 1;
    FILE *entry = fopen(argv[1], "rb");
    if (!entry) { fputs("Cannot open JavaScript entry", stderr); return 1; }
    size_t size;
    char *source = read_stream(entry, &size);
    fclose(entry);
    if (!source) { fputs("Cannot read JavaScript entry", stderr); return 1; }
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) return 1;
    JS_SetMemoryLimit(rt, 48 * 1024 * 1024);
    JS_SetMaxStackSize(rt, 384 * 1024);
    int rejections = 0;
    JS_SetHostPromiseRejectionTracker(rt, track_rejection, &rejections);
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) return 1;
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue console = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, console, "log", JS_NewCFunctionMagic(ctx, print_line, "log", 1, JS_CFUNC_generic_magic, 0));
    JS_SetPropertyStr(ctx, console, "error", JS_NewCFunctionMagic(ctx, print_line, "error", 1, JS_CFUNC_generic_magic, 1));
    JS_SetPropertyStr(ctx, global, "console", console);
    JS_SetPropertyStr(ctx, global, "readText", JS_NewCFunctionMagic(ctx, read_text, "readText", 1, JS_CFUNC_generic_magic, 0));
    JS_SetPropertyStr(ctx, global, "readStdin", JS_NewCFunctionMagic(ctx, read_text, "readStdin", 0, JS_CFUNC_generic_magic, 1));
    JS_FreeValue(ctx, global);
    JSValue compiled = JS_Eval(ctx, source, size, argv[1], JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY);
    free(source);
    if (JS_IsException(compiled)) { show_exception(ctx); return 1; }
    orb_started();
    JSValue value = JS_EvalFunction(ctx, compiled);
    if (JS_IsException(value)) { show_exception(ctx); return 1; }
    JS_FreeValue(ctx, value);
    JSContext *job_ctx;
    int pending;
    while ((pending = JS_ExecutePendingJob(rt, &job_ctx)) > 0) {}
    if (pending < 0) { show_exception(job_ctx); return 1; }
    if (rejections) { fputs("Unhandled JavaScript promise rejection", stderr); return 1; }
    return 0; // The host discards this instance at the end of each invocation.
}
