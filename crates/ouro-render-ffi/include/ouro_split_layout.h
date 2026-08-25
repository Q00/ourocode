#ifndef OURO_SPLIT_LAYOUT_H
#define OURO_SPLIT_LAYOUT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OURO_SPLIT_LAYOUT_ABI_VERSION 1u
#define OURO_SPLIT_TERMINAL_ID_MAX_BYTES 256u
#define OURO_SPLIT_LAYOUT_MAX_LEAVES 32u
#define OURO_SPLIT_LAYOUT_MAX_DEPTH 8u
#define OURO_SPLIT_LAYOUT_UNITS 1000000u

typedef struct OuroSplitLayout OuroSplitLayout;

typedef enum OuroSplitLayoutResult {
    OURO_SPLIT_LAYOUT_OK = 0,
    OURO_SPLIT_LAYOUT_INVALID_ARGUMENT = 1,
    OURO_SPLIT_LAYOUT_BUFFER_TOO_SMALL = 2,
    OURO_SPLIT_LAYOUT_NOT_FOUND = 3,
    OURO_SPLIT_LAYOUT_LIMIT_EXCEEDED = 4,
    OURO_SPLIT_LAYOUT_BUSY = 5,
    OURO_SPLIT_LAYOUT_CANNOT_CLOSE_LAST_LEAF = 6,
    OURO_SPLIT_LAYOUT_STALE_SNAPSHOT = 7,
    OURO_SPLIT_LAYOUT_INTERNAL_ERROR = 8,
} OuroSplitLayoutResult;

typedef enum OuroSplitAxis {
    OURO_SPLIT_AXIS_LEFT_RIGHT = 0,
    OURO_SPLIT_AXIS_TOP_BOTTOM = 1,
} OuroSplitAxis;

typedef enum OuroSplitPlacement {
    OURO_SPLIT_PLACEMENT_BEFORE = 0,
    OURO_SPLIT_PLACEMENT_AFTER = 1,
} OuroSplitPlacement;

typedef enum OuroSplitFocusDirection {
    OURO_SPLIT_FOCUS_LEFT = 0,
    OURO_SPLIT_FOCUS_RIGHT = 1,
    OURO_SPLIT_FOCUS_UP = 2,
    OURO_SPLIT_FOCUS_DOWN = 3,
} OuroSplitFocusDirection;

typedef enum OuroSplitResizeCause {
    OURO_SPLIT_RESIZE_DIVIDER_COMMIT = 0,
    OURO_SPLIT_RESIZE_KEYBOARD = 1,
    OURO_SPLIT_RESIZE_EQUALIZE = 2,
} OuroSplitResizeCause;

/* IDs are UTF-8, contain no control characters, and are not NUL terminated. */
typedef struct OuroSplitTerminalId {
    size_t size;
    uint32_t abi_version;
    size_t length;
    uint8_t bytes[OURO_SPLIT_TERMINAL_ID_MAX_BYTES];
} OuroSplitTerminalId;

typedef struct OuroSplitLayoutConfig {
    size_t size;
    uint32_t abi_version;
    uint32_t max_leaves;
    uint32_t max_depth;
} OuroSplitLayoutConfig;

typedef struct OuroSplitLayoutSnapshot {
    size_t size;
    uint32_t abi_version;
    uint64_t revision;
    size_t leaf_count;
    OuroSplitTerminalId focused_terminal;
} OuroSplitLayoutSnapshot;

typedef struct OuroSplitLeafGeometry {
    size_t size;
    uint32_t abi_version;
    uint64_t node_id;
    uint32_t x;
    uint32_t y;
    uint32_t width;
    uint32_t height;
    OuroSplitTerminalId terminal_id;
} OuroSplitLeafGeometry;

typedef struct OuroSplitFocusResult {
    size_t size;
    uint32_t abi_version;
    uint8_t moved;
    OuroSplitTerminalId focused_terminal;
} OuroSplitFocusResult;

typedef struct OuroSplitPresentationUpdate {
    size_t size;
    uint32_t abi_version;
    uint64_t divider_node_id;
    uint16_t ratio_basis_points;
} OuroSplitPresentationUpdate;

/* `affected_count` is the number of records copied to the caller-owned
 * affected-terminals buffer. `has_value == 0` means the ratio did not change. */
typedef struct OuroSplitResizeIntent {
    size_t size;
    uint32_t abi_version;
    uint8_t has_value;
    OuroSplitResizeCause cause;
    uint64_t layout_revision;
    size_t affected_count;
} OuroSplitResizeIntent;

/* Every non-ID output struct must be initialized by the caller with its
 * `size` and `abi_version`. Output terminal-ID records are fully overwritten. */

#if UINTPTR_MAX == UINT64_MAX
#if defined(__cplusplus)
#define OURO_SPLIT_STATIC_ASSERT(condition, message) static_assert(condition, message)
#else
#define OURO_SPLIT_STATIC_ASSERT(condition, message) _Static_assert(condition, message)
#endif
OURO_SPLIT_STATIC_ASSERT(sizeof(OuroSplitLayoutResult) == 4, "result enum layout");
OURO_SPLIT_STATIC_ASSERT(sizeof(OuroSplitAxis) == 4, "axis enum layout");
OURO_SPLIT_STATIC_ASSERT(sizeof(OuroSplitTerminalId) == 280, "terminal id layout");
OURO_SPLIT_STATIC_ASSERT(offsetof(OuroSplitTerminalId, bytes) == 24, "terminal id bytes offset");
OURO_SPLIT_STATIC_ASSERT(sizeof(OuroSplitLayoutConfig) == 24, "config layout");
OURO_SPLIT_STATIC_ASSERT(sizeof(OuroSplitLayoutSnapshot) == 312, "snapshot layout");
OURO_SPLIT_STATIC_ASSERT(offsetof(OuroSplitLayoutSnapshot, focused_terminal) == 32, "snapshot focus offset");
OURO_SPLIT_STATIC_ASSERT(sizeof(OuroSplitLeafGeometry) == 320, "leaf geometry layout");
OURO_SPLIT_STATIC_ASSERT(offsetof(OuroSplitLeafGeometry, terminal_id) == 40, "leaf terminal offset");
OURO_SPLIT_STATIC_ASSERT(sizeof(OuroSplitFocusResult) == 296, "focus result layout");
OURO_SPLIT_STATIC_ASSERT(offsetof(OuroSplitFocusResult, focused_terminal) == 16, "focus terminal offset");
OURO_SPLIT_STATIC_ASSERT(sizeof(OuroSplitPresentationUpdate) == 32, "presentation update layout");
OURO_SPLIT_STATIC_ASSERT(sizeof(OuroSplitResizeIntent) == 40, "resize intent layout");
#undef OURO_SPLIT_STATIC_ASSERT
#endif

OuroSplitLayoutResult ouro_split_layout_new(
    const OuroSplitLayoutConfig *config,
    const OuroSplitTerminalId *initial_terminal,
    OuroSplitLayout **out_layout);
void ouro_split_layout_free(OuroSplitLayout *layout);

OuroSplitLayoutResult ouro_split_layout_snapshot(
    OuroSplitLayout *layout,
    OuroSplitLayoutSnapshot *out_snapshot);
/* A NULL buffer with zero capacity is a required-count query. A stale
 * expected revision or short buffer copies no geometry. */
OuroSplitLayoutResult ouro_split_layout_copy_leaf_geometries(
    OuroSplitLayout *layout,
    uint64_t expected_revision,
    OuroSplitLeafGeometry *geometries,
    size_t geometry_capacity,
    size_t *out_geometry_count);

OuroSplitLayoutResult ouro_split_layout_focus(
    OuroSplitLayout *layout,
    const OuroSplitTerminalId *terminal);
OuroSplitLayoutResult ouro_split_layout_focus_direction(
    OuroSplitLayout *layout,
    OuroSplitFocusDirection direction,
    OuroSplitFocusResult *out_result);
OuroSplitLayoutResult ouro_split_layout_can_split_focused(
    OuroSplitLayout *layout,
    uint8_t *out_can_split);
OuroSplitLayoutResult ouro_split_layout_split_focused(
    OuroSplitLayout *layout,
    OuroSplitAxis axis,
    const OuroSplitTerminalId *new_terminal,
    OuroSplitPlacement placement,
    uint64_t *out_divider_node_id);
OuroSplitLayoutResult ouro_split_layout_close(
    OuroSplitLayout *layout,
    const OuroSplitTerminalId *terminal);

OuroSplitLayoutResult ouro_split_layout_begin_divider_drag(
    OuroSplitLayout *layout,
    uint64_t divider_node_id,
    OuroSplitPresentationUpdate *out_update);
OuroSplitLayoutResult ouro_split_layout_update_divider_drag(
    OuroSplitLayout *layout,
    uint32_t position_from_start,
    uint32_t available_span,
    OuroSplitPresentationUpdate *out_update);
/* Mutation is fail-closed unless `affected_terminals` has capacity for every
 * current leaf. This keeps BUFFER_TOO_SMALL from consuming a drag or changing
 * a committed ratio. */
OuroSplitLayoutResult ouro_split_layout_commit_divider_drag(
    OuroSplitLayout *layout,
    OuroSplitTerminalId *affected_terminals,
    size_t affected_capacity,
    OuroSplitResizeIntent *out_intent);
OuroSplitLayoutResult ouro_split_layout_cancel_divider_drag(
    OuroSplitLayout *layout,
    OuroSplitPresentationUpdate *out_update);
OuroSplitLayoutResult ouro_split_layout_resize_divider_keyboard(
    OuroSplitLayout *layout,
    uint64_t divider_node_id,
    int16_t delta_basis_points,
    OuroSplitTerminalId *affected_terminals,
    size_t affected_capacity,
    OuroSplitResizeIntent *out_intent);
/* Resets every divider in the recursive tree to 50/50 and emits at most one
 * bounded resize intent covering the visible terminal leaves. */
OuroSplitLayoutResult ouro_split_layout_equalize(
    OuroSplitLayout *layout,
    OuroSplitTerminalId *affected_terminals,
    size_t affected_capacity,
    OuroSplitResizeIntent *out_intent);

#ifdef __cplusplus
}
#endif

#endif
