#ifndef UNITERM_TEXT_H
#define UNITERM_TEXT_H

#include <stdint.h>

/*
 * Strict UTF-8: no overlong forms, no surrogates, nothing above U+10FFFF. Returns nonzero for
 * valid text. This header is private to the target.
 */
int uniterm_valid_utf8(const uint8_t *bytes, int32_t length);

#endif
