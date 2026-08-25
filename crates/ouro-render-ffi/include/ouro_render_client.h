#ifndef OURO_RENDER_CLIENT_H
#define OURO_RENDER_CLIENT_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

#define OURO_RENDER_CLIENT_ABI_VERSION 1u
#define OURO_RENDER_TERMINAL_ID_MAX_BYTES 128u
#define OURO_RENDER_PALETTE_COLORS 256u
#define OURO_RENDER_SELECTION_COPY_MAX_BYTES (1024u * 1024u)

typedef struct OuroRenderClient OuroRenderClient;
typedef enum OuroRenderClientResult {
    OURO_RENDER_CLIENT_OK = 0,
    OURO_RENDER_CLIENT_INVALID_ARGUMENT = 1,
    OURO_RENDER_CLIENT_OUT_OF_MEMORY = 2,
    OURO_RENDER_CLIENT_ENGINE_ERROR = 3,
    OURO_RENDER_CLIENT_BUFFER_TOO_SMALL = 4,
    OURO_RENDER_CLIENT_STATE_SEQ_GAP = 5,
    OURO_RENDER_CLIENT_BUSY = 6,
    OURO_RENDER_CLIENT_LIMIT_EXCEEDED = 7,
    OURO_RENDER_CLIENT_NO_CANDIDATE = 8,
    OURO_RENDER_CLIENT_STALE_FRAME = 9,
    OURO_RENDER_CLIENT_STALE_CANDIDATE = 10,
    OURO_RENDER_CLIENT_STALE_STREAM = 11,
    OURO_RENDER_CLIENT_MANIFEST_MISMATCH = 12,
    OURO_RENDER_CLIENT_RESYNC_REQUIRED = 13,
    OURO_RENDER_CLIENT_NO_VALUE = 14,
} OuroRenderClientResult;
typedef enum OuroRenderClientLeaseDisposition {
    OURO_RENDER_CLIENT_FRAME_CONSUMED = 0,
    OURO_RENDER_CLIENT_FRAME_RETRY = 1,
} OuroRenderClientLeaseDisposition;

typedef struct OuroRenderStreamIdentity {
    size_t size;
    uint32_t abi_version;
    uint64_t broker_generation;
    size_t terminal_id_length;
    uint8_t terminal_id[OURO_RENDER_TERMINAL_ID_MAX_BYTES];
} OuroRenderStreamIdentity;

/* Exact compile-time compatibility contract. Strings are NUL-terminated. */
typedef struct OuroRenderClientManifest {
    size_t size;
    uint32_t abi_version;
    uint32_t terminal_engine_abi_version;
    uint32_t snapshot_format_version;
    char ghostty_source_commit[41];
    char snapshot_magic[9];
    char unicode_width_policy[32];
    char graphics_policy[48];
} OuroRenderClientManifest;

typedef struct OuroRenderClientConfig {
    size_t size;
    uint32_t abi_version;
    OuroRenderStreamIdentity initial_stream;
    uint16_t columns;
    uint16_t rows;
    uint32_t cell_width_px;
    uint32_t cell_height_px;
    size_t scrollback_max_bytes;
    size_t scrollback_max_lines;
    size_t snapshot_max_bytes;
    size_t engine_memory_max_bytes;
    size_t projection_memory_max_bytes;
    size_t shared_page_budget_max_bytes;
    size_t max_grapheme_bytes;
    size_t max_feed_bytes;
    size_t cpu_cache_max_bytes;
    uint64_t initial_state_seq;
} OuroRenderClientConfig;

typedef struct OuroRenderClientRgb {
    uint8_t r;
    uint8_t g;
    uint8_t b;
} OuroRenderClientRgb;
typedef struct OuroRenderClientColor {
    uint32_t kind;
    uint8_t palette_index;
    OuroRenderClientRgb rgb;
} OuroRenderClientColor;

typedef struct OuroRenderClientRow {
    uint16_t y;
    size_t first_cell_index;
    size_t cell_count;
    uint8_t dirty;
    uint8_t selection_has_value;
    uint16_t selection_start_x;
    uint16_t selection_end_x;
    uint8_t wrap;
    uint8_t wrap_continuation;
    uint32_t semantic;
} OuroRenderClientRow;

/* Row damage is separate from the lossless, full CPU framebuffer payload.
 * bulk_frame.dirty: 0=NONE, 1=PARTIAL, 2=FULL.
 * - NONE: every returned row has dirty=0.
 * - PARTIAL: exactly rows changed by this generation have dirty=1; unchanged
 *   rows are still copied from the retained cache with dirty=0.
 * - FULL (including a RETRY lease): every returned row has dirty=1 and must be
 *   redrawn. row_count/cells/graphemes still describe one complete frame. */

enum {
    OURO_RENDER_CLIENT_CELL_SELECTED = 1u << 0,
    OURO_RENDER_CLIENT_CELL_HAS_STYLING = 1u << 1,
    OURO_RENDER_CLIENT_CELL_HAS_HYPERLINK = 1u << 2,
    OURO_RENDER_CLIENT_CELL_BOLD = 1u << 3,
    OURO_RENDER_CLIENT_CELL_ITALIC = 1u << 4,
    OURO_RENDER_CLIENT_CELL_FAINT = 1u << 5,
    OURO_RENDER_CLIENT_CELL_BLINK = 1u << 6,
    OURO_RENDER_CLIENT_CELL_INVERSE = 1u << 7,
    OURO_RENDER_CLIENT_CELL_INVISIBLE = 1u << 8,
    OURO_RENDER_CLIENT_CELL_STRIKETHROUGH = 1u << 9,
    OURO_RENDER_CLIENT_CELL_OVERLINE = 1u << 10,
};
typedef enum OuroRenderClientUnderline {
    OURO_RENDER_CLIENT_UNDERLINE_NONE = 0,
    OURO_RENDER_CLIENT_UNDERLINE_SINGLE = 1,
    OURO_RENDER_CLIENT_UNDERLINE_DOUBLE = 2,
    OURO_RENDER_CLIENT_UNDERLINE_CURLY = 3,
    OURO_RENDER_CLIENT_UNDERLINE_DOTTED = 4,
    OURO_RENDER_CLIENT_UNDERLINE_DASHED = 5,
} OuroRenderClientUnderline;
typedef struct OuroRenderClientCell {
    uint16_t x;
    uint8_t width;
    size_t grapheme_offset;
    size_t grapheme_bytes;
    uint32_t flags;
    uint32_t semantic;
    OuroRenderClientColor foreground;
    OuroRenderClientColor background;
    OuroRenderClientColor underline_color;
    OuroRenderClientUnderline underline;
} OuroRenderClientCell;

typedef struct OuroRenderClientBulkFrame {
    size_t size;
    uint32_t abi_version;
    uint64_t state_seq;
    uint64_t generation;
    uint32_t dirty;
    uint16_t columns;
    uint16_t rows;
    size_t row_count;
    size_t cell_count;
    size_t grapheme_bytes;
    uint8_t cursor_has_value;
    uint16_t cursor_x;
    uint16_t cursor_y;
    uint8_t cursor_wide_tail;
    uint8_t cursor_visible;
    uint8_t cursor_blinking;
    uint8_t cursor_password_input;
    uint32_t cursor_style;
    OuroRenderClientRgb background;
    OuroRenderClientRgb foreground;
    uint8_t cursor_color_has_value;
    OuroRenderClientRgb cursor_color;
    OuroRenderClientRgb palette[OURO_RENDER_PALETTE_COLORS];
} OuroRenderClientBulkFrame;

typedef struct OuroRenderClientMemoryInfo {
    size_t size;
    uint32_t abi_version;
    size_t cpu_cache_live_bytes;
    size_t cpu_cache_peak_bytes;
    size_t cpu_cache_limit_bytes;
    size_t projection_live_bytes;
    size_t projection_peak_bytes;
    size_t projection_limit_bytes;
    uint64_t projection_allocation_failures;
    size_t active_engine_live_bytes;
    size_t active_engine_peak_bytes;
    size_t active_engine_limit_bytes;
    uint64_t active_engine_allocation_failures;
    uint8_t candidate_present;
    size_t candidate_engine_live_bytes;
    size_t candidate_engine_peak_bytes;
    size_t candidate_engine_limit_bytes;
    uint64_t candidate_engine_allocation_failures;
    size_t page_reserved_bytes;
    size_t page_peak_reserved_bytes;
    size_t page_limit_bytes;
    size_t page_denial_count;
    size_t page_child_failure_count;
    uint8_t active_terminal_count;
    uint8_t candidate_terminal_count;
    uint8_t projection_count;
} OuroRenderClientMemoryInfo;

/* Local projection mutations are scoped to the exact active stream. The
 * client must also have observed at least minimum_state_seq before applying
 * the effect. This prevents a delayed pointer receipt from mutating a stale
 * or not-yet-caught-up visible projection. */
typedef struct OuroRenderClientProjectionContext {
    size_t size;
    uint32_t abi_version;
    OuroRenderStreamIdentity stream;
    uint64_t minimum_state_seq;
} OuroRenderClientProjectionContext;

/* `row` is Ghostty's viewport/history row coordinate. Surface positions and
 * geometry are f64 so AppKit can preserve subpixel input through the bridge. */
typedef struct OuroRenderClientSelectionPoint {
    size_t size;
    uint32_t abi_version;
    uint16_t column;
    uint32_t row;
    double surface_x;
    double surface_y;
    uint8_t has_time;
    uint64_t time_ns;
} OuroRenderClientSelectionPoint;

typedef struct OuroRenderClientSelectionGeometry {
    size_t size;
    uint32_t abi_version;
    uint32_t columns;
    double cell_width;
    double padding_left;
    double screen_height;
} OuroRenderClientSelectionGeometry;

typedef enum OuroRenderClientSelectionAutoscroll {
    OURO_RENDER_CLIENT_SELECTION_AUTOSCROLL_NONE = 0,
    OURO_RENDER_CLIENT_SELECTION_AUTOSCROLL_UP = 1,
    OURO_RENDER_CLIENT_SELECTION_AUTOSCROLL_DOWN = 2,
} OuroRenderClientSelectionAutoscroll;

typedef struct OuroRenderClientSelectionOutcome {
    size_t size;
    uint32_t abi_version;
    uint64_t observed_state_seq;
    uint8_t selection_has_value;
    OuroRenderClientSelectionAutoscroll autoscroll_direction;
} OuroRenderClientSelectionOutcome;

typedef enum OuroRenderClientViewportScrollKind {
    OURO_RENDER_CLIENT_VIEWPORT_SCROLL_TOP = 0,
    OURO_RENDER_CLIENT_VIEWPORT_SCROLL_BOTTOM = 1,
    OURO_RENDER_CLIENT_VIEWPORT_SCROLL_DELTA = 2,
    OURO_RENDER_CLIENT_VIEWPORT_SCROLL_ROW = 3,
} OuroRenderClientViewportScrollKind;

/* Unused fields must be zero. DELTA is signed rows (negative is older
 * history); ROW is an absolute top-origin offset in scrollbar row space. */
typedef struct OuroRenderClientViewportScroll {
    size_t size;
    uint32_t abi_version;
    OuroRenderClientViewportScrollKind kind;
    int64_t delta;
    uint64_t row;
} OuroRenderClientViewportScroll;

typedef struct OuroRenderClientScrollbar {
    size_t size;
    uint32_t abi_version;
    uint64_t observed_state_seq;
    uint64_t total;
    uint64_t offset;
    uint64_t length;
} OuroRenderClientScrollbar;

/* The macOS static bridge is 64-bit. These gates make accidental C/Rust ABI
 * drift a compile error on both C11 and C++17 clients. */
#if UINTPTR_MAX == UINT64_MAX
#if defined(__cplusplus)
#define OURO_RENDER_STATIC_ASSERT(condition, message) static_assert(condition, message)
#else
#define OURO_RENDER_STATIC_ASSERT(condition, message) _Static_assert(condition, message)
#endif
OURO_RENDER_STATIC_ASSERT(sizeof(OuroRenderStreamIdentity) == 160, "stream identity layout");
OURO_RENDER_STATIC_ASSERT(offsetof(OuroRenderStreamIdentity, terminal_id) == 32, "stream terminal id offset");
OURO_RENDER_STATIC_ASSERT(sizeof(OuroRenderClientManifest) == 152, "manifest layout");
OURO_RENDER_STATIC_ASSERT(sizeof(OuroRenderClientConfig) == 272, "config layout");
OURO_RENDER_STATIC_ASSERT(offsetof(OuroRenderClientConfig, initial_stream) == 16, "config stream offset");
OURO_RENDER_STATIC_ASSERT(offsetof(OuroRenderClientConfig, initial_state_seq) == 264, "config seq offset");
OURO_RENDER_STATIC_ASSERT(sizeof(OuroRenderClientRow) == 40, "row layout");
OURO_RENDER_STATIC_ASSERT(offsetof(OuroRenderClientRow, first_cell_index) == 8, "row cell offset");
OURO_RENDER_STATIC_ASSERT(sizeof(OuroRenderClientCell) == 64, "cell layout");
OURO_RENDER_STATIC_ASSERT(sizeof(OuroRenderClientUnderline) == 4, "underline enum layout");
OURO_RENDER_STATIC_ASSERT(offsetof(OuroRenderClientCell, underline) == 56, "cell underline offset");
OURO_RENDER_STATIC_ASSERT(OURO_RENDER_CLIENT_UNDERLINE_NONE == 0, "underline none value");
OURO_RENDER_STATIC_ASSERT(OURO_RENDER_CLIENT_UNDERLINE_SINGLE == 1, "underline single value");
OURO_RENDER_STATIC_ASSERT(OURO_RENDER_CLIENT_UNDERLINE_DOUBLE == 2, "underline double value");
OURO_RENDER_STATIC_ASSERT(OURO_RENDER_CLIENT_UNDERLINE_CURLY == 3, "underline curly value");
OURO_RENDER_STATIC_ASSERT(OURO_RENDER_CLIENT_UNDERLINE_DOTTED == 4, "underline dotted value");
OURO_RENDER_STATIC_ASSERT(OURO_RENDER_CLIENT_UNDERLINE_DASHED == 5, "underline dashed value");
OURO_RENDER_STATIC_ASSERT(offsetof(OuroRenderClientCell, grapheme_offset) == 8, "cell grapheme offset");
OURO_RENDER_STATIC_ASSERT(offsetof(OuroRenderClientCell, foreground) == 32, "cell color offset");
OURO_RENDER_STATIC_ASSERT(sizeof(OuroRenderClientBulkFrame) == 864, "bulk frame layout");
OURO_RENDER_STATIC_ASSERT(offsetof(OuroRenderClientBulkFrame, palette) == 90, "palette offset");
OURO_RENDER_STATIC_ASSERT(sizeof(OuroRenderClientMemoryInfo) == 192, "memory info layout");
OURO_RENDER_STATIC_ASSERT(offsetof(OuroRenderClientMemoryInfo, page_reserved_bytes) == 144, "page telemetry offset");
OURO_RENDER_STATIC_ASSERT(sizeof(OuroRenderClientProjectionContext) == 184, "projection context layout");
OURO_RENDER_STATIC_ASSERT(offsetof(OuroRenderClientProjectionContext, stream) == 16, "projection context stream offset");
OURO_RENDER_STATIC_ASSERT(offsetof(OuroRenderClientProjectionContext, minimum_state_seq) == 176, "projection context seq offset");
OURO_RENDER_STATIC_ASSERT(sizeof(OuroRenderClientSelectionPoint) == 56, "selection point layout");
OURO_RENDER_STATIC_ASSERT(offsetof(OuroRenderClientSelectionPoint, row) == 16, "selection point row offset");
OURO_RENDER_STATIC_ASSERT(offsetof(OuroRenderClientSelectionPoint, time_ns) == 48, "selection point time offset");
OURO_RENDER_STATIC_ASSERT(sizeof(OuroRenderClientSelectionGeometry) == 40, "selection geometry layout");
OURO_RENDER_STATIC_ASSERT(offsetof(OuroRenderClientSelectionGeometry, cell_width) == 16, "selection geometry width offset");
OURO_RENDER_STATIC_ASSERT(sizeof(OuroRenderClientSelectionOutcome) == 32, "selection outcome layout");
OURO_RENDER_STATIC_ASSERT(offsetof(OuroRenderClientSelectionOutcome, observed_state_seq) == 16, "selection outcome seq offset");
OURO_RENDER_STATIC_ASSERT(offsetof(OuroRenderClientSelectionOutcome, autoscroll_direction) == 28, "selection outcome direction offset");
OURO_RENDER_STATIC_ASSERT(sizeof(OuroRenderClientSelectionAutoscroll) == 4, "selection autoscroll enum layout");
OURO_RENDER_STATIC_ASSERT(sizeof(OuroRenderClientViewportScroll) == 32, "viewport scroll layout");
OURO_RENDER_STATIC_ASSERT(offsetof(OuroRenderClientViewportScroll, delta) == 16, "viewport scroll delta offset");
OURO_RENDER_STATIC_ASSERT(sizeof(OuroRenderClientViewportScrollKind) == 4, "viewport scroll enum layout");
OURO_RENDER_STATIC_ASSERT(sizeof(OuroRenderClientScrollbar) == 48, "scrollbar layout");
OURO_RENDER_STATIC_ASSERT(offsetof(OuroRenderClientScrollbar, observed_state_seq) == 16, "scrollbar seq offset");
OURO_RENDER_STATIC_ASSERT(offsetof(OuroRenderClientScrollbar, length) == 40, "scrollbar length offset");
#undef OURO_RENDER_STATIC_ASSERT
#endif

OuroRenderClientResult ouro_render_client_manifest(
    OuroRenderClientManifest *out_manifest);
OuroRenderClientResult ouro_render_client_manifest_matches(
    const OuroRenderClientManifest *manifest);
OuroRenderClientResult ouro_render_client_new(
    const OuroRenderClientConfig *config,
    OuroRenderClient **out_client);
void ouro_render_client_free(OuroRenderClient *client);
OuroRenderClientResult ouro_render_client_memory_info(
    OuroRenderClient *client,
    OuroRenderClientMemoryInfo *out_info);

OuroRenderClientResult ouro_render_client_active_feed(
    OuroRenderClient *client,
    const OuroRenderStreamIdentity *stream,
    uint64_t state_seq,
    const uint8_t *bytes,
    size_t length);
/* A terminal feed error may follow prefix consumption. After such an error,
 * active calls and frame acquisition return RESYNC_REQUIRED until a complete
 * recovery candidate is committed. The failed state_seq is never accepted. */
OuroRenderClientResult ouro_render_client_active_resize(
    OuroRenderClient *client,
    const OuroRenderStreamIdentity *stream,
    uint64_t state_seq,
    uint16_t columns,
    uint16_t rows,
    uint32_t cell_width_px,
    uint32_t cell_height_px);

OuroRenderClientResult ouro_render_client_candidate_begin(
    OuroRenderClient *client,
    const OuroRenderStreamIdentity *target_stream,
    uint64_t checkpoint_state_seq,
    uint64_t *out_candidate_token);
OuroRenderClientResult ouro_render_client_candidate_import_checkpoint(
    OuroRenderClient *client,
    uint64_t candidate_token,
    const OuroRenderClientManifest *manifest,
    uint64_t checkpoint_state_seq,
    const uint8_t *checkpoint,
    size_t length);
OuroRenderClientResult ouro_render_client_candidate_feed(
    OuroRenderClient *client,
    uint64_t candidate_token,
    uint64_t state_seq,
    const uint8_t *bytes,
    size_t length);
/* A candidate feed error discards the prefix-mutated terminal. That candidate
 * returns RESYNC_REQUIRED for feed/resize/commit and must be aborted before a
 * fresh checkpoint recovery can begin. */
OuroRenderClientResult ouro_render_client_candidate_resize(
    OuroRenderClient *client,
    uint64_t candidate_token,
    uint64_t state_seq,
    uint16_t columns,
    uint16_t rows,
    uint32_t cell_width_px,
    uint32_t cell_height_px);
OuroRenderClientResult ouro_render_client_candidate_commit(
    OuroRenderClient *client,
    uint64_t candidate_token,
    uint64_t attached_ready_state_seq);
OuroRenderClientResult ouro_render_client_candidate_abort(
    OuroRenderClient *client,
    uint64_t candidate_token);

OuroRenderClientResult ouro_render_client_acquire_frame(
    OuroRenderClient *client,
    OuroRenderClientBulkFrame *out_frame);
/* All capacities are element counts except grapheme_capacity, which is bytes.
 * A too-small call writes required counts to frame and copies no payload. */
OuroRenderClientResult ouro_render_client_copy_frame_bulk(
    OuroRenderClient *client,
    uint64_t generation,
    OuroRenderClientRow *rows,
    size_t row_capacity,
    OuroRenderClientCell *cells,
    size_t cell_capacity,
    uint8_t *graphemes,
    size_t grapheme_capacity,
    OuroRenderClientBulkFrame *out_frame);
OuroRenderClientResult ouro_render_client_finish_frame_lease(
    OuroRenderClient *client,
    uint64_t generation,
    OuroRenderClientLeaseDisposition disposition);
/* RETRY pins the exact CPU frame bytes and generation until reacquisition.
 * Active feed/resize and candidate preparation may continue, but candidate
 * commit is BUSY so terminal rebind cannot invalidate the retry payload. */
/* Explicitly abandons a RETRY obligation after the old presentation has been
 * superseded by a terminal transition. An outstanding lease remains BUSY. */
OuroRenderClientResult ouro_render_client_cancel_frame_retry(
    OuroRenderClient *client);
OuroRenderClientResult ouro_render_client_force_full_frame(
    OuroRenderClient *client);

/* Selection mutation targets only the active projection and returns BUSY
 * while a frame lease is outstanding. Every successful mutation, including a
 * no-value gesture transition, forces the next frame to be FULL. The nullable
 * point on `end` is the only nullable mutation input. */
OuroRenderClientResult ouro_render_client_active_selection_begin(
    OuroRenderClient *client,
    const OuroRenderClientProjectionContext *context,
    const OuroRenderClientSelectionPoint *point,
    OuroRenderClientSelectionOutcome *out_outcome);
OuroRenderClientResult ouro_render_client_active_selection_update(
    OuroRenderClient *client,
    const OuroRenderClientProjectionContext *context,
    const OuroRenderClientSelectionPoint *point,
    const OuroRenderClientSelectionGeometry *geometry,
    uint8_t rectangle,
    OuroRenderClientSelectionOutcome *out_outcome);
OuroRenderClientResult ouro_render_client_active_selection_autoscroll(
    OuroRenderClient *client,
    const OuroRenderClientProjectionContext *context,
    uint16_t viewport_column,
    uint32_t viewport_row,
    double surface_x,
    double surface_y,
    const OuroRenderClientSelectionGeometry *geometry,
    uint8_t rectangle,
    OuroRenderClientSelectionOutcome *out_outcome);
OuroRenderClientResult ouro_render_client_active_selection_end(
    OuroRenderClient *client,
    const OuroRenderClientProjectionContext *context,
    const OuroRenderClientSelectionPoint *point,
    OuroRenderClientSelectionOutcome *out_outcome);
OuroRenderClientResult ouro_render_client_active_selection_cancel(
    OuroRenderClient *client,
    const OuroRenderClientProjectionContext *context,
    OuroRenderClientSelectionOutcome *out_outcome);

/* Bounded two-pass copy. NULL + zero capacity is the required-length query.
 * BUFFER_TOO_SMALL writes the exact required length. NO_VALUE means there is
 * no active selection; LIMIT_EXCEEDED means it exceeds the fixed 1 MiB cap.
 * Copy is read-only and does not force a frame. */
OuroRenderClientResult ouro_render_client_active_selection_copy(
    OuroRenderClient *client,
    const OuroRenderClientProjectionContext *context,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length);

/* Bounded on-demand full scrollback text export for Find. The returned bytes
 * are transient and are never retained in the renderer cache. */
OuroRenderClientResult ouro_render_client_active_copy_plain_text(
    OuroRenderClient *client,
    const OuroRenderClientProjectionContext *context,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length);

/* Bounded two-pass copies of shell-owned title/PWD metadata from the active
 * projection. kind=1 is title, kind=2 is current working directory. */
OuroRenderClientResult ouro_render_client_active_copy_metadata(
    OuroRenderClient *client,
    const OuroRenderClientProjectionContext *context,
    uint8_t kind,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length);
OuroRenderClientResult ouro_render_client_active_metadata_epoch(
    OuroRenderClient *client,
    const OuroRenderClientProjectionContext *context,
    uint64_t *out_epoch);

/* Bounded on-demand OSC 8 lookup at a visible viewport cell. The URI is
 * never retained in the renderer cache. NULL + zero capacity queries the
 * length; NO_VALUE means no hyperlink is present. */
OuroRenderClientResult ouro_render_client_active_hyperlink_uri(
    OuroRenderClient *client,
    const OuroRenderClientProjectionContext *context,
    uint16_t column,
    uint32_t row,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length);

/* Returns and clears terminal bells observed since the previous call. */
OuroRenderClientResult ouro_render_client_active_take_bells(
    OuroRenderClient *client,
    const OuroRenderClientProjectionContext *context,
    uint32_t *out_count);

/* Scroll mutates only the active local projection, is BUSY during a frame
 * lease, and forces the next frame FULL. Scrollbar is a read-only, lease-safe
 * query with offset + length <= total. */
OuroRenderClientResult ouro_render_client_active_viewport_scroll(
    OuroRenderClient *client,
    const OuroRenderClientProjectionContext *context,
    const OuroRenderClientViewportScroll *request);
OuroRenderClientResult ouro_render_client_active_scrollbar(
    OuroRenderClient *client,
    const OuroRenderClientProjectionContext *context,
    OuroRenderClientScrollbar *out_scrollbar);

/* Input encoding remains in the broker-owned normalized-input lane. */
#ifdef __cplusplus
}
#endif
#endif
