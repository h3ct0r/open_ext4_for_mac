//
//  json.h
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  A small JSON reader, for the metadata area of a LUKS2 header.
//
//  Deliberately minimal, and deliberately paranoid. This parses a structure
//  that lives on removable media: an attacker who can hand someone a USB stick
//  chooses every byte of it. So there is no recursion (a nesting stack with a
//  hard ceiling instead), every token is bounds-checked against the buffer, and
//  the token array is supplied by the caller so allocation cannot be driven
//  from the input.
//
//  It tokenises rather than building a tree: LUKS2 needs perhaps a dozen fields
//  out of the document, and walking tokens to find them is less machinery than
//  materialising the whole thing.
//

#ifndef JSON_H
#define JSON_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    JSON_UNDEFINED = 0,
    JSON_OBJECT,
    JSON_ARRAY,
    JSON_STRING,
    JSON_PRIMITIVE,     /* number, true, false, null */
} json_type;

typedef struct {
    json_type type;
    int       start;    /* byte offset of the value, quotes excluded */
    int       end;      /* one past the last byte                    */
    int       size;     /* members for an object, elements for an array */
    int       parent;   /* index of the containing token, -1 at the top */
} json_tok;

/// Deepest nesting accepted. LUKS2 uses four or five levels; anything beyond
/// this is not a document we need to understand.
#define JSON_MAX_DEPTH 32

/// Tokenise. Returns the number of tokens used, or a negative errno:
/// -EINVAL for malformed input, -ENOSPC when `max` tokens are not enough,
/// -E2BIG when the nesting is deeper than JSON_MAX_DEPTH.
int json_parse(const char *js, size_t len, json_tok *tokens, unsigned max);

/// Index of the value for `key` inside the object at `obj`, or -1.
int json_object_get(const char *js, const json_tok *t, int count,
                    int obj, const char *key);

/// True when the string or primitive at `idx` equals `s`.
bool json_equals(const char *js, const json_tok *t, int idx, const char *s);

/// Copy the token's text out, always NUL-terminated. Returns false if it does
/// not fit, rather than truncating silently.
bool json_copy(const char *js, const json_tok *t, int idx,
               char *out, size_t out_len);

/// Read an unsigned integer.
///
/// LUKS2 writes values that can exceed 2^53 -- byte offsets, area sizes -- as
/// JSON *strings*, because JSON numbers are doubles by specification. So both
/// forms are accepted here; refusing the string form would fail on every real
/// header.
bool json_get_u64(const char *js, const json_tok *t, int idx, uint64_t *out);

/// How many key/value pairs the object at `obj` has.
int json_object_count(const json_tok *t, int count, int obj);

/// Element `n` of the array at `arr`, or -1.
int json_array_get(const char *js, const json_tok *t, int count, int arr, int n);

/// Index just past the whole subtree rooted at `idx`; use it to step over a
/// value without descending into it.
int json_skip(const json_tok *t, int count, int idx);

/// Standard base64 with padding, as LUKS2 stores salts and digests.
/// Returns the number of bytes written, or -1.
int base64_decode(const char *in, size_t in_len, uint8_t *out, size_t out_len);

#ifdef __cplusplus
}
#endif

#endif /* JSON_H */
