//
//  json.c
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#include "json.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------- tokenising -- */

static json_tok *alloc_tok(json_tok *tokens, unsigned max, int *count)
{
    if ((unsigned)*count >= max)
        return NULL;
    json_tok *t = &tokens[(*count)++];
    t->type   = JSON_UNDEFINED;
    t->start  = -1;
    t->end    = -1;
    t->size   = 0;
    t->parent = -1;
    return t;
}

int json_parse(const char *js, size_t len, json_tok *tokens, unsigned max)
{
    if (!js || !tokens || max == 0)
        return -EINVAL;

    int count = 0;
    /* Explicit stack rather than recursion: the depth of the input is chosen
     * by whoever wrote the medium, and a recursive parser hands them the
     * call stack. */
    int stack[JSON_MAX_DEPTH];
    int depth = 0;

    for (size_t i = 0; i < len; i++) {
        char c = js[i];
        json_tok *t;

        switch (c) {
        case '{':
        case '[':
            t = alloc_tok(tokens, max, &count);
            if (!t) return -ENOSPC;
            t->type   = (c == '{') ? JSON_OBJECT : JSON_ARRAY;
            t->start  = (int)i;
            if (depth > 0) {
                t->parent = stack[depth - 1];
                tokens[stack[depth - 1]].size++;
            }
            if (depth >= JSON_MAX_DEPTH)
                return -E2BIG;
            stack[depth++] = count - 1;
            break;

        case '}':
        case ']': {
            if (depth == 0)
                return -EINVAL;
            json_tok *open = &tokens[stack[depth - 1]];
            json_type want = (c == '}') ? JSON_OBJECT : JSON_ARRAY;
            if (open->type != want)
                return -EINVAL;
            open->end = (int)i + 1;
            depth--;
            break;
        }

        case '"': {
            size_t start = i + 1;
            i++;
            for (; i < len; i++) {
                if (js[i] == '"')
                    break;
                /* Skip the character after a backslash so an escaped quote
                 * does not end the string. The escape itself is not decoded:
                 * nothing LUKS2 stores in a field we read needs it, and
                 * json_copy refuses anything it cannot represent. */
                if (js[i] == '\\' && i + 1 < len)
                    i++;
            }
            if (i >= len)
                return -EINVAL;

            t = alloc_tok(tokens, max, &count);
            if (!t) return -ENOSPC;
            t->type  = JSON_STRING;
            t->start = (int)start;
            t->end   = (int)i;
            if (depth > 0) {
                t->parent = stack[depth - 1];
                tokens[stack[depth - 1]].size++;
            }
            break;
        }

        case '\t': case '\r': case '\n': case ' ':
        case ':':  case ',':
            break;

        default: {
            /* A primitive runs until a structural character. */
            size_t start = i;
            for (; i < len; i++) {
                switch (js[i]) {
                case '\t': case '\r': case '\n': case ' ':
                case ',':  case ']':  case '}':  case ':':
                    goto primitive_done;
                default:
                    /* Anything outside printable ASCII here is malformed. */
                    if ((unsigned char)js[i] < 32 || (unsigned char)js[i] >= 127)
                        return -EINVAL;
                    break;
                }
            }
        primitive_done:
            t = alloc_tok(tokens, max, &count);
            if (!t) return -ENOSPC;
            t->type  = JSON_PRIMITIVE;
            t->start = (int)start;
            t->end   = (int)i;
            if (depth > 0) {
                t->parent = stack[depth - 1];
                tokens[stack[depth - 1]].size++;
            }
            i--;   /* the structural character is re-read by the loop */
            break;
        }
        }
    }

    if (depth != 0)
        return -EINVAL;   /* something was never closed */
    return count;
}

/* ---------------------------------------------------------------- walking -- */

int json_skip(const json_tok *t, int count, int idx)
{
    if (idx < 0 || idx >= count)
        return count;
    int end = t[idx].end;
    int i = idx + 1;
    while (i < count && t[i].start < end)
        i++;
    return i;
}

bool json_equals(const char *js, const json_tok *t, int idx, const char *s)
{
    if (idx < 0 || !s)
        return false;
    size_t n = (size_t)(t[idx].end - t[idx].start);
    return strlen(s) == n && strncmp(js + t[idx].start, s, n) == 0;
}

/*
 * Iteration is bounded by the container's extent, not by its `size`.
 *
 * `size` counts every token whose parent is this one, which for an object
 * means keys *and* values -- so using it as a member count walks twice as far
 * as it should and off the end of the container. The byte range is
 * unambiguous, so that is what bounds the walk.
 */
int json_object_get(const char *js, const json_tok *t, int count,
                    int obj, const char *key)
{
    if (obj < 0 || obj >= count || t[obj].type != JSON_OBJECT)
        return -1;

    const int limit = t[obj].end;
    int i = obj + 1;
    while (i < count && t[i].start < limit) {
        int k = i;
        int v = json_skip(t, count, k);
        if (v >= count || t[v].start >= limit)
            break;
        if (t[k].type == JSON_STRING && json_equals(js, t, k, key))
            return v;
        i = json_skip(t, count, v);
    }
    return -1;
}

int json_array_get(const char *js, const json_tok *t, int count, int arr, int n)
{
    (void)js;
    if (arr < 0 || arr >= count || t[arr].type != JSON_ARRAY || n < 0)
        return -1;

    const int limit = t[arr].end;
    int i = arr + 1;
    for (int e = 0; i < count && t[i].start < limit; e++) {
        if (e == n)
            return i;
        i = json_skip(t, count, i);
    }
    return -1;
}

int json_object_count(const json_tok *t, int count, int obj)
{
    if (obj < 0 || obj >= count || t[obj].type != JSON_OBJECT)
        return 0;
    const int limit = t[obj].end;
    int i = obj + 1, members = 0;
    while (i < count && t[i].start < limit) {
        int v = json_skip(t, count, i);
        if (v >= count || t[v].start >= limit)
            break;
        members++;
        i = json_skip(t, count, v);
    }
    return members;
}

bool json_copy(const char *js, const json_tok *t, int idx,
               char *out, size_t out_len)
{
    if (idx < 0 || !out || out_len == 0)
        return false;
    size_t n = (size_t)(t[idx].end - t[idx].start);
    if (n >= out_len)
        return false;
    memcpy(out, js + t[idx].start, n);
    out[n] = 0;
    return true;
}

bool json_get_u64(const char *js, const json_tok *t, int idx, uint64_t *out)
{
    if (idx < 0 || !out)
        return false;
    if (t[idx].type != JSON_PRIMITIVE && t[idx].type != JSON_STRING)
        return false;

    size_t n = (size_t)(t[idx].end - t[idx].start);
    if (n == 0 || n > 20)
        return false;

    uint64_t v = 0;
    for (size_t i = 0; i < n; i++) {
        char c = js[t[idx].start + i];
        if (c < '0' || c > '9')
            return false;
        if (v > (UINT64_MAX - (uint64_t)(c - '0')) / 10)
            return false;   /* would overflow */
        v = v * 10 + (uint64_t)(c - '0');
    }
    *out = v;
    return true;
}

/* ----------------------------------------------------------------- base64 -- */

static int b64_value(char c)
{
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

int base64_decode(const char *in, size_t in_len, uint8_t *out, size_t out_len)
{
    if (!in || !out || (in_len % 4) != 0)
        return -1;

    size_t produced = 0;
    for (size_t i = 0; i < in_len; i += 4) {
        int v[4];
        int pad = 0;
        for (int j = 0; j < 4; j++) {
            char c = in[i + j];
            if (c == '=') {
                /* Padding is only legal in the last group, and only in the
                 * last two positions. */
                if (i + 4 != in_len || j < 2)
                    return -1;
                v[j] = 0;
                pad++;
            } else {
                v[j] = b64_value(c);
                if (v[j] < 0 || pad)
                    return -1;
            }
        }

        uint32_t triple = ((uint32_t)v[0] << 18) | ((uint32_t)v[1] << 12)
                        | ((uint32_t)v[2] << 6)  |  (uint32_t)v[3];
        int bytes = 3 - pad;
        for (int j = 0; j < bytes; j++) {
            if (produced >= out_len)
                return -1;
            out[produced++] = (uint8_t)(triple >> (16 - 8 * j));
        }
    }
    return (int)produced;
}
