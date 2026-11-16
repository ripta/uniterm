#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "janet.h"
#include "uniterm_janet.h"

/*
 * Reading a script file's forms as data, for the lint.
 *
 * The file is parsed with Janet's own parser and nothing is evaluated. Each form is copied into
 * malloc'd arrays right after the parser produces it, with no Janet allocation in between, so the
 * collector never runs while this code holds a value that nothing else holds. Errors are raised
 * with a Janet panic that this file's boundary catches, so none leaves this file.
 */

#define MAX_FORM_DEPTH 512
#define MESSAGE_CAPACITY UNITERM_JANET_DECLARATION_MESSAGE_CAPACITY

static __thread uniterm_forms *target;
static __thread size_t node_capacity;
static __thread size_t text_capacity;
static __thread char message[MESSAGE_CAPACITY];

static void fail(const char *format, ...) __attribute__((noreturn, format(printf, 1, 2)));

static void fail(const char *format, ...) {
    va_list arguments;

    va_start(arguments, format);
    vsnprintf(message, sizeof(message), format, arguments);
    va_end(arguments);

    janet_panic("forms");
}

static size_t add_node(int32_t kind, int32_t line, int32_t column) {
    if (target->node_count == node_capacity) {
        size_t capacity = node_capacity ? node_capacity * 2 : 256;
        uniterm_form_node *grown = realloc(target->nodes, capacity * sizeof(uniterm_form_node));

        if (grown == NULL) fail("uniterm ran out of memory reading the file");

        target->nodes = grown;
        node_capacity = capacity;
    }

    size_t index = target->node_count++;
    uniterm_form_node *node = &target->nodes[index];

    memset(node, 0, sizeof(*node));
    node->kind = kind;
    node->line = line;
    node->column = column;

    return index;
}

static void set_text(size_t index, const uint8_t *bytes, int32_t length) {
    if (target->text_length + (size_t)length + 1 > text_capacity) {
        size_t capacity = text_capacity ? text_capacity * 2 : 1024;

        while (capacity < target->text_length + (size_t)length + 1) capacity *= 2;

        char *grown = realloc(target->text, capacity);

        if (grown == NULL) fail("uniterm ran out of memory reading the file");

        target->text = grown;
        text_capacity = capacity;
    }

    memcpy(target->text + target->text_length, bytes, (size_t)length);
    target->nodes[index].text_offset = target->text_length;
    target->nodes[index].text_length = (size_t)length;
    target->text_length += (size_t)length;
    target->text[target->text_length] = '\0';
}

static void convert(Janet form, int depth, int32_t line, int32_t column);

static void convert_children(size_t index, const Janet *items, int32_t count, int depth,
                             int32_t line, int32_t column) {
    for (int32_t position = 0; position < count; position++) {
        convert(items[position], depth + 1, line, column);
    }

    target->nodes[index].children = count;
}

static void convert_dictionary(size_t index, const JanetKV *kvs, int32_t capacity, int depth,
                               int32_t line, int32_t column) {
    const JanetKV *kv = NULL;
    int32_t count = 0;

    while ((kv = janet_dictionary_next(kvs, capacity, kv)) != NULL) {
        convert(kv->key, depth + 1, line, column);
        convert(kv->value, depth + 1, line, column);
        count += 2;
    }

    target->nodes[index].children = count;
}

static void convert(Janet form, int depth, int32_t line, int32_t column) {
    if (depth > MAX_FORM_DEPTH) fail("the file nests forms more than %d levels deep", MAX_FORM_DEPTH);

    switch (janet_type(form)) {
        case JANET_SYMBOL:
        case JANET_KEYWORD:
        case JANET_STRING: {
            int32_t kind = janet_checktype(form, JANET_SYMBOL)    ? UNITERM_FORM_SYMBOL
                           : janet_checktype(form, JANET_KEYWORD) ? UNITERM_FORM_KEYWORD
                                                                  : UNITERM_FORM_STRING;
            size_t index = add_node(kind, line, column);
            const uint8_t *bytes = janet_unwrap_string(form);

            set_text(index, bytes, janet_string_length(bytes));

            return;
        }

        case JANET_TUPLE: {
            const Janet *items = janet_unwrap_tuple(form);
            int32_t sm_line = janet_tuple_sm_line(items);
            int32_t sm_column = janet_tuple_sm_column(items);

            if (sm_line > 0) {
                line = sm_line;
                column = sm_column;
            }

            int bracket = (janet_tuple_flag(items) & JANET_TUPLE_FLAG_BRACKETCTOR) != 0;
            size_t index = add_node(bracket ? UNITERM_FORM_BRACKET : UNITERM_FORM_PAREN, line, column);

            convert_children(index, items, janet_tuple_length(items), depth, line, column);

            return;
        }

        case JANET_ARRAY: {
            JanetArray *array = janet_unwrap_array(form);
            size_t index = add_node(UNITERM_FORM_ARRAY, line, column);

            convert_children(index, array->data, array->count, depth, line, column);

            return;
        }

        case JANET_STRUCT: {
            const JanetKV *kvs = janet_unwrap_struct(form);
            size_t index = add_node(UNITERM_FORM_STRUCT, line, column);

            convert_dictionary(index, kvs, janet_struct_capacity(kvs), depth, line, column);

            return;
        }

        case JANET_TABLE: {
            JanetTable *table = janet_unwrap_table(form);
            size_t index = add_node(UNITERM_FORM_TABLE, line, column);

            convert_dictionary(index, table->data, table->capacity, depth, line, column);

            return;
        }

        default:
            add_node(UNITERM_FORM_ATOM, line, column);

            return;
    }
}

static uniterm_forms_status scan(const uint8_t *source, size_t length) {
    JanetParser *parser = janet_abstract(&janet_parser_type, sizeof(JanetParser));
    size_t index = 0;

    janet_parser_init(parser);
    janet_gcroot(janet_wrap_abstract(parser));

    for (;;) {
        while (janet_parser_has_more(parser)) {
            Janet form = janet_parser_produce(parser);

            convert(form, 0, (int32_t)parser->line, (int32_t)parser->column);
            target->root_count++;
        }

        const char *error = janet_parser_error(parser);

        if (error != NULL) {
            snprintf(target->message, sizeof(target->message), "%s", error);
            target->error_line = (int32_t)parser->line;
            target->error_column = (int32_t)parser->column;

            return UNITERM_FORMS_ERROR;
        }

        if (janet_parser_status(parser) == JANET_PARSE_DEAD) return UNITERM_FORMS_OK;

        if (index >= length) {
            janet_parser_eof(parser);

            continue;
        }

        janet_parser_consume(parser, source[index++]);
    }
}

uniterm_forms_status uniterm_janet_parse_forms(const uint8_t *source, size_t length,
                                               uniterm_forms *forms) {
    memset(forms, 0, sizeof(*forms));
    message[0] = '\0';
    target = forms;
    node_capacity = 0;
    text_capacity = 0;

    if (janet_init() != 0) {
        snprintf(forms->message, sizeof(forms->message), "Janet did not start");

        return UNITERM_FORMS_ERROR;
    }

    volatile uniterm_forms_status status = UNITERM_FORMS_OK;
    JanetTryState state;

    if (janet_try(&state) == JANET_SIGNAL_OK) {
        status = scan(source, length);
        janet_restore(&state);
    } else {
        janet_restore(&state);
        status = UNITERM_FORMS_ERROR;

        snprintf(forms->message, sizeof(forms->message), "%s",
                 message[0] ? message : "uniterm could not read the file");
    }

    janet_deinit();
    target = NULL;

    if (status != UNITERM_FORMS_OK) {
        free(forms->nodes);
        free(forms->text);
        forms->nodes = NULL;
        forms->text = NULL;
        forms->node_count = 0;
        forms->text_length = 0;
        forms->root_count = 0;
    }

    return status;
}

void uniterm_janet_free_forms(uniterm_forms *forms) {
    free(forms->nodes);
    free(forms->text);
    forms->nodes = NULL;
    forms->text = NULL;
    forms->node_count = 0;
    forms->text_length = 0;
}
