#ifndef RESOLVER_SYMBOL_H
#define RESOLVER_SYMBOL_H

#include "ast/ast.h"

typedef enum { NS_VALUE, NS_TYPE } Namespace;

// 16 bytes, 8-aligned, no padding. The name span is packed Token-style (start + 24-bit len) with
// the Namespace stored in the token-type slot, so identity is (hash, name bytes, namespace).
typedef struct {
    uint32_t hash; // FNV-1a of the source bytes; compared before the bytes to skip mismatches fast
    NodeId decl;   // declaring node
    Token name;    // token_start/token_len give the source span; token_type holds the Namespace
} Symbol;

VEC_DECLARE(Symbol, Symbol_Vec)

#endif // RESOLVER_SYMBOL_H
