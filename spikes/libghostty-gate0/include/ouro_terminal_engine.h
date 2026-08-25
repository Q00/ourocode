#ifndef OURO_TERMINAL_ENGINE_H
#define OURO_TERMINAL_ENGINE_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Ourocode-owned terminal-engine ABI.
 *
 * Nothing from libghostty is exposed here. This header is the upgrade and
 * licensing boundary between the application/broker and an experimental
 * engine adapter. Keep every struct sized and versioned so an older client
 * can reject an incompatible adapter instead of guessing layouts.
 */
#define OURO_TERMINAL_ENGINE_ABI_VERSION 6u
/* Product renderers use one reusable scratch buffer of this bounded size. */
#define OURO_RENDER_MAX_GRAPHEME_BYTES 256u
/* Input text is bounded before it reaches the exact-pin key encoder. */
#define OURO_TERMINAL_MAX_KEY_TEXT_BYTES 4096u
/* Twelve bytes are reserved for the two bracketed-paste delimiters. */
#define OURO_TERMINAL_MAX_PASTE_SOURCE_BYTES (65536u - 12u)

typedef struct OuroTerminal OuroTerminal;
typedef struct OuroTerminalPageBudget OuroTerminalPageBudget;
typedef struct OuroRenderProjection OuroRenderProjection;
typedef struct OuroRenderFrame OuroRenderFrame;
typedef struct OuroTerminalInput OuroTerminalInput;
typedef struct OuroTerminalSelection OuroTerminalSelection;

typedef enum OuroTerminalResult {
    OURO_TERMINAL_OK = 0,
    OURO_TERMINAL_INVALID_ARGUMENT = 1,
    OURO_TERMINAL_OUT_OF_MEMORY = 2,
    OURO_TERMINAL_ENGINE_ERROR = 3,
    OURO_TERMINAL_BUFFER_TOO_SMALL = 4,
    /* An optional value is absent. This is a normal, non-fatal result. */
    OURO_TERMINAL_NO_VALUE = 5,
} OuroTerminalResult;

typedef enum OuroTerminalOptionAsAlt {
    OURO_TERMINAL_OPTION_AS_ALT_FALSE = 0,
    OURO_TERMINAL_OPTION_AS_ALT_TRUE = 1,
    OURO_TERMINAL_OPTION_AS_ALT_LEFT = 2,
    OURO_TERMINAL_OPTION_AS_ALT_RIGHT = 3,
} OuroTerminalOptionAsAlt;

typedef enum OuroTerminalKeyAction {
    OURO_TERMINAL_KEY_RELEASE = 0,
    OURO_TERMINAL_KEY_PRESS = 1,
    OURO_TERMINAL_KEY_REPEAT = 2,
} OuroTerminalKeyAction;

typedef uint16_t OuroTerminalModifiers;
#define OURO_TERMINAL_MOD_SHIFT ((OuroTerminalModifiers)(1u << 0))
#define OURO_TERMINAL_MOD_CTRL ((OuroTerminalModifiers)(1u << 1))
#define OURO_TERMINAL_MOD_ALT ((OuroTerminalModifiers)(1u << 2))
#define OURO_TERMINAL_MOD_SUPER ((OuroTerminalModifiers)(1u << 3))
#define OURO_TERMINAL_MOD_CAPS_LOCK ((OuroTerminalModifiers)(1u << 4))
#define OURO_TERMINAL_MOD_NUM_LOCK ((OuroTerminalModifiers)(1u << 5))
#define OURO_TERMINAL_MOD_SHIFT_RIGHT ((OuroTerminalModifiers)(1u << 6))
#define OURO_TERMINAL_MOD_CTRL_RIGHT ((OuroTerminalModifiers)(1u << 7))
#define OURO_TERMINAL_MOD_ALT_RIGHT ((OuroTerminalModifiers)(1u << 8))
#define OURO_TERMINAL_MOD_SUPER_RIGHT ((OuroTerminalModifiers)(1u << 9))
#define OURO_TERMINAL_MOD_ALL ((OuroTerminalModifiers)0x03ffu)

typedef struct OuroTerminalInputConfig {
    size_t size;
    uint32_t abi_version;
    OuroTerminalOptionAsAlt option_as_alt;
} OuroTerminalInputConfig;

/*
 * `hid_usage` is a USB HID Keyboard/Keypad page (0x07) usage. The adapter
 * performs the layout-independent mapping to the exact-pin Ghostty key enum.
 * `utf8` is borrowed only for the synchronous call and must be valid UTF-8.
 * Preedit text must never be passed here; use `composing` for a composing key
 * event, then send only committed IME text with the committed-text function.
 */
typedef struct OuroTerminalKeyEvent {
    size_t size;
    uint32_t abi_version;
    uint32_t hid_usage;
    OuroTerminalKeyAction action;
    OuroTerminalModifiers modifiers;
    OuroTerminalModifiers consumed_modifiers;
    bool composing;
    uint32_t unshifted_codepoint;
    const uint8_t *utf8;
    size_t utf8_length;
} OuroTerminalKeyEvent;

typedef enum OuroTerminalMouseAction {
    OURO_TERMINAL_MOUSE_PRESS = 0,
    OURO_TERMINAL_MOUSE_RELEASE = 1,
    OURO_TERMINAL_MOUSE_MOTION = 2,
} OuroTerminalMouseAction;

typedef enum OuroTerminalMouseButton {
    OURO_TERMINAL_MOUSE_BUTTON_NONE = 0,
    OURO_TERMINAL_MOUSE_BUTTON_LEFT = 1,
    OURO_TERMINAL_MOUSE_BUTTON_RIGHT = 2,
    OURO_TERMINAL_MOUSE_BUTTON_MIDDLE = 3,
    OURO_TERMINAL_MOUSE_BUTTON_FOUR = 4,
    OURO_TERMINAL_MOUSE_BUTTON_FIVE = 5,
    OURO_TERMINAL_MOUSE_BUTTON_SIX = 6,
    OURO_TERMINAL_MOUSE_BUTTON_SEVEN = 7,
    OURO_TERMINAL_MOUSE_BUTTON_EIGHT = 8,
    OURO_TERMINAL_MOUSE_BUTTON_NINE = 9,
    OURO_TERMINAL_MOUSE_BUTTON_TEN = 10,
    OURO_TERMINAL_MOUSE_BUTTON_ELEVEN = 11,
} OuroTerminalMouseButton;

typedef struct OuroTerminalMouseGeometry {
    size_t size;
    uint32_t abi_version;
    double screen_width;
    double screen_height;
    double cell_width;
    double cell_height;
    double padding_top;
    double padding_bottom;
    double padding_right;
    double padding_left;
} OuroTerminalMouseGeometry;

typedef struct OuroTerminalMouseEvent {
    size_t size;
    uint32_t abi_version;
    OuroTerminalMouseAction action;
    OuroTerminalMouseButton button;
    OuroTerminalModifiers modifiers;
    double x;
    double y;
} OuroTerminalMouseEvent;

typedef enum OuroTerminalScrollDirection {
    OURO_TERMINAL_SCROLL_UP = 0,
    OURO_TERMINAL_SCROLL_DOWN = 1,
    OURO_TERMINAL_SCROLL_LEFT = 2,
    OURO_TERMINAL_SCROLL_RIGHT = 3,
} OuroTerminalScrollDirection;

typedef struct OuroTerminalScrollEvent {
    size_t size;
    uint32_t abi_version;
    OuroTerminalScrollDirection direction;
    OuroTerminalModifiers modifiers;
    double x;
    double y;
} OuroTerminalScrollEvent;

/*
 * Viewport movement does not mutate terminal contents. Absolute rows use the
 * same top-origin row space returned by OuroTerminalScrollbar::offset.
 */
typedef enum OuroTerminalScrollViewportKind {
    OURO_TERMINAL_SCROLL_VIEWPORT_TOP = 0,
    OURO_TERMINAL_SCROLL_VIEWPORT_BOTTOM = 1,
    OURO_TERMINAL_SCROLL_VIEWPORT_DELTA = 2,
    OURO_TERMINAL_SCROLL_VIEWPORT_ROW = 3,
} OuroTerminalScrollViewportKind;

typedef struct OuroTerminalScrollViewport {
    size_t size;
    uint32_t abi_version;
    OuroTerminalScrollViewportKind kind;
    /* Used only by DELTA. Negative values move toward older history. */
    int64_t delta;
    /* Used only by ROW. Zero is the oldest retained row. */
    uint64_t row;
} OuroTerminalScrollViewport;

typedef struct OuroTerminalScrollbar {
    size_t size;
    uint32_t abi_version;
    uint64_t total;
    uint64_t offset;
    uint64_t length;
} OuroTerminalScrollbar;

typedef struct OuroTerminalSelectionConfig {
    size_t size;
    uint32_t abi_version;
    size_t copy_max_bytes;
    double repeat_distance_px;
    uint64_t repeat_interval_ns;
} OuroTerminalSelectionConfig;

typedef struct OuroTerminalSelectionPoint {
    size_t size;
    uint32_t abi_version;
    uint16_t column;
    uint32_t row;
    double surface_x;
    double surface_y;
    bool has_time;
    uint64_t time_ns;
} OuroTerminalSelectionPoint;

typedef struct OuroTerminalSelectionGeometry {
    size_t size;
    uint32_t abi_version;
    uint32_t columns;
    double cell_width;
    double padding_left;
    double screen_height;
} OuroTerminalSelectionGeometry;

typedef enum OuroTerminalSelectionAutoscroll {
    OURO_TERMINAL_SELECTION_AUTOSCROLL_NONE = 0,
    OURO_TERMINAL_SELECTION_AUTOSCROLL_UP = 1,
    OURO_TERMINAL_SELECTION_AUTOSCROLL_DOWN = 2,
} OuroTerminalSelectionAutoscroll;

typedef enum OuroTerminalDirty {
    OURO_TERMINAL_DIRTY_NONE = 0,
    OURO_TERMINAL_DIRTY_PARTIAL = 1,
    OURO_TERMINAL_DIRTY_FULL = 2,
} OuroTerminalDirty;

/* Typed scheduling result for idle scrollback compression. */
typedef enum OuroTerminalCompressionResult {
    OURO_TERMINAL_COMPRESSION_UNSUPPORTED = 0,
    OURO_TERMINAL_COMPRESSION_PENDING = 1,
    OURO_TERMINAL_COMPRESSION_COMPLETE = 2,
} OuroTerminalCompressionResult;

typedef struct OuroTerminalConfig {
    size_t size;
    uint32_t abi_version;
    uint16_t columns;
    uint16_t rows;
    uint32_t cell_width_px;
    uint32_t cell_height_px;
    size_t scrollback_max_bytes;
    size_t scrollback_max_lines;
    uint64_t kitty_image_max_bytes;
    size_t apc_max_bytes;
    size_t continuation_max_bytes;
    size_t snapshot_max_bytes;
    /*
     * Hard cap for allocations routed through GhosttyAllocator. The pinned
     * engine's native terminal-page mmap regions are separately bounded by
     * scrollback policy and are not included in this counter.
     */
    size_t engine_memory_max_bytes;
} OuroTerminalConfig;

typedef struct OuroTerminalFrameInfo {
    size_t size;
    uint32_t abi_version;
    uint16_t columns;
    uint16_t rows;
    uint16_t cursor_x;
    uint16_t cursor_y;
    OuroTerminalDirty dirty;
} OuroTerminalFrameInfo;

/* Exact requested-byte accounting for GhosttyAllocator-mediated allocations. */
typedef struct OuroTerminalMemoryInfo {
    size_t size;
    uint32_t abi_version;
    size_t live_bytes;
    size_t peak_bytes;
    size_t limit_bytes;
    uint64_t allocation_failures;
} OuroTerminalMemoryInfo;

/*
 * Shared accounting for Ghostty-owned terminal page mappings. Charges follow
 * the upstream runtime-page rounding policy. This is not a process RSS cap.
 */
typedef struct OuroTerminalPageBudgetStats {
    size_t size;
    uint32_t abi_version;
    size_t limit_bytes;
    size_t reserved_bytes;
    size_t peak_reserved_bytes;
    size_t denial_count;
    size_t child_failure_count;
} OuroTerminalPageBudgetStats;

typedef struct OuroRenderProjectionConfig {
    size_t size;
    uint32_t abi_version;
    /* Hard cap for the projection-owned GhosttyAllocator. */
    size_t memory_max_bytes;
    /* Per-cell UTF-8 copy bound; must not exceed the ABI hard maximum. */
    size_t max_grapheme_bytes;
} OuroRenderProjectionConfig;

typedef struct OuroRenderProjectionMemoryInfo {
    size_t size;
    uint32_t abi_version;
    size_t live_bytes;
    size_t peak_bytes;
    size_t limit_bytes;
    uint64_t allocation_failures;
} OuroRenderProjectionMemoryInfo;

typedef struct OuroRenderRgb {
    uint8_t r;
    uint8_t g;
    uint8_t b;
} OuroRenderRgb;

typedef enum OuroRenderColorKind {
    OURO_RENDER_COLOR_DEFAULT = 0,
    OURO_RENDER_COLOR_PALETTE = 1,
    OURO_RENDER_COLOR_RGB = 2,
} OuroRenderColorKind;

typedef struct OuroRenderColor {
    OuroRenderColorKind kind;
    uint8_t palette_index;
    OuroRenderRgb rgb;
} OuroRenderColor;

typedef enum OuroRenderCursorStyle {
    OURO_RENDER_CURSOR_BAR = 0,
    OURO_RENDER_CURSOR_BLOCK = 1,
    OURO_RENDER_CURSOR_UNDERLINE = 2,
    OURO_RENDER_CURSOR_BLOCK_HOLLOW = 3,
} OuroRenderCursorStyle;

typedef enum OuroRenderFrameDisposition {
    /*
     * Every row and cell was merged into a renderer-owned, lossless CPU cache.
     * This is deliberately unrelated to GPU submission or screen presentation.
     */
    OURO_RENDER_FRAME_COMMITTED = 0,
    OURO_RENDER_FRAME_DROPPED = 1,
} OuroRenderFrameDisposition;

typedef enum OuroRenderRowSemantic {
    OURO_RENDER_ROW_SEMANTIC_NONE = 0,
    OURO_RENDER_ROW_SEMANTIC_PROMPT = 1,
    OURO_RENDER_ROW_SEMANTIC_PROMPT_CONTINUATION = 2,
} OuroRenderRowSemantic;

typedef enum OuroRenderCellSemantic {
    OURO_RENDER_CELL_SEMANTIC_OUTPUT = 0,
    OURO_RENDER_CELL_SEMANTIC_INPUT = 1,
    OURO_RENDER_CELL_SEMANTIC_PROMPT = 2,
} OuroRenderCellSemantic;

typedef struct OuroRenderFrameInfo {
    size_t size;
    uint32_t abi_version;
    uint64_t generation;
    OuroTerminalDirty dirty;
    uint16_t columns;
    uint16_t rows;
    bool cursor_has_value;
    uint16_t cursor_x;
    uint16_t cursor_y;
    bool cursor_wide_tail;
    bool cursor_visible;
    bool cursor_blinking;
    bool cursor_password_input;
    OuroRenderCursorStyle cursor_style;
    OuroRenderRgb background;
    OuroRenderRgb foreground;
    bool cursor_color_has_value;
    OuroRenderRgb cursor_color;
    OuroRenderRgb palette[256];
} OuroRenderFrameInfo;

typedef struct OuroRenderRowInfo {
    size_t size;
    uint32_t abi_version;
    uint16_t y;
    bool dirty;
    bool selection_has_value;
    uint16_t selection_start_x;
    uint16_t selection_end_x;
    bool wrap;
    bool wrap_continuation;
    OuroRenderRowSemantic semantic;
} OuroRenderRowInfo;

typedef struct OuroRenderCellInfo {
    size_t size;
    uint32_t abi_version;
    uint16_t x;
    uint8_t width;
    size_t grapheme_bytes;
    bool selected;
    bool has_styling;
    bool has_hyperlink;
    OuroRenderCellSemantic semantic;
    bool foreground_has_value;
    OuroRenderColor foreground;
    bool background_has_value;
    OuroRenderColor background;
    bool underline_color_has_value;
    OuroRenderColor underline_color;
    bool bold;
    bool italic;
    bool faint;
    bool blink;
    bool inverse;
    bool invisible;
    bool strikethrough;
    bool overline;
    int32_t underline;
} OuroRenderCellInfo;

/* Creates one opaque budget that can be shared by many terminals. */
OuroTerminalResult ouro_terminal_page_budget_new(
    size_t limit_bytes,
    OuroTerminalPageBudget **out_budget);

void ouro_terminal_page_budget_free(OuroTerminalPageBudget *budget);

OuroTerminalResult ouro_terminal_page_budget_stats(
    OuroTerminalPageBudget *budget,
    OuroTerminalPageBudgetStats *out_stats);

/* Initializes a bounded, threadless terminal-state engine. */
OuroTerminalResult ouro_terminal_new(
    const OuroTerminalConfig *config,
    OuroTerminal **out_terminal);

/* Initializes a terminal using a borrowed shared page-mapping budget. */
OuroTerminalResult ouro_terminal_new_with_page_budget(
    const OuroTerminalConfig *config,
    OuroTerminalPageBudget *page_budget,
    OuroTerminal **out_terminal);

void ouro_terminal_free(OuroTerminal *terminal);

/*
 * Feeds bytes read from a PTY. Callers serialize mutation of one terminal.
 * The pinned upstream write API cannot return an allocation error, so the
 * adapter compares allocator-failure counters around the call. An OOM result
 * means the engine state may contain an arbitrary prefix of this input. The
 * caller must discard/resynchronize this state from its last checkpoint and
 * ordered event tail; retrying the same bytes on this handle is unsafe.
 * Zero-length input is a successful no-op.
 */
OuroTerminalResult ouro_terminal_feed(
    OuroTerminal *terminal,
    const uint8_t *bytes,
    size_t length);

/*
 * Copies terminal-generated query responses collected during the most recent
 * feed and clears them only after a successful copy. The caller writes these
 * bytes back to the PTY; replay-only restores must drain and discard them.
 */
OuroTerminalResult ouro_terminal_take_pty_responses(
    OuroTerminal *terminal,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length);

/*
 * Returns and clears the bounded bell count accumulated by the most recent
 * feed batches. Saturation is reported as UINT32_MAX rather than wrapping.
 */
OuroTerminalResult ouro_terminal_take_bells(
    OuroTerminal *terminal,
    uint32_t *out_count);

/*
 * Bounded two-pass OSC 8 lookup at a visible viewport cell. NULL + zero
 * capacity queries the URI length. NO_VALUE means the point has no hyperlink.
 */
OuroTerminalResult ouro_terminal_hyperlink_uri_at_viewport(
    OuroTerminal *terminal,
    uint16_t column,
    uint32_t row,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length);

/* Bounded two-pass copies of metadata emitted by the shell. The returned
 * bytes are transient snapshots of Ghostty's retained title/PWD strings and
 * are never retained by the adapter. NULL + zero capacity queries length. */
OuroTerminalResult ouro_terminal_copy_title(
    OuroTerminal *terminal,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length);
OuroTerminalResult ouro_terminal_copy_pwd(
    OuroTerminal *terminal,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length);
OuroTerminalResult ouro_terminal_metadata_epoch(
    OuroTerminal *terminal,
    uint64_t *out_epoch);

OuroTerminalResult ouro_terminal_resize(
    OuroTerminal *terminal,
    uint16_t columns,
    uint16_t rows,
    uint32_t cell_width_px,
    uint32_t cell_height_px);

/*
 * Moves the viewport without mutating terminal contents or snapshot format.
 * TOP/BOTTOM require delta=row=0, DELTA requires row=0, and ROW requires
 * delta=0. Requests that cannot fit the exact-pin platform integer width are
 * rejected instead of being truncated.
 */
OuroTerminalResult ouro_terminal_scroll_viewport(
    OuroTerminal *terminal,
    const OuroTerminalScrollViewport *viewport);

/* Poll after a write batch or once per frame; no change callback is retained. */
OuroTerminalResult ouro_terminal_scrollbar(
    OuroTerminal *terminal,
    OuroTerminalScrollbar *out_scrollbar);

/*
 * Creates persistent input encoder state borrowed from `terminal`. The
 * terminal must outlive this context. Calls using either handle are serialized
 * by the owner. Output always goes to caller-owned bounded memory; on
 * BUFFER_TOO_SMALL, `out_length` is the exact required size and encoder retry
 * state is unchanged.
 */
OuroTerminalResult ouro_terminal_input_new(
    OuroTerminal *terminal,
    const OuroTerminalInputConfig *config,
    OuroTerminalInput **out_input);

void ouro_terminal_input_free(OuroTerminalInput *input);

OuroTerminalResult ouro_terminal_input_encode_key(
    OuroTerminalInput *input,
    const OuroTerminalKeyEvent *event,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length);

/* Copies committed IME text verbatim after UTF-8 validation and KAM checks. */
OuroTerminalResult ouro_terminal_input_encode_committed_text(
    OuroTerminalInput *input,
    const uint8_t *utf8,
    size_t utf8_length,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length);

OuroTerminalResult ouro_terminal_input_set_mouse_geometry(
    OuroTerminalInput *input,
    const OuroTerminalMouseGeometry *geometry);

/* Route probe: true means pointer events normally belong to the PTY. */
OuroTerminalResult ouro_terminal_input_mouse_reporting(
    OuroTerminalInput *input,
    bool *out_enabled);

OuroTerminalResult ouro_terminal_input_encode_mouse(
    OuroTerminalInput *input,
    const OuroTerminalMouseEvent *event,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length);

/* One call represents one discrete wheel tick. */
OuroTerminalResult ouro_terminal_input_encode_scroll(
    OuroTerminalInput *input,
    const OuroTerminalScrollEvent *event,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length);

/* Clears only mouse motion-deduplication and pressed-button state. */
OuroTerminalResult ouro_terminal_input_reset_mouse(OuroTerminalInput *input);

OuroTerminalResult ouro_terminal_input_paste_is_safe(
    OuroTerminalInput *input,
    const uint8_t *source,
    size_t source_length,
    bool *out_safe);

/*
 * The source remains byte-identical: the adapter copies it before calling the
 * pinned public Ghostty API, whose input parameter is intentionally mutable.
 */
OuroTerminalResult ouro_terminal_input_encode_paste(
    OuroTerminalInput *input,
    const uint8_t *source,
    size_t source_length,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length);

OuroTerminalResult ouro_terminal_input_encode_focus(
    OuroTerminalInput *input,
    bool focused,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length);

/*
 * Creates a persistent public-Ghostty selection gesture context. The terminal
 * must outlive the context. Snapshot selections never escape this boundary;
 * each produced snapshot is immediately installed as terminal-owned state.
 */
OuroTerminalResult ouro_terminal_selection_new(
    OuroTerminal *terminal,
    const OuroTerminalSelectionConfig *config,
    OuroTerminalSelection **out_selection);

void ouro_terminal_selection_free(OuroTerminalSelection *selection);

OuroTerminalResult ouro_terminal_selection_begin(
    OuroTerminalSelection *selection,
    const OuroTerminalSelectionPoint *point);

OuroTerminalResult ouro_terminal_selection_update(
    OuroTerminalSelection *selection,
    const OuroTerminalSelectionPoint *point,
    const OuroTerminalSelectionGeometry *geometry,
    bool rectangle);

OuroTerminalResult ouro_terminal_selection_autoscroll(
    OuroTerminalSelection *selection,
    uint16_t viewport_column,
    uint32_t viewport_row,
    double surface_x,
    double surface_y,
    const OuroTerminalSelectionGeometry *geometry,
    bool rectangle,
    OuroTerminalSelectionAutoscroll *out_direction);

OuroTerminalResult ouro_terminal_selection_end(
    OuroTerminalSelection *selection,
    const OuroTerminalSelectionPoint *point);

OuroTerminalResult ouro_terminal_selection_cancel(
    OuroTerminalSelection *selection);

/* NO_VALUE means there is no active selection; this is not an error. */
OuroTerminalResult ouro_terminal_selection_copy(
    OuroTerminalSelection *selection,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length);

/*
 * Diagnostic/test-only compatibility helper. It creates and destroys an
 * ephemeral render state for this call; production renderers should retain an
 * OuroRenderProjection instead. This helper does not make headless terminals
 * carry persistent render allocation.
 */
OuroTerminalResult ouro_terminal_frame_info(
    OuroTerminal *terminal,
    OuroTerminalFrameInfo *out_info);

/* Installs or clears a viewport-coordinate selection for render projection. */
OuroTerminalResult ouro_terminal_set_selection(
    OuroTerminal *terminal,
    uint16_t start_x,
    uint16_t start_y,
    uint16_t end_x,
    uint16_t end_y,
    bool rectangle);

OuroTerminalResult ouro_terminal_clear_selection(OuroTerminal *terminal);

/*
 * Lazily allocates detached render projection state for a terminal.
 *
 * The borrowed terminal must outlive the projection. Calls that mutate that
 * terminal and all calls using its projection must be serialized by the
 * owner; neither handle supports concurrent use. At most one frame may be
 * outstanding for a projection.
 */
OuroTerminalResult ouro_render_projection_new(
    OuroTerminal *terminal,
    const OuroRenderProjectionConfig *config,
    OuroRenderProjection **out_projection);

/*
 * Rebinds an idle projection to a replacement terminal while preserving the
 * outer projection identity and monotonic frame generation. Both terminals
 * must remain alive for this call. On failure the projection remains bound to
 * the old terminal and the caller retains the candidate unchanged. On
 * success the old terminal is no longer borrowed and may be destroyed.
 * The first frame from the replacement is always fully dirty.
 */
OuroTerminalResult ouro_render_projection_rebind(
    OuroRenderProjection *projection,
    OuroTerminal *terminal);

OuroTerminalResult ouro_render_projection_memory_info(
    OuroRenderProjection *projection,
    OuroRenderProjectionMemoryInfo *out_info);

void ouro_render_projection_free(OuroRenderProjection *projection);

OuroTerminalResult ouro_render_projection_begin(
    OuroRenderProjection *projection,
    OuroRenderFrame **out_frame);

OuroTerminalResult ouro_render_projection_force_full(
    OuroRenderProjection *projection);

OuroTerminalResult ouro_render_frame_info(
    OuroRenderFrame *frame,
    OuroRenderFrameInfo *out_info);

OuroTerminalResult ouro_render_frame_next_row(
    OuroRenderFrame *frame,
    OuroRenderRowInfo *out_row,
    bool *out_has_row);

OuroTerminalResult ouro_render_frame_next_cell(
    OuroRenderFrame *frame,
    uint8_t *grapheme_buffer,
    size_t grapheme_capacity,
    OuroRenderCellInfo *out_cell,
    bool *out_has_cell);

/*
 * COMMITTED clears engine dirty state only after the caller has drained every
 * row/cell and merged them into its lossless full CPU row cache. A later GPU
 * submission failure is retried from that cache and must not be reported as a
 * DROPPED engine frame. DROPPED retains a full invalidation.
 */
OuroTerminalResult ouro_render_frame_end(
    OuroRenderFrame *frame,
    OuroRenderFrameDisposition disposition);

/* Returns GhosttyAllocator-mediated requested-byte budget and current usage. */
OuroTerminalResult ouro_terminal_memory_info(
    OuroTerminal *terminal,
    OuroTerminalMemoryInfo *out_info);

/*
 * Returns an opaque compression-relevant activity token. Only equality is
 * meaningful. A scheduler restarts its idle delay whenever this value changes.
 */
OuroTerminalResult ouro_terminal_compression_activity(
    OuroTerminal *terminal,
    uint64_t *out_activity);

/*
 * Performs one bounded incremental compression step. Call again while the
 * typed result is PENDING, but only while the session remains idle and the
 * activity token has not changed. Callers serialize this with every other
 * operation on the terminal.
 */
OuroTerminalResult ouro_terminal_compress_incremental(
    OuroTerminal *terminal,
    OuroTerminalCompressionResult *out_result);

/*
 * Synchronously scans all currently eligible history. This is exposed only
 * for conformance tests and benchmarks; it is forbidden on the product hot
 * path because large histories can stall the terminal owner.
 */
OuroTerminalResult ouro_terminal_compress_full_for_testing(
    OuroTerminal *terminal,
    OuroTerminalCompressionResult *out_result);

/*
 * Copies a plain-text diagnostic projection into caller-owned memory.
 * This is deliberately not the production renderer or persistence format.
 */
OuroTerminalResult ouro_terminal_copy_plain_text(
    OuroTerminal *terminal,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length);

/*
 * Exports a complete, CRC-protected terminal snapshot. Passing NULL with a
 * zero capacity queries the required size. The configured snapshot_max_bytes
 * is enforced for both queries and copies before caller memory is touched.
 */
OuroTerminalResult ouro_terminal_copy_snapshot(
    OuroTerminal *terminal,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length);

/*
 * Restores a new terminal from borrowed snapshot bytes. The bytes are borrowed
 * only for this synchronous call. Runtime resource bounds come from config,
 * not from the untrusted snapshot, and are reapplied before success returns.
 */
OuroTerminalResult ouro_terminal_restore(
    const OuroTerminalConfig *config,
    const uint8_t *bytes,
    size_t length,
    OuroTerminal **out_terminal);

/* Restores a terminal into the same shared page-mapping budget. */
OuroTerminalResult ouro_terminal_restore_with_page_budget(
    const OuroTerminalConfig *config,
    OuroTerminalPageBudget *page_budget,
    const uint8_t *bytes,
    size_t length,
    OuroTerminal **out_terminal);

#ifdef __cplusplus
}
#endif

#endif
