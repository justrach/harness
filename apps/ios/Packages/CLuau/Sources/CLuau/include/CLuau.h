#ifndef CLUAU_H
#define CLUAU_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CLuauSandbox CLuauSandbox;

typedef enum {
    CLUAU_NODE_COLUMN = 0,
    CLUAU_NODE_ROW = 1,
    CLUAU_NODE_TEXT = 2,
    CLUAU_NODE_STAT = 3,
    CLUAU_NODE_CHART = 4,
    CLUAU_NODE_BUTTON = 5,
    CLUAU_NODE_TOGGLE = 6,
    CLUAU_NODE_SLIDER = 7,
    CLUAU_NODE_RULE = 8,
} CLuauNodeKind;

typedef struct {
    CLuauNodeKind kind;
    const char *text;
    double value;
    double min_value;
    double max_value;
    uint64_t handler_id;
    int has_handler;
    size_t values_offset;
    size_t values_count;
    size_t labels_offset;
    size_t labels_count;
    size_t children_offset;
    size_t children_count;
} CLuauNode;

typedef struct {
    CLuauNode *nodes;
    size_t nodes_count;
    double *values;
    size_t values_count;
    const char **chart_labels;
    size_t chart_labels_count;
    size_t *child_indices;
    size_t child_indices_count;
} CLuauTree;

CLuauSandbox *cluau_sandbox_create(const char *source, size_t source_len, char *err_buf, size_t err_cap);
void cluau_sandbox_destroy(CLuauSandbox *sandbox);

size_t cluau_sandbox_memory_used(const CLuauSandbox *sandbox);
void cluau_sandbox_gc(CLuauSandbox *sandbox);

CLuauTree *cluau_sandbox_render(CLuauSandbox *sandbox, char *err_buf, size_t err_cap);
CLuauTree *cluau_sandbox_call_click(CLuauSandbox *sandbox, uint64_t handler_id, char *err_buf, size_t err_cap);
CLuauTree *cluau_sandbox_call_bool(CLuauSandbox *sandbox, uint64_t handler_id, int value, char *err_buf, size_t err_cap);
CLuauTree *cluau_sandbox_call_number(CLuauSandbox *sandbox, uint64_t handler_id, double value, char *err_buf, size_t err_cap);
void cluau_tree_free(CLuauTree *tree);

#ifdef __cplusplus
}
#endif

#endif
