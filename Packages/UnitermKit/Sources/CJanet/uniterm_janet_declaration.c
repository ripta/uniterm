#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "janet.h"
#include "uniterm_janet.h"
#include "uniterm_text.h"

/*
 * Reading a script file's declaration.
 *
 * The file's first form may be `(declare-permissions ...)`. This reads it as data with Janet's own
 * parser, from the same bytes that the VM runs, and evaluates nothing. The parser merges equal
 * struct keys and drops a nil key or value, so a struct that says something other than what it
 * reads as could reach the review. The check below reads the parser's state before each struct
 * closes and can only refuse.
 *
 * Every value is examined right after the parser produces it, with no Janet allocation in between,
 * so the collector never runs while this code holds a value that nothing else holds. Errors are
 * raised with a Janet panic that this file's boundary catches, so none leaves this file.
 */

/*
 * The parser's private flag bits, from the pinned release's parser. A test of duplicate keys and
 * nil entries fails if a Janet upgrade moves them.
 */
#define PFLAG_CURLYBRACKETS 0x1000
#define PFLAG_ATSYM 0x10000
#define PFLAG_TOKEN 0x40000

#define DECLARATION_HEAD "declare-permissions"
#define MAX_VALUE_DEPTH 8
#define MAX_FORM_DEPTH 512
#define MESSAGE_CAPACITY UNITERM_JANET_DECLARATION_MESSAGE_CAPACITY

typedef struct output {
    char *data;
    size_t length;
    size_t capacity;
} output;

static __thread output json;
static __thread char message[MESSAGE_CAPACITY];
static __thread char hazard[MESSAGE_CAPACITY];

typedef enum role { ROLE_HEADER, ROLE_PERMISSION, ROLE_OTHER } role;

typedef enum field_type {
    TYPE_ANY,
    TYPE_KEYWORD,
    TYPE_STRING,
    TYPE_NUMBER,
    TYPE_STRINGS
} field_type;

static void fail(const char *format, ...) __attribute__((noreturn, format(printf, 1, 2)));

static void fail(const char *format, ...) {
    va_list arguments;

    va_start(arguments, format);
    vsnprintf(message, sizeof(message), format, arguments);
    va_end(arguments);

    janet_panic("declaration");
}

static void emit(const char *text, size_t length) {
    if (json.length + length > UNITERM_JANET_MAX_DECLARATION_BYTES) {
        fail("the declaration is over %d bytes", UNITERM_JANET_MAX_DECLARATION_BYTES);
    }

    if (json.length + length + 1 > json.capacity) {
        size_t capacity = json.capacity ? json.capacity * 2 : 1024;

        while (capacity < json.length + length + 1) capacity *= 2;

        char *grown = realloc(json.data, capacity);

        if (grown == NULL) fail("uniterm ran out of memory reading the declaration");

        json.data = grown;
        json.capacity = capacity;
    }

    memcpy(json.data + json.length, text, length);
    json.length += length;
    json.data[json.length] = '\0';
}

static void emit_text(const char *text) {
    emit(text, strlen(text));
}

static void emit_string(const uint8_t *bytes, int32_t length) {
    if (!uniterm_valid_utf8(bytes, length)) fail("a string in the declaration is not UTF-8");

    emit_text("\"");

    for (int32_t index = 0; index < length; index++) {
        uint8_t byte = bytes[index];
        char escape[8];

        if (byte == 0) {
            fail("a string in the declaration holds a NUL byte");
        } else if (byte == '"') {
            emit_text("\\\"");
        } else if (byte == '\\') {
            emit_text("\\\\");
        } else if (byte < 0x20) {
            snprintf(escape, sizeof(escape), "\\u%04x", byte);
            emit_text(escape);
        } else {
            emit((const char *)&byte, 1);
        }
    }

    emit_text("\"");
}

static int is_bracket_tuple(Janet value) {
    return janet_checktype(value, JANET_TUPLE) &&
           (janet_tuple_flag(janet_unwrap_tuple(value)) & JANET_TUPLE_FLAG_BRACKETCTOR);
}

/* A short phrase for the value, for a message. It copies, so nothing refers to Janet memory. */
static void describe(Janet value, char *out, size_t capacity) {
    switch (janet_type(value)) {
        case JANET_NIL:
            snprintf(out, capacity, "nil");
            break;
        case JANET_BOOLEAN:
            snprintf(out, capacity, "%s", janet_unwrap_boolean(value) ? "true" : "false");
            break;
        case JANET_NUMBER:
            snprintf(out, capacity, "a number");
            break;
        case JANET_STRING:
            snprintf(out, capacity, "a string");
            break;
        case JANET_KEYWORD:
            snprintf(out, capacity, "the keyword :%.60s", (const char *)janet_unwrap_keyword(value));
            break;
        case JANET_SYMBOL:
            snprintf(out, capacity, "the symbol %.60s", (const char *)janet_unwrap_symbol(value));
            break;
        case JANET_TUPLE:
            snprintf(out, capacity, "%s",
                     is_bracket_tuple(value) ? "a bracketed list"
                                             : "a parenthesized form, which is a call");
            break;
        case JANET_ARRAY:
            snprintf(out, capacity, "an array");
            break;
        case JANET_STRUCT:
            snprintf(out, capacity, "a struct");
            break;
        case JANET_TABLE:
            snprintf(out, capacity, "a table");
            break;
        case JANET_BUFFER:
            snprintf(out, capacity, "a buffer");
            break;
        default:
            snprintf(out, capacity, "a value that is not plain data");
            break;
    }
}

static int keyword_is(Janet value, const char *text) {
    return janet_checktype(value, JANET_KEYWORD) &&
           strcmp((const char *)janet_unwrap_keyword(value), text) == 0;
}

static field_type expected_type(role which, const char *key) {
    if (which == ROLE_HEADER) {
        if (strcmp(key, "id") == 0 || strcmp(key, "name") == 0) return TYPE_STRING;
    } else if (which == ROLE_PERMISSION) {
        if (strcmp(key, "kind") == 0 || strcmp(key, "name") == 0) return TYPE_KEYWORD;
        if (strcmp(key, "version") == 0) return TYPE_NUMBER;
        if (strcmp(key, "executable") == 0 || strcmp(key, "directory") == 0) return TYPE_STRING;
        if (strcmp(key, "environment") == 0) return TYPE_STRINGS;
    }

    return TYPE_ANY;
}

static const char *expected_phrase(field_type type) {
    switch (type) {
        case TYPE_KEYWORD:
            return "a keyword such as :pane-control";
        case TYPE_STRING:
            return "a string in double quotes";
        case TYPE_NUMBER:
            return "a whole number such as 1";
        case TYPE_STRINGS:
            return "a list of strings in square brackets, such as [\"HOME\" \"PATH\"]";
        default:
            return "plain data";
    }
}

static int is_data(Janet value) {
    switch (janet_type(value)) {
        case JANET_NUMBER:
        case JANET_STRING:
        case JANET_KEYWORD:
        case JANET_STRUCT:
            return 1;
        case JANET_TUPLE:
            return is_bracket_tuple(value);
        default:
            return 0;
    }
}

static void emit_struct(Janet value, role which, int depth);

static void emit_value(Janet value, field_type type, const char *field, int depth) {
    char found[96];

    describe(value, found, sizeof(found));

    char where[96];

    if (field) {
        snprintf(where, sizeof(where), "The value of :%.60s", field);
    } else {
        snprintf(where, sizeof(where), "A list item");
    }

    if (!is_data(value)) {
        fail("the declaration holds only literal data: keywords, strings, whole numbers, "
             "[bracketed lists], and {structs}. %s is %s",
             where, found);
    }

    switch (type) {
        case TYPE_KEYWORD:
            if (!janet_checktype(value, JANET_KEYWORD)) {
                fail(":%s takes %s, not %s", field, expected_phrase(type), found);
            }

            emit_string(janet_unwrap_keyword(value), janet_string_length(janet_unwrap_keyword(value)));

            return;

        case TYPE_STRING:
            if (!janet_checktype(value, JANET_STRING)) {
                fail(":%s takes %s, not %s", field, expected_phrase(type), found);
            }

            emit_string(janet_unwrap_string(value), janet_string_length(janet_unwrap_string(value)));

            return;

        case TYPE_NUMBER:
            break;

        case TYPE_STRINGS:
            if (!is_bracket_tuple(value)) {
                fail(":%s takes %s, not %s", field, expected_phrase(type), found);
            }

            break;

        case TYPE_ANY:
            break;
    }

    if (janet_checktype(value, JANET_NUMBER)) {
        double number = janet_unwrap_number(value);
        char text[32];

        if (type != TYPE_ANY && type != TYPE_NUMBER) {
            fail(":%s takes %s, not %s", field, expected_phrase(type), found);
        }

        if (!(number == floor(number)) || number < 0 || number > 999999999) {
            fail("a number in the declaration must be a whole number from 0 to 999999999, such as a "
                 "version of 1. %s is not",
                 where);
        }

        snprintf(text, sizeof(text), "%.0f", number);
        emit_text(text);

        return;
    }

    if (type == TYPE_NUMBER) fail(":%s takes %s, not %s", field, expected_phrase(type), found);

    if (janet_checktype(value, JANET_STRING) || janet_checktype(value, JANET_KEYWORD)) {
        JanetString text = janet_checktype(value, JANET_STRING) ? janet_unwrap_string(value)
                                                                 : janet_unwrap_keyword(value);

        emit_string(text, janet_string_length(text));

        return;
    }

    if (janet_checktype(value, JANET_TUPLE)) {
        const Janet *items = janet_unwrap_tuple(value);
        int32_t count = janet_tuple_length(items);

        if (depth >= MAX_VALUE_DEPTH) fail("the declaration nests values too deeply");

        emit_text("[");

        for (int32_t index = 0; index < count; index++) {
            if (index > 0) emit_text(",");

            if (type == TYPE_STRINGS && !janet_checktype(items[index], JANET_STRING)) {
                char item[96];

                describe(items[index], item, sizeof(item));
                fail(":%s takes a list of strings, and one item is %s", field, item);
            }

            emit_value(items[index], TYPE_ANY, field, depth + 1);
        }

        emit_text("]");

        return;
    }

    if (depth >= MAX_VALUE_DEPTH) fail("the declaration nests values too deeply");

    emit_struct(value, ROLE_OTHER, depth + 1);
}

static void emit_struct(Janet value, role which, int depth) {
    JanetStruct st = janet_unwrap_struct(value);
    const JanetKV *kv = NULL;
    int first = 1;

    emit_text("{");

    while ((kv = janet_dictionary_next(st, janet_struct_capacity(st), kv)) != NULL) {
        char found[96];

        if (!janet_checktype(kv->key, JANET_KEYWORD)) {
            describe(kv->key, found, sizeof(found));
            fail("a struct key in the declaration must be a keyword such as :kind, not %s", found);
        }

        JanetKeyword key = janet_unwrap_keyword(kv->key);

        if (!first) emit_text(",");

        first = 0;

        emit_string(key, janet_string_length(key));
        emit_text(":");
        emit_value(kv->value, expected_type(which, (const char *)key), (const char *)key, depth);
    }

    emit_text("}");
}

static int struct_has_kind(Janet value) {
    JanetStruct st = janet_unwrap_struct(value);
    const JanetKV *kv = NULL;

    while ((kv = janet_dictionary_next(st, janet_struct_capacity(st), kv)) != NULL) {
        if (keyword_is(kv->key, "kind")) return 1;
    }

    return 0;
}

static size_t edit_distance(const char *left, const char *right);

/* The first key of the struct that reads as a misspelled :kind, or NULL when none does. */
static const char *misspelled_kind_key(Janet value) {
    JanetStruct st = janet_unwrap_struct(value);
    const JanetKV *kv = NULL;

    while ((kv = janet_dictionary_next(st, janet_struct_capacity(st), kv)) != NULL) {
        if (!janet_checktype(kv->key, JANET_KEYWORD) || keyword_is(kv->key, "kind")) continue;

        const char *name = (const char *)janet_unwrap_keyword(kv->key);

        /* A key of one or two letters, such as :id, is within two edits of any four-letter word. */
        if (strlen(name) >= 3 && edit_distance(name, "kind") <= 2) return name;
    }

    return NULL;
}

static void convert_declaration(JanetTuple form) {
    int32_t count = janet_tuple_length(form);
    int32_t index = 1;

    emit_text("{");

    for (int32_t position = 1; position < count; position++) {
        if (!janet_checktype(form[position], JANET_STRUCT)) {
            char found[96];

            describe(form[position], found, sizeof(found));
            fail("the declaration holds only structs: an optional header with :id and :name, then "
                 "one struct for each permission. It has %s",
                 found);
        }
    }

    /*
     * This is the only place that decides a struct holds a likely misspelled :kind. It reports the
     * struct's place and the key, and the Swift reader words the message from that.
     */
    int typos = 0;

    for (int32_t position = 1; position < count; position++) {
        const char *key = struct_has_kind(form[position]) ? NULL : misspelled_kind_key(form[position]);
        char number[16];

        if (key == NULL) continue;

        emit_text(typos ? "," : "\"typos\":[");
        snprintf(number, sizeof(number), "%d", (int)position);
        emit_text("{\"struct\":");
        emit_text(number);
        emit_text(",\"key\":");
        emit_string((const uint8_t *)key, (int32_t)strlen(key));
        emit_text("}");
        typos++;
    }

    if (typos) emit_text("],");

    if (count > 1 && !struct_has_kind(form[1])) {
        /*
         * A header that holds a misspelled :kind is most likely a permission. Its fields are not
         * type checked as a header's, so the reader can name the typo.
         */
        emit_text("\"header\":");
        emit_struct(form[1], misspelled_kind_key(form[1]) ? ROLE_OTHER : ROLE_HEADER, 0);
        emit_text(",");
        index = 2;
    }

    emit_text("\"permissions\":[");

    for (int32_t position = index; position < count; position++) {
        if (position > index) emit_text(",");

        emit_struct(form[position], ROLE_PERMISSION, 0);
    }

    emit_text("]}");
}

static size_t edit_distance(const char *left, const char *right) {
    size_t left_length = strlen(left);
    size_t right_length = strlen(right);
    size_t row[96];

    if (right_length >= sizeof(row) / sizeof(row[0])) return right_length;

    for (size_t column = 0; column <= right_length; column++) row[column] = column;

    for (size_t line = 1; line <= left_length; line++) {
        size_t diagonal = row[0];

        row[0] = line;

        for (size_t column = 1; column <= right_length; column++) {
            size_t above = row[column];
            size_t cost = left[line - 1] == right[column - 1] ? 0 : 1;
            size_t best = diagonal + cost;

            if (row[column] + 1 < best) best = row[column] + 1;
            if (row[column - 1] + 1 < best) best = row[column - 1] + 1;

            row[column] = best;
            diagonal = above;
        }
    }

    return row[right_length];
}

/* True for a name that reads as a try at the declaration's name. */
static int near_miss(const char *name) {
    char normal[96];
    size_t length = strlen(name);

    if (length == 0 || length >= sizeof(normal)) return 0;

    for (size_t index = 0; index < length; index++) {
        char letter = name[index];

        normal[index] = letter == '_' ? '-' : (letter >= 'A' && letter <= 'Z') ? letter + 32 : letter;
    }

    normal[length] = '\0';

    if (strncmp(normal, "declare-perm", 12) == 0) return 1;

    return edit_distance(normal, DECLARATION_HEAD) <= 3;
}

static int head_is(Janet form, const char *name) {
    if (!janet_checktype(form, JANET_TUPLE)) return 0;

    const Janet *items = janet_unwrap_tuple(form);

    if (janet_tuple_length(items) == 0 || !janet_checktype(items[0], JANET_SYMBOL)) return 0;

    return strcmp((const char *)janet_unwrap_symbol(items[0]), name) == 0;
}

/* The line of the first declaration inside `form`, or 0 when it holds none. */
static int declaration_line(Janet form, int depth) {
    if (depth > MAX_FORM_DEPTH) fail("the file nests forms more than %d deep", MAX_FORM_DEPTH);

    switch (janet_type(form)) {
        case JANET_TUPLE: {
            const Janet *items = janet_unwrap_tuple(form);
            int32_t count = janet_tuple_length(items);

            /* Quoted forms are data, and so is a bracketed list that starts with the name. */
            if (head_is(form, "quote") || head_is(form, "quasiquote")) return 0;

            if (!is_bracket_tuple(form) && head_is(form, DECLARATION_HEAD)) {
                int line = (int)janet_tuple_sm_line(items);

                return line > 0 ? line : 1;
            }

            for (int32_t index = 0; index < count; index++) {
                int line = declaration_line(items[index], depth + 1);

                if (line) return line;
            }

            return 0;
        }

        case JANET_ARRAY: {
            JanetArray *array = janet_unwrap_array(form);

            for (int32_t index = 0; index < array->count; index++) {
                int line = declaration_line(array->data[index], depth + 1);

                if (line) return line;
            }

            return 0;
        }

        case JANET_STRUCT:
        case JANET_TABLE: {
            const JanetKV *kvs;
            int32_t capacity;
            const JanetKV *kv = NULL;

            if (janet_checktype(form, JANET_STRUCT)) {
                kvs = janet_unwrap_struct(form);
                capacity = janet_struct_capacity(kvs);
            } else {
                JanetTable *table = janet_unwrap_table(form);

                kvs = table->data;
                capacity = table->capacity;
            }

            while ((kv = janet_dictionary_next(kvs, capacity, kv)) != NULL) {
                int line = declaration_line(kv->key, depth + 1);

                if (!line) line = declaration_line(kv->value, depth + 1);
                if (line) return line;
            }

            return 0;
        }

        default:
            return 0;
    }
}

/* Returns 1 when `form`, the file's first, is the declaration, and converts it. */
static int inspect_first(Janet form) {
    if (janet_checktype(form, JANET_TUPLE)) {
        const Janet *items = janet_unwrap_tuple(form);

        if (janet_tuple_length(items) > 0 && janet_checktype(items[0], JANET_SYMBOL)) {
            const char *name = (const char *)janet_unwrap_symbol(items[0]);

            if (strcmp(name, DECLARATION_HEAD) == 0) {
                if (is_bracket_tuple(form)) {
                    fail("the declaration must be a parenthesized form: (declare-permissions ...)");
                }

                if (hazard[0]) fail("%s", hazard);

                convert_declaration(items);

                return 1;
            }

            if (near_miss(name)) {
                fail("the first form is (%.60s ...). If it is the declaration, spell it "
                     "declare-permissions exactly. The declaration must come first in the file, "
                     "after only a #! line and comments.",
                     name);
            }
        }
    }

    return 0;
}

/*
 * Called with the byte about to close a struct. A token still open before it is ended first, with a
 * space that Janet would read the same, so the parser's state shows every value the struct holds.
 */
static void note_struct_close(JanetParser *parser) {
    if (hazard[0] || parser->statecount == 0) return;

    JanetParseState *top = parser->states + parser->statecount - 1;

    if (top->flags & PFLAG_TOKEN) {
        size_t column = parser->column;

        janet_parser_consume(parser, ' ');
        parser->column = column;

        /* A token that does not read leaves an error for the caller's status check. */
        if (parser->error) return;

        top = parser->states + parser->statecount - 1;
    }

    if (!(top->flags & PFLAG_CURLYBRACKETS) || (top->flags & PFLAG_ATSYM)) return;

    if (top->argn % 2 != 0 || (size_t)top->argn > parser->argcount) return;

    const Janet *items = parser->args + parser->argcount - (size_t)top->argn;

    for (int32_t index = 0; index < top->argn; index += 2) {
        if (janet_checktype(items[index], JANET_NIL) ||
            janet_checktype(items[index + 1], JANET_NIL)) {
            snprintf(hazard, sizeof(hazard),
                     "a struct in the declaration has nil as a key or a value, which Janet would "
                     "drop. Remove the entry or give it a value.");

            return;
        }

        for (int32_t earlier = 0; earlier < index; earlier += 2) {
            if (janet_equals(items[earlier], items[index])) {
                char found[96];

                describe(items[index], found, sizeof(found));
                snprintf(hazard, sizeof(hazard),
                         "a struct in the declaration repeats a key (%s), and Janet would keep only "
                         "one of the two entries. List each key once.",
                         found);

                return;
            }
        }
    }
}

static uniterm_declaration_status scan(const uint8_t *source, size_t length) {
    JanetParser *parser = janet_abstract(&janet_parser_type, sizeof(JanetParser));
    size_t index = 0;
    size_t forms = 0;
    int first_is_declaration = 0;

    janet_parser_init(parser);
    janet_gcroot(janet_wrap_abstract(parser));

    for (;;) {
        while (janet_parser_has_more(parser)) {
            Janet form = janet_parser_produce(parser);

            if (forms == 0) {
                first_is_declaration = inspect_first(form);

                if (!first_is_declaration) {
                    int line = declaration_line(form, 0);

                    if (line) {
                        fail("(declare-permissions ...) at line %d must be the first form of the "
                             "file. Only a #! line, comments, and blank lines may come before it.",
                             line);
                    }
                }
            } else {
                int line = declaration_line(form, 0);

                if (line) {
                    if (first_is_declaration) {
                        fail("(declare-permissions ...) appears again at line %d. A file declares "
                             "its powers once, in its first form.",
                             line);
                    }

                    fail("(declare-permissions ...) at line %d must be the first form of the file. "
                         "Only a #! line, comments, and blank lines may come before it.",
                         line);
                }
            }

            forms++;
        }

        enum JanetParserStatus status = janet_parser_status(parser);

        /* A file that does not parse is reported by the run. Nothing is declared here. */
        if (status == JANET_PARSE_DEAD || status == JANET_PARSE_ERROR) break;

        if (index >= length) {
            janet_parser_eof(parser);
        } else {
            uint8_t byte = source[index++];

            if (forms == 0 && byte == '}') note_struct_close(parser);

            if (!parser->error) janet_parser_consume(parser, byte);
        }
    }

    return first_is_declaration ? UNITERM_DECLARATION_FOUND : UNITERM_DECLARATION_NONE;
}

uniterm_declaration_status uniterm_janet_read_declaration(const uint8_t *source, size_t length,
                                                          uniterm_declaration *declaration) {
    memset(declaration, 0, sizeof(*declaration));
    memset(&json, 0, sizeof(json));
    message[0] = '\0';
    hazard[0] = '\0';

    if (janet_init() != 0) {
        snprintf(declaration->message, sizeof(declaration->message), "Janet did not start");

        return UNITERM_DECLARATION_INVALID;
    }

    volatile uniterm_declaration_status status = UNITERM_DECLARATION_NONE;
    JanetTryState state;

    if (janet_try(&state) == JANET_SIGNAL_OK) {
        status = scan(source, length);
        janet_restore(&state);
    } else {
        janet_restore(&state);
        status = UNITERM_DECLARATION_INVALID;

        if (message[0] == '\0') {
            snprintf(message, sizeof(message), "uniterm could not read the file's first form");
        }
    }

    janet_deinit();

    if (status == UNITERM_DECLARATION_FOUND) {
        declaration->json = json.data;
        declaration->json_length = json.length;
    } else {
        free(json.data);

        if (status == UNITERM_DECLARATION_INVALID) {
            snprintf(declaration->message, sizeof(declaration->message), "%s", message);
        }
    }

    memset(&json, 0, sizeof(json));

    return status;
}

void uniterm_janet_free_declaration(uniterm_declaration *declaration) {
    free(declaration->json);
    declaration->json = NULL;
    declaration->json_length = 0;
}
