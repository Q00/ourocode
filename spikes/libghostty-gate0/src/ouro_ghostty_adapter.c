#include "ouro_terminal_engine.h"

#include <ghostty/vt.h>

#include <float.h>
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#include <malloc/malloc.h>
#endif

typedef struct OuroMemoryBudget {
    size_t live_bytes;
    size_t peak_bytes;
    size_t limit_bytes;
    size_t physical_usable_bytes;
    size_t physical_peak_usable_bytes;
    uint64_t allocation_failures;
} OuroMemoryBudget;

struct OuroTerminal {
    GhosttyTerminal terminal;
    OuroTerminalConfig config;
    OuroMemoryBudget memory;
    GhosttyAllocator allocator;
    uint8_t pty_responses[65536];
    size_t pty_response_length;
    bool pty_response_overflow;
    uint32_t pending_bell_count;
    uint64_t metadata_epoch;
};

struct OuroTerminalPageBudget {
    GhosttyPageBudget budget;
};

typedef struct OuroRenderResources {
    GhosttyRenderState state;
    GhosttyRenderStateRowIterator rows;
    GhosttyRenderStateRowCells cells;
} OuroRenderResources;

struct OuroRenderProjection {
    OuroTerminal *terminal;
    OuroRenderProjectionConfig config;
    OuroMemoryBudget memory;
    GhosttyAllocator allocator;
    OuroRenderResources *resources;
    OuroRenderFrame *active_frame;
    uint64_t generation;
};

struct OuroRenderFrame {
    OuroRenderProjection *projection;
    bool fully_drained;
    bool row_active;
    bool row_drained;
    bool rows_exhausted;
    bool cell_ready;
    uint16_t row_y;
    uint16_t cell_x;
};

struct OuroTerminalInput {
    OuroTerminal *terminal;
    OuroTerminalInputConfig config;
    GhosttyKeyEncoder key_encoder;
    GhosttyKeyEvent key_event;
    GhosttyMouseEncoder mouse_encoder;
    GhosttyMouseEvent mouse_event;
    GhosttyMouseEncoderSize mouse_geometry;
    bool mouse_geometry_valid;
    bool mouse_modes_valid;
    uint16_t mouse_mode_mask;
    uint16_t pressed_buttons;
    GhosttyMouseEncoder gesture_mouse_encoders[11];
};

struct OuroTerminalSelection {
    OuroTerminal *terminal;
    OuroTerminalSelectionConfig config;
    GhosttySelectionGesture gesture;
    GhosttySelectionGestureEvent press;
    GhosttySelectionGestureEvent drag;
    GhosttySelectionGestureEvent autoscroll;
    GhosttySelectionGestureEvent release;
};

static bool valid_alignment(uint8_t alignment);
static bool pointer_meets_alignment(const void *memory, uint8_t alignment);

static void collect_pty_response(
    GhosttyTerminal terminal,
    void *userdata,
    const uint8_t *data,
    size_t length) {
    (void)terminal;
    OuroTerminal *adapter = userdata;
    if (adapter == NULL || (data == NULL && length != 0) ||
        length > sizeof(adapter->pty_responses) - adapter->pty_response_length) {
        if (adapter != NULL) adapter->pty_response_overflow = true;
        return;
    }
    if (length != 0) {
        memcpy(
            adapter->pty_responses + adapter->pty_response_length,
            data,
            length);
        adapter->pty_response_length += length;
    }
}

static void collect_bell(GhosttyTerminal terminal, void *userdata) {
    (void)terminal;
    OuroTerminal *adapter = userdata;
    if (adapter != NULL && adapter->pending_bell_count != UINT32_MAX) {
        adapter->pending_bell_count++;
    }
}

static void collect_metadata_change(GhosttyTerminal terminal, void *userdata) {
    (void)terminal;
    OuroTerminal *adapter = userdata;
    if (adapter != NULL && adapter->metadata_epoch != UINT64_MAX) {
        adapter->metadata_epoch++;
    }
}

static GhosttyResult install_terminal_effects(OuroTerminal *adapter) {
    GhosttyResult result = ghostty_terminal_set(
        adapter->terminal,
        GHOSTTY_TERMINAL_OPT_USERDATA,
        adapter);
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_terminal_set(
            adapter->terminal,
            GHOSTTY_TERMINAL_OPT_WRITE_PTY,
            (const void *)collect_pty_response);
    }
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_terminal_set(
            adapter->terminal,
            GHOSTTY_TERMINAL_OPT_BELL,
            (const void *)collect_bell);
    }
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_terminal_set(
            adapter->terminal,
            GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,
            (const void *)collect_metadata_change);
    }
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_terminal_set(
            adapter->terminal,
            GHOSTTY_TERMINAL_OPT_PWD_CHANGED,
            (const void *)collect_metadata_change);
    }
    return result;
}

/*
 * PageBudget retains its owner allocator after this wrapper is released, so
 * its allocator context must have static lifetime. The native page allocator
 * remains the upstream child allocator and is the memory being budgeted.
 */
static void *system_alloc(
    void *ctx,
    size_t len,
    uint8_t alignment,
    uintptr_t ret_addr) {
    (void)ctx;
    (void)ret_addr;
    if (!valid_alignment(alignment)) return NULL;
    void *memory = malloc(len == 0 ? 1 : len);
    if (memory != NULL && !pointer_meets_alignment(memory, alignment)) {
        free(memory);
        return NULL;
    }
    return memory;
}

static bool system_resize(
    void *ctx,
    void *memory,
    size_t memory_len,
    uint8_t alignment,
    size_t new_len,
    uintptr_t ret_addr) {
    (void)ctx;
    (void)ret_addr;
    return memory != NULL && new_len != 0 &&
           valid_alignment(alignment) &&
           pointer_meets_alignment(memory, alignment) &&
           new_len <= memory_len;
}

static void *system_remap(
    void *ctx,
    void *memory,
    size_t memory_len,
    uint8_t alignment,
    size_t new_len,
    uintptr_t ret_addr) {
    (void)ctx;
    (void)memory_len;
    (void)ret_addr;
    if (memory == NULL || new_len == 0 ||
        !valid_alignment(alignment) ||
        !pointer_meets_alignment(memory, alignment)) {
        return NULL;
    }
    void *resized = realloc(memory, new_len);
    if (resized != NULL && !pointer_meets_alignment(resized, alignment)) {
        abort();
    }
    return resized;
}

static void system_free(
    void *ctx,
    void *memory,
    size_t memory_len,
    uint8_t alignment,
    uintptr_t ret_addr) {
    (void)ctx;
    (void)memory_len;
    (void)ret_addr;
    if (memory == NULL) return;
    if (!valid_alignment(alignment) ||
        !pointer_meets_alignment(memory, alignment)) {
        abort();
    }
    free(memory);
}

static const GhosttyAllocatorVtable system_allocator_vtable = {
    .alloc = system_alloc,
    .resize = system_resize,
    .remap = system_remap,
    .free = system_free,
};

static const GhosttyAllocator system_allocator = {
    .ctx = NULL,
    .vtable = &system_allocator_vtable,
};

static void record_allocation_failure(OuroMemoryBudget *budget) {
    if (budget->allocation_failures != UINT64_MAX) {
        budget->allocation_failures++;
    }
}

static bool valid_alignment(uint8_t alignment) {
    /* This exact pin passes Zig std.mem.Alignment's log2 enum value. */
    return alignment <= 4;
}

static bool pointer_meets_alignment(const void *memory, uint8_t alignment) {
    const uintptr_t byte_alignment = (uintptr_t)1 << alignment;
    return ((uintptr_t)memory & (byte_alignment - 1)) == 0;
}

static bool budget_allows_additional(
    OuroMemoryBudget *budget,
    size_t additional) {
    if (budget->live_bytes > budget->limit_bytes ||
        additional > budget->limit_bytes - budget->live_bytes) {
        record_allocation_failure(budget);
        return false;
    }
    return true;
}

static void account_growth(
    OuroMemoryBudget *budget,
    size_t old_len,
    size_t new_len) {
    budget->live_bytes += new_len - old_len;
    if (budget->live_bytes > budget->peak_bytes) {
        budget->peak_bytes = budget->live_bytes;
    }
}

static size_t allocation_usable_size(void *memory, size_t requested_len) {
#if defined(__APPLE__)
    (void)requested_len;
    return malloc_size(memory);
#else
    return requested_len;
#endif
}

static void account_physical_allocation(
    OuroMemoryBudget *budget,
    size_t usable_size) {
    if (usable_size > SIZE_MAX - budget->physical_usable_bytes) abort();
    budget->physical_usable_bytes += usable_size;
    if (budget->physical_usable_bytes >
        budget->physical_peak_usable_bytes) {
        budget->physical_peak_usable_bytes = budget->physical_usable_bytes;
    }
}

static void account_physical_remap(
    OuroMemoryBudget *budget,
    size_t old_usable_size,
    size_t new_usable_size) {
    if (old_usable_size > budget->physical_usable_bytes) abort();
    budget->physical_usable_bytes -= old_usable_size;
    account_physical_allocation(budget, new_usable_size);
}

static void *budget_alloc(
    void *ctx,
    size_t len,
    uint8_t alignment,
    uintptr_t ret_addr) {
    (void)ret_addr;
    OuroMemoryBudget *budget = ctx;
    if (!valid_alignment(alignment) ||
        !budget_allows_additional(budget, len)) {
        if (!valid_alignment(alignment)) record_allocation_failure(budget);
        return NULL;
    }

    /* malloc(0) is implementation-defined; keep a stable non-NULL identity. */
    void *memory = malloc(len == 0 ? 1 : len);
    if (memory == NULL) {
        record_allocation_failure(budget);
        return NULL;
    }
    if (!pointer_meets_alignment(memory, alignment)) {
        free(memory);
        record_allocation_failure(budget);
        return NULL;
    }
    account_growth(budget, 0, len);
    account_physical_allocation(
        budget, allocation_usable_size(memory, len));
    return memory;
}

static bool budget_resize(
    void *ctx,
    void *memory,
    size_t memory_len,
    uint8_t alignment,
    size_t new_len,
    uintptr_t ret_addr) {
    (void)ret_addr;
    OuroMemoryBudget *budget = ctx;
    if (memory == NULL || new_len == 0 || !valid_alignment(alignment) ||
        !pointer_meets_alignment(memory, alignment) ||
        memory_len > budget->live_bytes) {
        record_allocation_failure(budget);
        return false;
    }
    if (new_len == memory_len) return true;

    /* A size change succeeds only after remap physically resizes the block. */
    (void)memory;
    return false;
}

static void *budget_remap(
    void *ctx,
    void *memory,
    size_t memory_len,
    uint8_t alignment,
    size_t new_len,
    uintptr_t ret_addr) {
    (void)ret_addr;
    OuroMemoryBudget *budget = ctx;
    if (memory == NULL || new_len == 0 || !valid_alignment(alignment) ||
        !pointer_meets_alignment(memory, alignment) ||
        memory_len > budget->live_bytes) {
        record_allocation_failure(budget);
        return NULL;
    }
    if (new_len == memory_len) return memory;

    /*
     * A moving realloc may briefly retain old and new blocks. For growth,
     * reserve the complete replacement size in addition to current live
     * requests, rather than only checking the final logical delta.
     */
    if (new_len > memory_len &&
        !budget_allows_additional(budget, new_len)) {
        return NULL;
    }

    const size_t old_usable_size =
        allocation_usable_size(memory, memory_len);
    void *resized = realloc(memory, new_len);
    if (resized == NULL) {
        record_allocation_failure(budget);
        return NULL;
    }
    if (!pointer_meets_alignment(resized, alignment)) {
        /* A conforming target malloc/realloc cannot reach this branch. */
        abort();
    }
    const size_t new_usable_size =
        allocation_usable_size(resized, new_len);
    if (new_len > memory_len) {
        account_growth(budget, memory_len, new_len);
    } else {
        budget->live_bytes -= memory_len - new_len;
    }
    account_physical_remap(
        budget, old_usable_size, new_usable_size);
    return resized;
}

static void budget_free(
    void *ctx,
    void *memory,
    size_t memory_len,
    uint8_t alignment,
    uintptr_t ret_addr) {
    (void)ret_addr;
    OuroMemoryBudget *budget = ctx;
    if (memory == NULL) return;
    if (!valid_alignment(alignment) ||
        !pointer_meets_alignment(memory, alignment) ||
        memory_len > budget->live_bytes) {
        /* The callback cannot report a violated upstream free contract. */
        abort();
    }
    const size_t usable_size = allocation_usable_size(memory, memory_len);
    if (usable_size > budget->physical_usable_bytes) abort();
    budget->live_bytes -= memory_len;
    budget->physical_usable_bytes -= usable_size;
    free(memory);
}

static const GhosttyAllocatorVtable budget_allocator_vtable = {
    .alloc = budget_alloc,
    .resize = budget_resize,
    .remap = budget_remap,
    .free = budget_free,
};

#if defined(__APPLE__)
/* Private conformance hook; intentionally absent from the public ABI header. */
bool ouro_terminal_gate0_test_grow_shrink(
    OuroTerminal *terminal,
    size_t initial_len,
    size_t grown_len,
    size_t shrunk_len,
    size_t *out_initial_usable,
    size_t *out_grown_usable,
    size_t *out_shrunk_usable) {
    if (terminal == NULL || initial_len == 0 || grown_len <= initial_len ||
        shrunk_len == 0 || shrunk_len >= grown_len ||
        out_initial_usable == NULL || out_grown_usable == NULL ||
        out_shrunk_usable == NULL) {
        return false;
    }
    *out_initial_usable = 0;
    *out_grown_usable = 0;
    *out_shrunk_usable = 0;

    const size_t baseline_live = terminal->memory.live_bytes;
    const size_t baseline_physical = terminal->memory.physical_usable_bytes;
    void *memory = budget_alloc(&terminal->memory, initial_len, 4, 0);
    if (memory == NULL) return false;
    *out_initial_usable = malloc_size(memory);

    void *grown = budget_remap(
        &terminal->memory, memory, initial_len, 4, grown_len, 0);
    if (grown == NULL) {
        budget_free(&terminal->memory, memory, initial_len, 4, 0);
        return false;
    }
    *out_grown_usable = malloc_size(grown);

    void *shrunk = budget_remap(
        &terminal->memory, grown, grown_len, 4, shrunk_len, 0);
    if (shrunk == NULL) {
        budget_free(&terminal->memory, grown, grown_len, 4, 0);
        return false;
    }
    *out_shrunk_usable = malloc_size(shrunk);
    budget_free(&terminal->memory, shrunk, shrunk_len, 4, 0);

    if (terminal->memory.live_bytes != baseline_live ||
        terminal->memory.physical_usable_bytes != baseline_physical) {
        abort();
    }
    return true;
}
#endif

static void initialize_adapter(
    OuroTerminal *adapter,
    const OuroTerminalConfig *config) {
    adapter->config = *config;
    adapter->memory.limit_bytes = config->engine_memory_max_bytes;
    adapter->allocator.ctx = &adapter->memory;
    adapter->allocator.vtable = &budget_allocator_vtable;
}

static void release_adapter_storage(OuroTerminal *adapter) {
    if (adapter->memory.live_bytes != 0 ||
        adapter->memory.physical_usable_bytes != 0) {
        /* Losing the context would turn a Ghostty leak into untracked memory. */
        abort();
    }
    free(adapter);
}

static OuroTerminalResult map_result(GhosttyResult result) {
    if (result == GHOSTTY_SUCCESS) return OURO_TERMINAL_OK;
    if (result == GHOSTTY_INVALID_VALUE) return OURO_TERMINAL_INVALID_ARGUMENT;
    if (result == GHOSTTY_OUT_OF_MEMORY) return OURO_TERMINAL_OUT_OF_MEMORY;
    if (result == GHOSTTY_OUT_OF_SPACE) return OURO_TERMINAL_BUFFER_TOO_SMALL;
    if (result == GHOSTTY_NO_VALUE) return OURO_TERMINAL_NO_VALUE;
    return OURO_TERMINAL_ENGINE_ERROR;
}

OuroTerminalResult ouro_terminal_page_budget_new(
    size_t limit_bytes,
    OuroTerminalPageBudget **out_budget) {
    if (limit_bytes == 0 || out_budget == NULL) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    *out_budget = NULL;

    OuroTerminalPageBudget *budget = calloc(1, sizeof(*budget));
    if (budget == NULL) return OURO_TERMINAL_OUT_OF_MEMORY;
    GhosttyResult result = ghostty_page_budget_new(
        &system_allocator, &budget->budget, limit_bytes);
    if (result != GHOSTTY_SUCCESS) {
        free(budget);
        return map_result(result);
    }
    *out_budget = budget;
    return OURO_TERMINAL_OK;
}

void ouro_terminal_page_budget_free(OuroTerminalPageBudget *budget) {
    if (budget == NULL) return;
    ghostty_page_budget_free(budget->budget);
    free(budget);
}

OuroTerminalResult ouro_terminal_page_budget_stats(
    OuroTerminalPageBudget *budget,
    OuroTerminalPageBudgetStats *out_stats) {
    if (budget == NULL || out_stats == NULL ||
        out_stats->size != sizeof(*out_stats) ||
        out_stats->abi_version != OURO_TERMINAL_ENGINE_ABI_VERSION) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }

    GhosttyPageBudgetStats stats = GHOSTTY_INIT_SIZED(GhosttyPageBudgetStats);
    GhosttyResult result = ghostty_page_budget_get_stats(
        budget->budget, &stats);
    if (result != GHOSTTY_SUCCESS) return map_result(result);
    out_stats->limit_bytes = stats.limit_bytes;
    out_stats->reserved_bytes = stats.reserved_bytes;
    out_stats->peak_reserved_bytes = stats.peak_reserved_bytes;
    out_stats->denial_count = stats.denial_count;
    out_stats->child_failure_count = stats.child_failure_count;
    return OURO_TERMINAL_OK;
}

static OuroTerminalResult page_failure_epoch(
    OuroTerminal *terminal,
    size_t *out_epoch) {
    return map_result(ghostty_terminal_get(
        terminal->terminal,
        GHOSTTY_TERMINAL_DATA_PAGE_BUDGET_FAILURE_EPOCH,
        out_epoch));
}

static OuroTerminalResult finish_page_observed_operation(
    OuroTerminal *terminal,
    size_t epoch_before,
    GhosttyResult engine_result) {
    size_t epoch_after = 0;
    OuroTerminalResult epoch_result = page_failure_epoch(
        terminal, &epoch_after);
    if (epoch_result != OURO_TERMINAL_OK) return epoch_result;
    if (epoch_after != epoch_before) return OURO_TERMINAL_OUT_OF_MEMORY;
    return map_result(engine_result);
}

static bool valid_config(const OuroTerminalConfig *config) {
    return config != NULL &&
           config->size == sizeof(*config) &&
           config->abi_version == OURO_TERMINAL_ENGINE_ABI_VERSION &&
           config->columns > 0 && config->rows > 0 &&
           config->cell_width_px > 0 && config->cell_height_px > 0 &&
           config->snapshot_max_bytes > 0 &&
           config->engine_memory_max_bytes > 0;
}

static GhosttyResult apply_runtime_bounds(
    GhosttyTerminal terminal,
    const OuroTerminalConfig *config) {
    GhosttyResult result = ghostty_terminal_set(
        terminal,
        GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,
        &config->scrollback_max_bytes);
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_terminal_set(
            terminal,
            GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,
            &config->scrollback_max_lines);
    }
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_terminal_set(
            terminal,
            GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT,
            &config->kitty_image_max_bytes);
    }
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_terminal_set(
            terminal,
            GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES,
            &config->apc_max_bytes);
    }
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_terminal_set(
            terminal,
            GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES,
            &config->continuation_max_bytes);
    }
    return result;
}

static OuroTerminalResult terminal_new_internal(
    const OuroTerminalConfig *config,
    OuroTerminalPageBudget *page_budget,
    OuroTerminal **out_terminal) {
    if (!valid_config(config) || out_terminal == NULL) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    *out_terminal = NULL;

    OuroTerminal *adapter = calloc(1, sizeof(*adapter));
    if (adapter == NULL) return OURO_TERMINAL_OUT_OF_MEMORY;
    initialize_adapter(adapter, config);

    GhosttyResult result;
    if (page_budget == NULL) {
        result = ghostty_terminal_new(
            &adapter->allocator,
            &adapter->terminal,
            config->columns,
            config->rows);
    } else {
        GhosttyPageBudgetFailure page_failure =
            GHOSTTY_PAGE_BUDGET_FAILURE_NONE;
        GhosttyTerminalCreateOptions options =
            GHOSTTY_INIT_SIZED(GhosttyTerminalCreateOptions);
        options.page_budget = page_budget->budget;
        options.page_budget_failure_out = &page_failure;
        result = ghostty_terminal_new_with_options(
            &adapter->allocator,
            &adapter->terminal,
            config->columns,
            config->rows,
            &options);
        if (result != GHOSTTY_SUCCESS &&
            page_failure != GHOSTTY_PAGE_BUDGET_FAILURE_NONE) {
            result = GHOSTTY_OUT_OF_MEMORY;
        }
    }
    if (result != GHOSTTY_SUCCESS) {
        release_adapter_storage(adapter);
        return map_result(result);
    }

    /* Every potentially large protocol-owned store is bounded explicitly. */
    result = install_terminal_effects(adapter);
    if (result == GHOSTTY_SUCCESS) {
        result = apply_runtime_bounds(adapter->terminal, config);
    }
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_terminal_resize(
            adapter->terminal,
            config->columns,
            config->rows,
            config->cell_width_px,
            config->cell_height_px);
    }
    if (result != GHOSTTY_SUCCESS) {
        ghostty_terminal_free(adapter->terminal);
        release_adapter_storage(adapter);
        return map_result(result);
    }

    *out_terminal = adapter;
    return OURO_TERMINAL_OK;
}

OuroTerminalResult ouro_terminal_new(
    const OuroTerminalConfig *config,
    OuroTerminal **out_terminal) {
    return terminal_new_internal(config, NULL, out_terminal);
}

OuroTerminalResult ouro_terminal_new_with_page_budget(
    const OuroTerminalConfig *config,
    OuroTerminalPageBudget *page_budget,
    OuroTerminal **out_terminal) {
    if (page_budget == NULL) return OURO_TERMINAL_INVALID_ARGUMENT;
    return terminal_new_internal(config, page_budget, out_terminal);
}

void ouro_terminal_free(OuroTerminal *terminal) {
    if (terminal == NULL) return;
    ghostty_terminal_free(terminal->terminal);
    release_adapter_storage(terminal);
}

OuroTerminalResult ouro_terminal_feed(
    OuroTerminal *terminal,
    const uint8_t *bytes,
    size_t length) {
    if (terminal == NULL || (bytes == NULL && length != 0)) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    if (length == 0) return OURO_TERMINAL_OK;

    size_t page_epoch_before = 0;
    OuroTerminalResult page_result = page_failure_epoch(
        terminal, &page_epoch_before);
    if (page_result != OURO_TERMINAL_OK) return page_result;
    const uint64_t failures_before = terminal->memory.allocation_failures;
    if (failures_before == UINT64_MAX) {
        /* The saturating counter can no longer prove a mutation succeeded. */
        return OURO_TERMINAL_ENGINE_ERROR;
    }
    terminal->pty_response_length = 0;
    terminal->pty_response_overflow = false;
    ghostty_terminal_vt_write(terminal->terminal, bytes, length);
    if (terminal->pty_response_overflow) return OURO_TERMINAL_ENGINE_ERROR;
    page_result = finish_page_observed_operation(
        terminal, page_epoch_before, GHOSTTY_SUCCESS);
    if (page_result != OURO_TERMINAL_OK) return page_result;
    if (terminal->memory.allocation_failures != failures_before) {
        /* Upstream may already have applied a prefix; caller must resync. */
        return OURO_TERMINAL_OUT_OF_MEMORY;
    }
    return OURO_TERMINAL_OK;
}

OuroTerminalResult ouro_terminal_take_pty_responses(
    OuroTerminal *terminal,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length) {
    if (terminal == NULL || out_length == NULL ||
        (buffer == NULL && capacity != 0)) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    *out_length = terminal->pty_response_length;
    if (capacity < terminal->pty_response_length) {
        return OURO_TERMINAL_BUFFER_TOO_SMALL;
    }
    if (terminal->pty_response_length != 0) {
        memcpy(buffer, terminal->pty_responses, terminal->pty_response_length);
    }
    terminal->pty_response_length = 0;
    return OURO_TERMINAL_OK;
}

OuroTerminalResult ouro_terminal_take_bells(
    OuroTerminal *terminal,
    uint32_t *out_count) {
    if (terminal == NULL || out_count == NULL) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    *out_count = terminal->pending_bell_count;
    terminal->pending_bell_count = 0;
    return OURO_TERMINAL_OK;
}

OuroTerminalResult ouro_terminal_hyperlink_uri_at_viewport(
    OuroTerminal *terminal,
    uint16_t column,
    uint32_t row,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length) {
    if (terminal == NULL || out_length == NULL ||
        (buffer == NULL && capacity != 0)) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    *out_length = 0;
    GhosttyPoint point = {
        .tag = GHOSTTY_POINT_TAG_VIEWPORT,
        .value = {.coordinate = {.x = column, .y = row}},
    };
    GhosttyGridRef reference = GHOSTTY_INIT_SIZED(GhosttyGridRef);
    GhosttyResult result = ghostty_terminal_grid_ref(
        terminal->terminal, point, &reference);
    if (result != GHOSTTY_SUCCESS) return map_result(result);

    size_t required = 0;
    result = ghostty_grid_ref_hyperlink_uri(
        &reference, NULL, 0, &required);
    if (result != GHOSTTY_SUCCESS && result != GHOSTTY_OUT_OF_SPACE) {
        return map_result(result);
    }
    *out_length = required;
    if (required == 0) return OURO_TERMINAL_NO_VALUE;
    if (capacity < required) return OURO_TERMINAL_BUFFER_TOO_SMALL;
    result = ghostty_grid_ref_hyperlink_uri(
        &reference, buffer, capacity, &required);
    if (result != GHOSTTY_SUCCESS) return map_result(result);
    *out_length = required;
    return OURO_TERMINAL_OK;
}

static OuroTerminalResult copy_terminal_metadata(
    OuroTerminal *terminal,
    GhosttyTerminalData data,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length) {
    if (terminal == NULL || out_length == NULL ||
        (buffer == NULL && capacity != 0)) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    GhosttyString value = {0};
    GhosttyResult result = ghostty_terminal_get(
        terminal->terminal, data, &value);
    if (result != GHOSTTY_SUCCESS) return map_result(result);
    if (value.len > 4096) {
        *out_length = 0;
        return OURO_TERMINAL_BUFFER_TOO_SMALL;
    }
    *out_length = value.len;
    if (capacity < value.len) return OURO_TERMINAL_BUFFER_TOO_SMALL;
    if (value.len != 0) memcpy(buffer, value.ptr, value.len);
    return OURO_TERMINAL_OK;
}

OuroTerminalResult ouro_terminal_copy_title(
    OuroTerminal *terminal,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length) {
    return copy_terminal_metadata(
        terminal, GHOSTTY_TERMINAL_DATA_TITLE, buffer, capacity, out_length);
}

OuroTerminalResult ouro_terminal_copy_pwd(
    OuroTerminal *terminal,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length) {
    return copy_terminal_metadata(
        terminal, GHOSTTY_TERMINAL_DATA_PWD, buffer, capacity, out_length);
}

OuroTerminalResult ouro_terminal_metadata_epoch(
    OuroTerminal *terminal,
    uint64_t *out_epoch) {
    if (terminal == NULL || out_epoch == NULL) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    *out_epoch = terminal->metadata_epoch;
    return OURO_TERMINAL_OK;
}

OuroTerminalResult ouro_terminal_resize(
    OuroTerminal *terminal,
    uint16_t columns,
    uint16_t rows,
    uint32_t cell_width_px,
    uint32_t cell_height_px) {
    if (terminal == NULL || columns == 0 || rows == 0 ||
        cell_width_px == 0 || cell_height_px == 0) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    size_t page_epoch_before = 0;
    OuroTerminalResult page_result = page_failure_epoch(
        terminal, &page_epoch_before);
    if (page_result != OURO_TERMINAL_OK) return page_result;
    GhosttyResult result = ghostty_terminal_resize(
        terminal->terminal,
        columns,
        rows,
        cell_width_px,
        cell_height_px);
    return finish_page_observed_operation(
        terminal, page_epoch_before, result);
}

static bool valid_scroll_viewport(
    const OuroTerminalScrollViewport *viewport) {
    if (viewport == NULL || viewport->size != sizeof(*viewport) ||
        viewport->abi_version != OURO_TERMINAL_ENGINE_ABI_VERSION) {
        return false;
    }

    switch (viewport->kind) {
        case OURO_TERMINAL_SCROLL_VIEWPORT_TOP:
        case OURO_TERMINAL_SCROLL_VIEWPORT_BOTTOM:
            return viewport->delta == 0 && viewport->row == 0;
        case OURO_TERMINAL_SCROLL_VIEWPORT_DELTA:
            if (viewport->row != 0) return false;
#if INTPTR_MAX < INT64_MAX
            if (viewport->delta < (int64_t)INTPTR_MIN ||
                viewport->delta > (int64_t)INTPTR_MAX) {
                return false;
            }
#endif
            return true;
        case OURO_TERMINAL_SCROLL_VIEWPORT_ROW:
            if (viewport->delta != 0) return false;
#if SIZE_MAX < UINT64_MAX
            if (viewport->row > (uint64_t)SIZE_MAX) return false;
#endif
            return true;
        default:
            return false;
    }
}

OuroTerminalResult ouro_terminal_scroll_viewport(
    OuroTerminal *terminal,
    const OuroTerminalScrollViewport *viewport) {
    if (terminal == NULL || !valid_scroll_viewport(viewport)) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }

    GhosttyTerminalScrollViewport behavior = {0};
    switch (viewport->kind) {
        case OURO_TERMINAL_SCROLL_VIEWPORT_TOP:
            behavior.tag = GHOSTTY_SCROLL_VIEWPORT_TOP;
            break;
        case OURO_TERMINAL_SCROLL_VIEWPORT_BOTTOM:
            behavior.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM;
            break;
        case OURO_TERMINAL_SCROLL_VIEWPORT_DELTA:
            behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA;
            behavior.value.delta = (intptr_t)viewport->delta;
            break;
        case OURO_TERMINAL_SCROLL_VIEWPORT_ROW:
            behavior.tag = GHOSTTY_SCROLL_VIEWPORT_ROW;
            behavior.value.row = (size_t)viewport->row;
            break;
        default:
            /* valid_scroll_viewport already rejects unknown tags. */
            return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    ghostty_terminal_scroll_viewport(terminal->terminal, behavior);
    return OURO_TERMINAL_OK;
}

OuroTerminalResult ouro_terminal_scrollbar(
    OuroTerminal *terminal,
    OuroTerminalScrollbar *out_scrollbar) {
    if (terminal == NULL || out_scrollbar == NULL ||
        out_scrollbar->size != sizeof(*out_scrollbar) ||
        out_scrollbar->abi_version != OURO_TERMINAL_ENGINE_ABI_VERSION) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }

    GhosttyTerminalScrollbar scrollbar = {0};
    GhosttyResult engine_result = ghostty_terminal_get(
        terminal->terminal,
        GHOSTTY_TERMINAL_DATA_SCROLLBAR,
        &scrollbar);
    if (engine_result != GHOSTTY_SUCCESS) return map_result(engine_result);
    if (scrollbar.len > scrollbar.total ||
        scrollbar.offset > scrollbar.total - scrollbar.len) {
        return OURO_TERMINAL_ENGINE_ERROR;
    }

    out_scrollbar->total = scrollbar.total;
    out_scrollbar->offset = scrollbar.offset;
    out_scrollbar->length = scrollbar.len;
    return OURO_TERMINAL_OK;
}

static bool valid_output_buffer(
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length) {
    return out_length != NULL && (buffer != NULL || capacity == 0);
}

static bool valid_unicode_scalar(uint32_t value) {
    return value == 0 ||
           (value <= 0x10ffffu && !(value >= 0xd800u && value <= 0xdfffu));
}

static bool valid_utf8_text(
    const uint8_t *bytes,
    size_t length,
    bool reject_controls) {
    if (bytes == NULL && length != 0) return false;
    size_t i = 0;
    while (i < length) {
        uint32_t codepoint = bytes[i++];
        size_t continuation = 0;
        uint32_t minimum = 0;
        if (codepoint <= 0x7fu) {
            continuation = 0;
        } else if (codepoint >= 0xc2u && codepoint <= 0xdfu) {
            codepoint &= 0x1fu;
            continuation = 1;
            minimum = 0x80u;
        } else if (codepoint >= 0xe0u && codepoint <= 0xefu) {
            codepoint &= 0x0fu;
            continuation = 2;
            minimum = 0x800u;
        } else if (codepoint >= 0xf0u && codepoint <= 0xf4u) {
            codepoint &= 0x07u;
            continuation = 3;
            minimum = 0x10000u;
        } else {
            return false;
        }
        if (continuation > length - i) return false;
        for (size_t j = 0; j < continuation; ++j) {
            const uint8_t byte = bytes[i++];
            if ((byte & 0xc0u) != 0x80u) return false;
            codepoint = (codepoint << 6) | (uint32_t)(byte & 0x3fu);
        }
        if ((continuation != 0 && codepoint < minimum) ||
            !valid_unicode_scalar(codepoint)) {
            return false;
        }
        if (reject_controls &&
            (codepoint <= 0x1fu || codepoint == 0x7fu ||
             (codepoint >= 0xf700u && codepoint <= 0xf8ffu))) {
            return false;
        }
    }
    return true;
}

static OuroTerminalResult terminal_mode(
    OuroTerminal *terminal,
    GhosttyMode mode,
    bool *out_enabled) {
    GhosttyTerminalModeConfig query = {.mode = mode, .value = false};
    GhosttyResult result = ghostty_terminal_get(
        terminal->terminal, GHOSTTY_TERMINAL_DATA_MODE, &query);
    if (result == GHOSTTY_SUCCESS) *out_enabled = query.value;
    return map_result(result);
}

static GhosttyKey key_from_hid_usage(uint32_t usage) {
    if (usage >= 0x04u && usage <= 0x1du) {
        return (GhosttyKey)(GHOSTTY_KEY_A + (usage - 0x04u));
    }
    if (usage >= 0x3au && usage <= 0x45u) {
        return (GhosttyKey)(GHOSTTY_KEY_F1 + (usage - 0x3au));
    }
    if (usage >= 0x68u && usage <= 0x73u) {
        return (GhosttyKey)(GHOSTTY_KEY_F13 + (usage - 0x68u));
    }
    switch (usage) {
        case 0x1e: return GHOSTTY_KEY_DIGIT_1;
        case 0x1f: return GHOSTTY_KEY_DIGIT_2;
        case 0x20: return GHOSTTY_KEY_DIGIT_3;
        case 0x21: return GHOSTTY_KEY_DIGIT_4;
        case 0x22: return GHOSTTY_KEY_DIGIT_5;
        case 0x23: return GHOSTTY_KEY_DIGIT_6;
        case 0x24: return GHOSTTY_KEY_DIGIT_7;
        case 0x25: return GHOSTTY_KEY_DIGIT_8;
        case 0x26: return GHOSTTY_KEY_DIGIT_9;
        case 0x27: return GHOSTTY_KEY_DIGIT_0;
        case 0x28: return GHOSTTY_KEY_ENTER;
        case 0x29: return GHOSTTY_KEY_ESCAPE;
        case 0x2a: return GHOSTTY_KEY_BACKSPACE;
        case 0x2b: return GHOSTTY_KEY_TAB;
        case 0x2c: return GHOSTTY_KEY_SPACE;
        case 0x2d: return GHOSTTY_KEY_MINUS;
        case 0x2e: return GHOSTTY_KEY_EQUAL;
        case 0x2f: return GHOSTTY_KEY_BRACKET_LEFT;
        case 0x30: return GHOSTTY_KEY_BRACKET_RIGHT;
        case 0x31: return GHOSTTY_KEY_BACKSLASH;
        case 0x32: return GHOSTTY_KEY_INTL_BACKSLASH;
        case 0x33: return GHOSTTY_KEY_SEMICOLON;
        case 0x34: return GHOSTTY_KEY_QUOTE;
        case 0x35: return GHOSTTY_KEY_BACKQUOTE;
        case 0x36: return GHOSTTY_KEY_COMMA;
        case 0x37: return GHOSTTY_KEY_PERIOD;
        case 0x38: return GHOSTTY_KEY_SLASH;
        case 0x39: return GHOSTTY_KEY_CAPS_LOCK;
        case 0x46: return GHOSTTY_KEY_PRINT_SCREEN;
        case 0x47: return GHOSTTY_KEY_SCROLL_LOCK;
        case 0x48: return GHOSTTY_KEY_PAUSE;
        case 0x49: return GHOSTTY_KEY_INSERT;
        case 0x4a: return GHOSTTY_KEY_HOME;
        case 0x4b: return GHOSTTY_KEY_PAGE_UP;
        case 0x4c: return GHOSTTY_KEY_DELETE;
        case 0x4d: return GHOSTTY_KEY_END;
        case 0x4e: return GHOSTTY_KEY_PAGE_DOWN;
        case 0x4f: return GHOSTTY_KEY_ARROW_RIGHT;
        case 0x50: return GHOSTTY_KEY_ARROW_LEFT;
        case 0x51: return GHOSTTY_KEY_ARROW_DOWN;
        case 0x52: return GHOSTTY_KEY_ARROW_UP;
        case 0x53: return GHOSTTY_KEY_NUM_LOCK;
        case 0x54: return GHOSTTY_KEY_NUMPAD_DIVIDE;
        case 0x55: return GHOSTTY_KEY_NUMPAD_MULTIPLY;
        case 0x56: return GHOSTTY_KEY_NUMPAD_SUBTRACT;
        case 0x57: return GHOSTTY_KEY_NUMPAD_ADD;
        case 0x58: return GHOSTTY_KEY_NUMPAD_ENTER;
        case 0x59: return GHOSTTY_KEY_NUMPAD_1;
        case 0x5a: return GHOSTTY_KEY_NUMPAD_2;
        case 0x5b: return GHOSTTY_KEY_NUMPAD_3;
        case 0x5c: return GHOSTTY_KEY_NUMPAD_4;
        case 0x5d: return GHOSTTY_KEY_NUMPAD_5;
        case 0x5e: return GHOSTTY_KEY_NUMPAD_6;
        case 0x5f: return GHOSTTY_KEY_NUMPAD_7;
        case 0x60: return GHOSTTY_KEY_NUMPAD_8;
        case 0x61: return GHOSTTY_KEY_NUMPAD_9;
        case 0x62: return GHOSTTY_KEY_NUMPAD_0;
        case 0x63: return GHOSTTY_KEY_NUMPAD_DECIMAL;
        case 0x64: return GHOSTTY_KEY_INTL_BACKSLASH;
        case 0x65: return GHOSTTY_KEY_CONTEXT_MENU;
        case 0x66: return GHOSTTY_KEY_POWER;
        case 0x67: return GHOSTTY_KEY_NUMPAD_EQUAL;
        case 0x75: return GHOSTTY_KEY_HELP;
        case 0x7b: return GHOSTTY_KEY_CUT;
        case 0x7c: return GHOSTTY_KEY_COPY;
        case 0x7d: return GHOSTTY_KEY_PASTE;
        case 0x7f: return GHOSTTY_KEY_AUDIO_VOLUME_MUTE;
        case 0x80: return GHOSTTY_KEY_AUDIO_VOLUME_UP;
        case 0x81: return GHOSTTY_KEY_AUDIO_VOLUME_DOWN;
        case 0x87: return GHOSTTY_KEY_INTL_RO;
        case 0x89: return GHOSTTY_KEY_INTL_YEN;
        case 0xe0: return GHOSTTY_KEY_CONTROL_LEFT;
        case 0xe1: return GHOSTTY_KEY_SHIFT_LEFT;
        case 0xe2: return GHOSTTY_KEY_ALT_LEFT;
        case 0xe3: return GHOSTTY_KEY_META_LEFT;
        case 0xe4: return GHOSTTY_KEY_CONTROL_RIGHT;
        case 0xe5: return GHOSTTY_KEY_SHIFT_RIGHT;
        case 0xe6: return GHOSTTY_KEY_ALT_RIGHT;
        case 0xe7: return GHOSTTY_KEY_META_RIGHT;
        default: return GHOSTTY_KEY_UNIDENTIFIED;
    }
}

static bool valid_input_config(const OuroTerminalInputConfig *config) {
    return config != NULL && config->size == sizeof(*config) &&
           config->abi_version == OURO_TERMINAL_ENGINE_ABI_VERSION &&
           config->option_as_alt >= OURO_TERMINAL_OPTION_AS_ALT_FALSE &&
           config->option_as_alt <= OURO_TERMINAL_OPTION_AS_ALT_RIGHT;
}

OuroTerminalResult ouro_terminal_input_new(
    OuroTerminal *terminal,
    const OuroTerminalInputConfig *config,
    OuroTerminalInput **out_input) {
    if (terminal == NULL || !valid_input_config(config) || out_input == NULL) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    *out_input = NULL;
    OuroTerminalInput *input = calloc(1, sizeof(*input));
    if (input == NULL) return OURO_TERMINAL_OUT_OF_MEMORY;
    input->terminal = terminal;
    input->config = *config;

    GhosttyResult result = ghostty_key_encoder_new(
        &terminal->allocator, &input->key_encoder);
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_key_event_new(
            &terminal->allocator, &input->key_event);
    }
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_mouse_encoder_new(
            &terminal->allocator, &input->mouse_encoder);
    }
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_mouse_event_new(
            &terminal->allocator, &input->mouse_event);
    }
    if (result != GHOSTTY_SUCCESS) {
        ghostty_mouse_event_free(input->mouse_event);
        ghostty_mouse_encoder_free(input->mouse_encoder);
        ghostty_key_event_free(input->key_event);
        ghostty_key_encoder_free(input->key_encoder);
        free(input);
        return map_result(result);
    }
    const bool track_last_cell = true;
    ghostty_mouse_encoder_setopt(
        input->mouse_encoder,
        GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL,
        &track_last_cell);
    *out_input = input;
    return OURO_TERMINAL_OK;
}

void ouro_terminal_input_free(OuroTerminalInput *input) {
    if (input == NULL) return;
    for (size_t i = 0; i < 11; ++i) {
        ghostty_mouse_encoder_free(input->gesture_mouse_encoders[i]);
    }
    ghostty_mouse_event_free(input->mouse_event);
    ghostty_mouse_encoder_free(input->mouse_encoder);
    ghostty_key_event_free(input->key_event);
    ghostty_key_encoder_free(input->key_encoder);
    free(input);
}

OuroTerminalResult ouro_terminal_input_encode_key(
    OuroTerminalInput *input,
    const OuroTerminalKeyEvent *event,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length) {
    if (input == NULL || event == NULL ||
        event->size != sizeof(*event) ||
        event->abi_version != OURO_TERMINAL_ENGINE_ABI_VERSION ||
        event->action < OURO_TERMINAL_KEY_RELEASE ||
        event->action > OURO_TERMINAL_KEY_REPEAT ||
        (event->modifiers & ~OURO_TERMINAL_MOD_ALL) != 0 ||
        (event->consumed_modifiers & ~event->modifiers) != 0 ||
        !valid_unicode_scalar(event->unshifted_codepoint) ||
        event->utf8_length > OURO_TERMINAL_MAX_KEY_TEXT_BYTES ||
        !valid_utf8_text(event->utf8, event->utf8_length, true) ||
        !valid_output_buffer(buffer, capacity, out_length)) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    *out_length = 0;
    bool keyboard_locked = false;
    OuroTerminalResult mode_result = terminal_mode(
        input->terminal, GHOSTTY_MODE_KAM, &keyboard_locked);
    if (mode_result != OURO_TERMINAL_OK) return mode_result;
    if (keyboard_locked) return OURO_TERMINAL_OK;

    ghostty_key_encoder_setopt_from_terminal(
        input->key_encoder, input->terminal->terminal);
    const GhosttyOptionAsAlt option_as_alt =
        (GhosttyOptionAsAlt)input->config.option_as_alt;
    ghostty_key_encoder_setopt(
        input->key_encoder,
        GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT,
        &option_as_alt);
    ghostty_key_event_set_action(
        input->key_event, (GhosttyKeyAction)event->action);
    ghostty_key_event_set_key(
        input->key_event, key_from_hid_usage(event->hid_usage));
    ghostty_key_event_set_mods(
        input->key_event, (GhosttyMods)event->modifiers);
    ghostty_key_event_set_consumed_mods(
        input->key_event, (GhosttyMods)event->consumed_modifiers);
    ghostty_key_event_set_composing(input->key_event, event->composing);
    ghostty_key_event_set_unshifted_codepoint(
        input->key_event, event->unshifted_codepoint);
    ghostty_key_event_set_utf8(
        input->key_event,
        (const char *)event->utf8,
        event->utf8_length);
    return map_result(ghostty_key_encoder_encode(
        input->key_encoder,
        input->key_event,
        (char *)buffer,
        capacity,
        out_length));
}

OuroTerminalResult ouro_terminal_input_encode_committed_text(
    OuroTerminalInput *input,
    const uint8_t *utf8,
    size_t utf8_length,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length) {
    if (input == NULL || utf8_length > OURO_TERMINAL_MAX_KEY_TEXT_BYTES ||
        !valid_utf8_text(utf8, utf8_length, true) ||
        !valid_output_buffer(buffer, capacity, out_length)) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    *out_length = utf8_length;
    bool keyboard_locked = false;
    OuroTerminalResult mode_result = terminal_mode(
        input->terminal, GHOSTTY_MODE_KAM, &keyboard_locked);
    if (mode_result != OURO_TERMINAL_OK) return mode_result;
    if (keyboard_locked) {
        *out_length = 0;
        return OURO_TERMINAL_OK;
    }
    if (capacity < utf8_length) return OURO_TERMINAL_BUFFER_TOO_SMALL;
    if (utf8_length != 0) memcpy(buffer, utf8, utf8_length);
    return OURO_TERMINAL_OK;
}

static bool double_to_u32(double value, bool allow_zero, uint32_t *out) {
    if (!isfinite(value) || value < 0.0 || value > (double)UINT32_MAX ||
        (!allow_zero && value == 0.0)) {
        return false;
    }
    *out = (uint32_t)value;
    return allow_zero || *out != 0;
}

OuroTerminalResult ouro_terminal_input_set_mouse_geometry(
    OuroTerminalInput *input,
    const OuroTerminalMouseGeometry *geometry) {
    if (input == NULL || geometry == NULL ||
        geometry->size != sizeof(*geometry) ||
        geometry->abi_version != OURO_TERMINAL_ENGINE_ABI_VERSION) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    GhosttyMouseEncoderSize value = GHOSTTY_INIT_SIZED(GhosttyMouseEncoderSize);
    if (!double_to_u32(geometry->screen_width, false, &value.screen_width) ||
        !double_to_u32(geometry->screen_height, false, &value.screen_height) ||
        !double_to_u32(geometry->cell_width, false, &value.cell_width) ||
        !double_to_u32(geometry->cell_height, false, &value.cell_height) ||
        !double_to_u32(geometry->padding_top, true, &value.padding_top) ||
        !double_to_u32(geometry->padding_bottom, true, &value.padding_bottom) ||
        !double_to_u32(geometry->padding_right, true, &value.padding_right) ||
        !double_to_u32(geometry->padding_left, true, &value.padding_left)) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    input->mouse_geometry = value;
    input->mouse_geometry_valid = true;
    ghostty_mouse_encoder_setopt(
        input->mouse_encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &value);
    ghostty_mouse_encoder_reset(input->mouse_encoder);
    return OURO_TERMINAL_OK;
}

OuroTerminalResult ouro_terminal_input_mouse_reporting(
    OuroTerminalInput *input,
    bool *out_enabled) {
    if (input == NULL || out_enabled == NULL) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    return map_result(ghostty_terminal_get(
        input->terminal->terminal,
        GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING,
        out_enabled));
}

static OuroTerminalResult current_mouse_mode_mask(
    OuroTerminalInput *input,
    uint16_t *out_mask) {
    const GhosttyMode modes[] = {
        GHOSTTY_MODE_X10_MOUSE,
        GHOSTTY_MODE_NORMAL_MOUSE,
        GHOSTTY_MODE_BUTTON_MOUSE,
        GHOSTTY_MODE_ANY_MOUSE,
        GHOSTTY_MODE_UTF8_MOUSE,
        GHOSTTY_MODE_SGR_MOUSE,
        GHOSTTY_MODE_URXVT_MOUSE,
        GHOSTTY_MODE_SGR_PIXELS_MOUSE,
    };
    uint16_t mask = 0;
    for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); ++i) {
        bool enabled = false;
        OuroTerminalResult result = terminal_mode(
            input->terminal, modes[i], &enabled);
        if (result != OURO_TERMINAL_OK) return result;
        if (enabled) mask |= (uint16_t)(1u << i);
    }
    *out_mask = mask;
    return OURO_TERMINAL_OK;
}

static OuroTerminalResult sync_mouse_encoder(OuroTerminalInput *input) {
    uint16_t mask = 0;
    OuroTerminalResult result = current_mouse_mode_mask(input, &mask);
    if (result != OURO_TERMINAL_OK) return result;
    if (!input->mouse_modes_valid || input->mouse_mode_mask != mask) {
        ghostty_mouse_encoder_setopt_from_terminal(
            input->mouse_encoder, input->terminal->terminal);
        input->mouse_mode_mask = mask;
        input->mouse_modes_valid = true;
    }
    return OURO_TERMINAL_OK;
}

static bool valid_surface_position(double x, double y) {
    return isfinite(x) && isfinite(y) && x >= 0.0 && y >= 0.0 &&
           x <= (double)FLT_MAX && y <= (double)FLT_MAX;
}

static size_t mouse_button_index(OuroTerminalMouseButton button) {
    return (size_t)((uint32_t)button - (uint32_t)OURO_TERMINAL_MOUSE_BUTTON_LEFT);
}

static GhosttyResult new_latched_mouse_encoder(
    OuroTerminalInput *input,
    GhosttyMouseEncoder *out_encoder) {
    *out_encoder = NULL;
    GhosttyResult result = ghostty_mouse_encoder_new(
        &input->terminal->allocator, out_encoder);
    if (result != GHOSTTY_SUCCESS) return result;
    const bool track_last_cell = true;
    ghostty_mouse_encoder_setopt(
        *out_encoder,
        GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL,
        &track_last_cell);
    ghostty_mouse_encoder_setopt_from_terminal(
        *out_encoder, input->terminal->terminal);
    ghostty_mouse_encoder_setopt(
        *out_encoder,
        GHOSTTY_MOUSE_ENCODER_OPT_SIZE,
        &input->mouse_geometry);
    return GHOSTTY_SUCCESS;
}

static OuroTerminalResult encode_mouse_common(
    OuroTerminalInput *input,
    GhosttyMouseAction action,
    OuroTerminalMouseButton button,
    OuroTerminalModifiers modifiers,
    double x,
    double y,
    bool update_pressed,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length) {
    if (!input->mouse_geometry_valid ||
        button < OURO_TERMINAL_MOUSE_BUTTON_NONE ||
        button > OURO_TERMINAL_MOUSE_BUTTON_ELEVEN ||
        (modifiers & ~OURO_TERMINAL_MOD_ALL) != 0 ||
        !valid_surface_position(x, y)) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    GhosttyMouseEncoder encoder = input->mouse_encoder;
    GhosttyMouseEncoder candidate = NULL;
    size_t gesture_index = 0;
    const bool concrete_button =
        button >= OURO_TERMINAL_MOUSE_BUTTON_LEFT &&
        button <= OURO_TERMINAL_MOUSE_BUTTON_ELEVEN;
    if (concrete_button) gesture_index = mouse_button_index(button);

    if (action == GHOSTTY_MOUSE_ACTION_PRESS && concrete_button && capacity != 0) {
        if (input->gesture_mouse_encoders[gesture_index] != NULL) {
            return OURO_TERMINAL_INVALID_ARGUMENT;
        }
        GhosttyResult result = new_latched_mouse_encoder(input, &candidate);
        if (result != GHOSTTY_SUCCESS) return map_result(result);
        encoder = candidate;
    } else if (action != GHOSTTY_MOUSE_ACTION_PRESS && concrete_button &&
               input->gesture_mouse_encoders[gesture_index] != NULL) {
        encoder = input->gesture_mouse_encoders[gesture_index];
    } else {
        OuroTerminalResult sync_result = sync_mouse_encoder(input);
        if (sync_result != OURO_TERMINAL_OK) return sync_result;
    }

    uint16_t prospective = input->pressed_buttons;
    if (update_pressed && button != OURO_TERMINAL_MOUSE_BUTTON_NONE) {
        const uint16_t bit = (uint16_t)(1u << (uint32_t)button);
        if (action == GHOSTTY_MOUSE_ACTION_PRESS) prospective |= bit;
        if (action == GHOSTTY_MOUSE_ACTION_RELEASE) prospective &= (uint16_t)~bit;
    }
    const bool any_button = prospective != 0;
    ghostty_mouse_encoder_setopt(
        encoder,
        GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED,
        &any_button);
    ghostty_mouse_event_set_action(input->mouse_event, action);
    if (button == OURO_TERMINAL_MOUSE_BUTTON_NONE) {
        ghostty_mouse_event_clear_button(input->mouse_event);
    } else {
        ghostty_mouse_event_set_button(
            input->mouse_event, (GhosttyMouseButton)button);
    }
    ghostty_mouse_event_set_mods(
        input->mouse_event, (GhosttyMods)modifiers);
    const GhosttyMousePosition position = {
        .x = (float)x,
        .y = (float)y,
    };
    ghostty_mouse_event_set_position(input->mouse_event, position);
    GhosttyResult result = ghostty_mouse_encoder_encode(
        encoder,
        input->mouse_event,
        (char *)buffer,
        capacity,
        out_length);
    if (result == GHOSTTY_SUCCESS && update_pressed) {
        input->pressed_buttons = prospective;
        if (action == GHOSTTY_MOUSE_ACTION_PRESS && candidate != NULL) {
            input->gesture_mouse_encoders[gesture_index] = candidate;
            candidate = NULL;
        } else if (action == GHOSTTY_MOUSE_ACTION_RELEASE && concrete_button &&
                   input->gesture_mouse_encoders[gesture_index] != NULL) {
            ghostty_mouse_encoder_free(
                input->gesture_mouse_encoders[gesture_index]);
            input->gesture_mouse_encoders[gesture_index] = NULL;
        }
    } else if (result != GHOSTTY_SUCCESS) {
        const bool previous_any_button = input->pressed_buttons != 0;
        ghostty_mouse_encoder_setopt(
            encoder,
            GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED,
            &previous_any_button);
    }
    ghostty_mouse_encoder_free(candidate);
    return map_result(result);
}

OuroTerminalResult ouro_terminal_input_encode_mouse(
    OuroTerminalInput *input,
    const OuroTerminalMouseEvent *event,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length) {
    if (input == NULL || event == NULL ||
        event->size != sizeof(*event) ||
        event->abi_version != OURO_TERMINAL_ENGINE_ABI_VERSION ||
        event->action < OURO_TERMINAL_MOUSE_PRESS ||
        event->action > OURO_TERMINAL_MOUSE_MOTION ||
        !valid_output_buffer(buffer, capacity, out_length) ||
        (event->action != OURO_TERMINAL_MOUSE_MOTION &&
         event->button == OURO_TERMINAL_MOUSE_BUTTON_NONE)) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    *out_length = 0;
    return encode_mouse_common(
        input,
        (GhosttyMouseAction)event->action,
        event->button,
        event->modifiers,
        event->x,
        event->y,
        true,
        buffer,
        capacity,
        out_length);
}

OuroTerminalResult ouro_terminal_input_encode_scroll(
    OuroTerminalInput *input,
    const OuroTerminalScrollEvent *event,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length) {
    if (input == NULL || event == NULL ||
        event->size != sizeof(*event) ||
        event->abi_version != OURO_TERMINAL_ENGINE_ABI_VERSION ||
        event->direction < OURO_TERMINAL_SCROLL_UP ||
        event->direction > OURO_TERMINAL_SCROLL_RIGHT ||
        !valid_output_buffer(buffer, capacity, out_length)) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    *out_length = 0;
    const OuroTerminalMouseButton buttons[] = {
        OURO_TERMINAL_MOUSE_BUTTON_FOUR,
        OURO_TERMINAL_MOUSE_BUTTON_FIVE,
        OURO_TERMINAL_MOUSE_BUTTON_SIX,
        OURO_TERMINAL_MOUSE_BUTTON_SEVEN,
    };
    return encode_mouse_common(
        input,
        GHOSTTY_MOUSE_ACTION_PRESS,
        buttons[event->direction],
        event->modifiers,
        event->x,
        event->y,
        false,
        buffer,
        capacity,
        out_length);
}

OuroTerminalResult ouro_terminal_input_reset_mouse(OuroTerminalInput *input) {
    if (input == NULL) return OURO_TERMINAL_INVALID_ARGUMENT;
    input->pressed_buttons = 0;
    input->mouse_modes_valid = false;
    ghostty_mouse_encoder_reset(input->mouse_encoder);
    for (size_t i = 0; i < 11; ++i) {
        ghostty_mouse_encoder_free(input->gesture_mouse_encoders[i]);
        input->gesture_mouse_encoders[i] = NULL;
    }
    const bool any_button = false;
    ghostty_mouse_encoder_setopt(
        input->mouse_encoder,
        GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED,
        &any_button);
    return OURO_TERMINAL_OK;
}

OuroTerminalResult ouro_terminal_input_paste_is_safe(
    OuroTerminalInput *input,
    const uint8_t *source,
    size_t source_length,
    bool *out_safe) {
    if (input == NULL || out_safe == NULL ||
        source_length > OURO_TERMINAL_MAX_PASTE_SOURCE_BYTES ||
        (source == NULL && source_length != 0)) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    bool carriage_return = false;
    for (size_t i = 0; i < source_length; ++i) {
        if (source[i] == '\r') {
            carriage_return = true;
            break;
        }
    }
    *out_safe = !carriage_return && ghostty_paste_is_safe(
        (const char *)source, source_length);
    return OURO_TERMINAL_OK;
}

OuroTerminalResult ouro_terminal_input_encode_paste(
    OuroTerminalInput *input,
    const uint8_t *source,
    size_t source_length,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length) {
    if (input == NULL || source_length > OURO_TERMINAL_MAX_PASTE_SOURCE_BYTES ||
        (source == NULL && source_length != 0) ||
        !valid_output_buffer(buffer, capacity, out_length)) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    *out_length = 0;
    bool bracketed = false;
    OuroTerminalResult mode_result = terminal_mode(
        input->terminal, GHOSTTY_MODE_BRACKETED_PASTE, &bracketed);
    if (mode_result != OURO_TERMINAL_OK) return mode_result;

    char *scratch = NULL;
    if (source_length != 0) {
        scratch = budget_alloc(
            &input->terminal->memory, source_length, 0, 0);
        if (scratch == NULL) return OURO_TERMINAL_OUT_OF_MEMORY;
        memcpy(scratch, source, source_length);
    }
    GhosttyResult result = ghostty_paste_encode(
        scratch,
        source_length,
        bracketed,
        (char *)buffer,
        capacity,
        out_length);
    if (scratch != NULL) {
        budget_free(
            &input->terminal->memory, scratch, source_length, 0, 0);
    }
    return map_result(result);
}

OuroTerminalResult ouro_terminal_input_encode_focus(
    OuroTerminalInput *input,
    bool focused,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length) {
    if (input == NULL || !valid_output_buffer(buffer, capacity, out_length)) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    *out_length = 0;
    bool enabled = false;
    OuroTerminalResult mode_result = terminal_mode(
        input->terminal, GHOSTTY_MODE_FOCUS_EVENT, &enabled);
    if (mode_result != OURO_TERMINAL_OK) return mode_result;
    if (!enabled) return OURO_TERMINAL_OK;
    return map_result(ghostty_focus_encode(
        focused ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST,
        (char *)buffer,
        capacity,
        out_length));
}

static bool valid_selection_config(
    const OuroTerminalSelectionConfig *config) {
    return config != NULL && config->size == sizeof(*config) &&
           config->abi_version == OURO_TERMINAL_ENGINE_ABI_VERSION &&
           config->copy_max_bytes > 0 &&
           isfinite(config->repeat_distance_px) &&
           config->repeat_distance_px >= 0.0 &&
           config->repeat_interval_ns > 0;
}

OuroTerminalResult ouro_terminal_selection_new(
    OuroTerminal *terminal,
    const OuroTerminalSelectionConfig *config,
    OuroTerminalSelection **out_selection) {
    if (terminal == NULL || !valid_selection_config(config) ||
        out_selection == NULL) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    *out_selection = NULL;
    OuroTerminalSelection *selection = calloc(1, sizeof(*selection));
    if (selection == NULL) return OURO_TERMINAL_OUT_OF_MEMORY;
    selection->terminal = terminal;
    selection->config = *config;
    GhosttyResult result = ghostty_selection_gesture_new(
        &terminal->allocator, &selection->gesture);
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_selection_gesture_event_new(
            &terminal->allocator,
            &selection->press,
            GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS);
    }
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_selection_gesture_event_new(
            &terminal->allocator,
            &selection->drag,
            GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG);
    }
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_selection_gesture_event_new(
            &terminal->allocator,
            &selection->autoscroll,
            GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK);
    }
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_selection_gesture_event_new(
            &terminal->allocator,
            &selection->release,
            GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE);
    }
    if (result != GHOSTTY_SUCCESS) {
        ghostty_selection_gesture_event_free(selection->release);
        ghostty_selection_gesture_event_free(selection->autoscroll);
        ghostty_selection_gesture_event_free(selection->drag);
        ghostty_selection_gesture_event_free(selection->press);
        ghostty_selection_gesture_free(
            selection->gesture, terminal->terminal);
        free(selection);
        return map_result(result);
    }
    *out_selection = selection;
    return OURO_TERMINAL_OK;
}

void ouro_terminal_selection_free(OuroTerminalSelection *selection) {
    if (selection == NULL) return;
    ghostty_selection_gesture_event_free(selection->release);
    ghostty_selection_gesture_event_free(selection->autoscroll);
    ghostty_selection_gesture_event_free(selection->drag);
    ghostty_selection_gesture_event_free(selection->press);
    ghostty_selection_gesture_free(
        selection->gesture, selection->terminal->terminal);
    free(selection);
}

static bool valid_selection_point(
    const OuroTerminalSelectionPoint *point) {
    return point != NULL && point->size == sizeof(*point) &&
           point->abi_version == OURO_TERMINAL_ENGINE_ABI_VERSION &&
           isfinite(point->surface_x) && isfinite(point->surface_y);
}

static bool valid_selection_geometry(
    const OuroTerminalSelectionGeometry *geometry,
    GhosttySelectionGestureGeometry *out) {
    if (geometry == NULL || geometry->size != sizeof(*geometry) ||
        geometry->abi_version != OURO_TERMINAL_ENGINE_ABI_VERSION ||
        geometry->columns == 0) {
        return false;
    }
    uint32_t cell_width = 0;
    uint32_t padding_left = 0;
    uint32_t screen_height = 0;
    if (!double_to_u32(geometry->cell_width, false, &cell_width) ||
        !double_to_u32(geometry->padding_left, true, &padding_left) ||
        !double_to_u32(geometry->screen_height, false, &screen_height)) {
        return false;
    }
    *out = (GhosttySelectionGestureGeometry){
        .columns = geometry->columns,
        .cell_width = cell_width,
        .padding_left = padding_left,
        .screen_height = screen_height,
    };
    return true;
}

static OuroTerminalResult selection_grid_ref(
    OuroTerminalSelection *selection,
    uint16_t column,
    uint32_t row,
    GhosttyGridRef *out_ref) {
    const GhosttyPoint point = {
        .tag = GHOSTTY_POINT_TAG_VIEWPORT,
        .value = {.coordinate = {.x = column, .y = row}},
    };
    *out_ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
    return map_result(ghostty_terminal_grid_ref(
        selection->terminal->terminal, point, out_ref));
}

static OuroTerminalResult install_selection(
    OuroTerminalSelection *owner,
    const GhosttySelection *selection) {
    return map_result(ghostty_terminal_set(
        owner->terminal->terminal,
        GHOSTTY_TERMINAL_OPT_SELECTION,
        selection));
}

static OuroTerminalResult set_selection_point_options(
    OuroTerminalSelection *selection,
    GhosttySelectionGestureEvent event,
    const OuroTerminalSelectionPoint *point,
    bool press) {
    GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
    OuroTerminalResult result = selection_grid_ref(
        selection, point->column, point->row, &ref);
    if (result != OURO_TERMINAL_OK) return result;
    GhosttyResult ghostty_result = ghostty_selection_gesture_event_set(
        event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref);
    const GhosttySurfacePosition position = {
        .x = point->surface_x,
        .y = point->surface_y,
    };
    if (ghostty_result == GHOSTTY_SUCCESS) {
        ghostty_result = ghostty_selection_gesture_event_set(
            event,
            GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION,
            &position);
    }
    if (ghostty_result == GHOSTTY_SUCCESS && press) {
        ghostty_result = ghostty_selection_gesture_event_set(
            event,
            GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE,
            &selection->config.repeat_distance_px);
    }
    if (ghostty_result == GHOSTTY_SUCCESS && press) {
        ghostty_result = ghostty_selection_gesture_event_set(
            event,
            GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS,
            &selection->config.repeat_interval_ns);
    }
    if (ghostty_result == GHOSTTY_SUCCESS && press) {
        ghostty_result = ghostty_selection_gesture_event_set(
            event,
            GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS,
            point->has_time ? &point->time_ns : NULL);
    }
    return map_result(ghostty_result);
}

static OuroTerminalResult apply_gesture_selection(
    OuroTerminalSelection *selection,
    GhosttySelectionGestureEvent event) {
    GhosttySelection snapshot = GHOSTTY_INIT_SIZED(GhosttySelection);
    GhosttyResult result = ghostty_selection_gesture_event(
        selection->gesture,
        selection->terminal->terminal,
        event,
        &snapshot);
    if (result != GHOSTTY_SUCCESS) return map_result(result);
    return install_selection(selection, &snapshot);
}

OuroTerminalResult ouro_terminal_selection_begin(
    OuroTerminalSelection *selection,
    const OuroTerminalSelectionPoint *point) {
    if (selection == NULL || !valid_selection_point(point)) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    /* Configure the already allocated gesture before replacing the terminal's
     * visible selection. Clearing first made an invalid/OOM press destroy a
     * perfectly valid prior selection even though the new gesture never
     * committed. apply_gesture_selection installs the replacement only after
     * Ghostty has produced a complete snapshot. */
    OuroTerminalResult result = set_selection_point_options(
        selection, selection->press, point, true);
    if (result != OURO_TERMINAL_OK) {
        ghostty_selection_gesture_reset(
            selection->gesture, selection->terminal->terminal);
        return result;
    }
    return apply_gesture_selection(selection, selection->press);
}

OuroTerminalResult ouro_terminal_selection_update(
    OuroTerminalSelection *selection,
    const OuroTerminalSelectionPoint *point,
    const OuroTerminalSelectionGeometry *geometry,
    bool rectangle) {
    GhosttySelectionGestureGeometry ghostty_geometry;
    if (selection == NULL || !valid_selection_point(point) ||
        !valid_selection_geometry(geometry, &ghostty_geometry)) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    OuroTerminalResult result = set_selection_point_options(
        selection, selection->drag, point, false);
    if (result != OURO_TERMINAL_OK) return result;
    GhosttyResult ghostty_result = ghostty_selection_gesture_event_set(
        selection->drag,
        GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY,
        &ghostty_geometry);
    if (ghostty_result == GHOSTTY_SUCCESS) {
        ghostty_result = ghostty_selection_gesture_event_set(
            selection->drag,
            GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE,
            &rectangle);
    }
    if (ghostty_result != GHOSTTY_SUCCESS) return map_result(ghostty_result);
    return apply_gesture_selection(selection, selection->drag);
}

OuroTerminalResult ouro_terminal_selection_autoscroll(
    OuroTerminalSelection *selection,
    uint16_t viewport_column,
    uint32_t viewport_row,
    double surface_x,
    double surface_y,
    const OuroTerminalSelectionGeometry *geometry,
    bool rectangle,
    OuroTerminalSelectionAutoscroll *out_direction) {
    GhosttySelectionGestureGeometry ghostty_geometry;
    if (selection == NULL || out_direction == NULL ||
        !isfinite(surface_x) || !isfinite(surface_y) ||
        !valid_selection_geometry(geometry, &ghostty_geometry)) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    const GhosttyPointCoordinate viewport = {
        .x = viewport_column,
        .y = viewport_row,
    };
    const GhosttySurfacePosition position = {
        .x = surface_x,
        .y = surface_y,
    };
    GhosttyResult ghostty_result = ghostty_selection_gesture_event_set(
        selection->autoscroll,
        GHOSTTY_SELECTION_GESTURE_EVENT_OPT_VIEWPORT,
        &viewport);
    if (ghostty_result == GHOSTTY_SUCCESS) {
        ghostty_result = ghostty_selection_gesture_event_set(
            selection->autoscroll,
            GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION,
            &position);
    }
    if (ghostty_result == GHOSTTY_SUCCESS) {
        ghostty_result = ghostty_selection_gesture_event_set(
            selection->autoscroll,
            GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY,
            &ghostty_geometry);
    }
    if (ghostty_result == GHOSTTY_SUCCESS) {
        ghostty_result = ghostty_selection_gesture_event_set(
            selection->autoscroll,
            GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE,
            &rectangle);
    }
    if (ghostty_result != GHOSTTY_SUCCESS) return map_result(ghostty_result);

    OuroTerminalResult result = apply_gesture_selection(
        selection, selection->autoscroll);
    if (result != OURO_TERMINAL_OK && result != OURO_TERMINAL_NO_VALUE) {
        return result;
    }
    GhosttySelectionGestureAutoscroll direction =
        GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE;
    ghostty_result = ghostty_selection_gesture_get(
        selection->gesture,
        selection->terminal->terminal,
        GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL,
        &direction);
    if (ghostty_result != GHOSTTY_SUCCESS) return map_result(ghostty_result);
    *out_direction = (OuroTerminalSelectionAutoscroll)direction;
    return result;
}

OuroTerminalResult ouro_terminal_selection_end(
    OuroTerminalSelection *selection,
    const OuroTerminalSelectionPoint *point) {
    if (selection == NULL || (point != NULL && !valid_selection_point(point))) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    GhosttyResult ghostty_result;
    if (point == NULL) {
        ghostty_result = ghostty_selection_gesture_event_set(
            selection->release,
            GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF,
            NULL);
    } else {
        GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
        OuroTerminalResult result = selection_grid_ref(
            selection, point->column, point->row, &ref);
        if (result != OURO_TERMINAL_OK) return result;
        ghostty_result = ghostty_selection_gesture_event_set(
            selection->release,
            GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF,
            &ref);
    }
    if (ghostty_result != GHOSTTY_SUCCESS) return map_result(ghostty_result);
    return map_result(ghostty_selection_gesture_event(
        selection->gesture,
        selection->terminal->terminal,
        selection->release,
        NULL));
}

OuroTerminalResult ouro_terminal_selection_cancel(
    OuroTerminalSelection *selection) {
    if (selection == NULL) return OURO_TERMINAL_INVALID_ARGUMENT;
    ghostty_selection_gesture_reset(
        selection->gesture, selection->terminal->terminal);
    return install_selection(selection, NULL);
}

OuroTerminalResult ouro_terminal_selection_copy(
    OuroTerminalSelection *selection,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length) {
    if (selection == NULL ||
        !valid_output_buffer(buffer, capacity, out_length)) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    *out_length = 0;
    GhosttyTerminalSelectionFormatOptions options =
        GHOSTTY_INIT_SIZED(GhosttyTerminalSelectionFormatOptions);
    options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
    options.unwrap = true;
    options.trim = true;
    options.selection = NULL;
    size_t required = 0;
    GhosttyResult result = ghostty_terminal_selection_format_buf(
        selection->terminal->terminal,
        options,
        NULL,
        0,
        &required);
    if (result == GHOSTTY_NO_VALUE) return OURO_TERMINAL_NO_VALUE;
    if (result != GHOSTTY_OUT_OF_SPACE && result != GHOSTTY_SUCCESS) {
        return map_result(result);
    }
    *out_length = required;
    if (required > selection->config.copy_max_bytes || capacity < required) {
        return OURO_TERMINAL_BUFFER_TOO_SMALL;
    }
    if (required == 0) return OURO_TERMINAL_OK;
    return map_result(ghostty_terminal_selection_format_buf(
        selection->terminal->terminal,
        options,
        buffer,
        capacity,
        out_length));
}

OuroTerminalResult ouro_terminal_frame_info(
    OuroTerminal *terminal,
    OuroTerminalFrameInfo *out_info) {
    if (terminal == NULL || out_info == NULL ||
        out_info->size != sizeof(*out_info) ||
        out_info->abi_version != OURO_TERMINAL_ENGINE_ABI_VERSION) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }

    GhosttyRenderState state = NULL;
    GhosttyResult result = ghostty_render_state_new(
        &terminal->allocator, &state);
    if (result != GHOSTTY_SUCCESS) return map_result(result);
    result = ghostty_render_state_update(state, terminal->terminal);
    if (result != GHOSTTY_SUCCESS) {
        ghostty_render_state_free(state);
        return map_result(result);
    }

    GhosttyRenderStateDirty dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
    uint16_t columns = 0;
    uint16_t rows = 0;
    uint16_t cursor_x = 0;
    uint16_t cursor_y = 0;
    bool cursor_has_value = false;

    result = ghostty_render_state_get(
        state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty);
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_render_state_get(
            state, GHOSTTY_RENDER_STATE_DATA_COLS, &columns);
    }
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_render_state_get(
            state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows);
    }
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_render_state_get(
            state,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE,
            &cursor_has_value);
    }
    if (result == GHOSTTY_SUCCESS && cursor_has_value) {
        result = ghostty_render_state_get(
            state,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X,
            &cursor_x);
    }
    if (result == GHOSTTY_SUCCESS && cursor_has_value) {
        result = ghostty_render_state_get(
            state,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y,
            &cursor_y);
    }
    if (result != GHOSTTY_SUCCESS) {
        ghostty_render_state_free(state);
        return map_result(result);
    }

    out_info->columns = columns;
    out_info->rows = rows;
    out_info->cursor_x = cursor_x;
    out_info->cursor_y = cursor_y;
    switch (dirty) {
        case GHOSTTY_RENDER_STATE_DIRTY_FALSE:
            out_info->dirty = OURO_TERMINAL_DIRTY_NONE;
            break;
        case GHOSTTY_RENDER_STATE_DIRTY_PARTIAL:
            out_info->dirty = OURO_TERMINAL_DIRTY_PARTIAL;
            break;
        case GHOSTTY_RENDER_STATE_DIRTY_FULL:
            out_info->dirty = OURO_TERMINAL_DIRTY_FULL;
            break;
        default:
            ghostty_render_state_free(state);
            return OURO_TERMINAL_ENGINE_ERROR;
    }
    ghostty_render_state_free(state);
    return OURO_TERMINAL_OK;
}

static OuroRenderRgb render_rgb(GhosttyColorRgb color) {
    return (OuroRenderRgb){.r = color.r, .g = color.g, .b = color.b};
}

static OuroRenderColor render_style_color(GhosttyStyleColor color) {
    OuroRenderColor result = {.kind = OURO_RENDER_COLOR_DEFAULT};
    switch (color.tag) {
        case GHOSTTY_STYLE_COLOR_NONE:
            break;
        case GHOSTTY_STYLE_COLOR_PALETTE:
            result.kind = OURO_RENDER_COLOR_PALETTE;
            result.palette_index = color.value.palette;
            break;
        case GHOSTTY_STYLE_COLOR_RGB:
            result.kind = OURO_RENDER_COLOR_RGB;
            result.rgb = render_rgb(color.value.rgb);
            break;
        default:
            result.kind = OURO_RENDER_COLOR_DEFAULT;
            break;
    }
    return result;
}

static OuroTerminalResult render_dirty(
    GhosttyRenderStateDirty dirty,
    OuroTerminalDirty *out) {
    switch (dirty) {
        case GHOSTTY_RENDER_STATE_DIRTY_FALSE:
            *out = OURO_TERMINAL_DIRTY_NONE;
            return OURO_TERMINAL_OK;
        case GHOSTTY_RENDER_STATE_DIRTY_PARTIAL:
            *out = OURO_TERMINAL_DIRTY_PARTIAL;
            return OURO_TERMINAL_OK;
        case GHOSTTY_RENDER_STATE_DIRTY_FULL:
            *out = OURO_TERMINAL_DIRTY_FULL;
            return OURO_TERMINAL_OK;
        default:
            return OURO_TERMINAL_ENGINE_ERROR;
    }
}

OuroTerminalResult ouro_terminal_set_selection(
    OuroTerminal *terminal,
    uint16_t start_x,
    uint16_t start_y,
    uint16_t end_x,
    uint16_t end_y,
    bool rectangle) {
    if (terminal == NULL) return OURO_TERMINAL_INVALID_ARGUMENT;
    GhosttyPoint start_point = {
        .tag = GHOSTTY_POINT_TAG_VIEWPORT,
        .value.coordinate = {.x = start_x, .y = start_y},
    };
    GhosttyPoint end_point = {
        .tag = GHOSTTY_POINT_TAG_VIEWPORT,
        .value.coordinate = {.x = end_x, .y = end_y},
    };
    GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
    GhosttyResult result = ghostty_terminal_grid_ref(
        terminal->terminal, start_point, &selection.start);
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_terminal_grid_ref(
            terminal->terminal, end_point, &selection.end);
    }
    if (result != GHOSTTY_SUCCESS) return map_result(result);
    selection.rectangle = rectangle;
    return map_result(ghostty_terminal_set(
        terminal->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection));
}

OuroTerminalResult ouro_terminal_clear_selection(OuroTerminal *terminal) {
    if (terminal == NULL) return OURO_TERMINAL_INVALID_ARGUMENT;
    return map_result(ghostty_terminal_set(
        terminal->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, NULL));
}

static bool valid_render_projection_config(
    const OuroRenderProjectionConfig *config) {
    return config != NULL && config->size == sizeof(*config) &&
           config->abi_version == OURO_TERMINAL_ENGINE_ABI_VERSION &&
           config->memory_max_bytes > 0 && config->max_grapheme_bytes > 0 &&
           config->max_grapheme_bytes <= OURO_RENDER_MAX_GRAPHEME_BYTES;
}

static void free_render_resources(OuroRenderResources *resources) {
    if (resources == NULL) return;
    ghostty_render_state_row_cells_free(resources->cells);
    ghostty_render_state_row_iterator_free(resources->rows);
    ghostty_render_state_free(resources->state);
    free(resources);
}

static OuroTerminalResult new_render_resources(
    GhosttyAllocator *allocator,
    OuroRenderResources **out_resources) {
    *out_resources = NULL;
    OuroRenderResources *resources = calloc(1, sizeof(*resources));
    if (resources == NULL) return OURO_TERMINAL_OUT_OF_MEMORY;
    GhosttyResult result = ghostty_render_state_new(
        allocator, &resources->state);
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_render_state_row_iterator_new(
            allocator, &resources->rows);
    }
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_render_state_row_cells_new(
            allocator, &resources->cells);
    }
    if (result != GHOSTTY_SUCCESS) {
        free_render_resources(resources);
        return map_result(result);
    }
    *out_resources = resources;
    return OURO_TERMINAL_OK;
}

OuroTerminalResult ouro_render_projection_new(
    OuroTerminal *terminal,
    const OuroRenderProjectionConfig *config,
    OuroRenderProjection **out_projection) {
    if (terminal == NULL || !valid_render_projection_config(config) ||
        out_projection == NULL) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    *out_projection = NULL;
    OuroRenderProjection *projection = calloc(1, sizeof(*projection));
    if (projection == NULL) return OURO_TERMINAL_OUT_OF_MEMORY;
    projection->terminal = terminal;
    projection->config = *config;
    projection->memory.limit_bytes = config->memory_max_bytes;
    projection->allocator.ctx = &projection->memory;
    projection->allocator.vtable = &budget_allocator_vtable;
    OuroTerminalResult result = new_render_resources(
        &projection->allocator, &projection->resources);
    if (result != OURO_TERMINAL_OK) {
        if (projection->memory.live_bytes != 0 ||
            projection->memory.physical_usable_bytes != 0) {
            abort();
        }
        free(projection);
        return result;
    }
    *out_projection = projection;
    return OURO_TERMINAL_OK;
}

static void retain_projection_invalidation(OuroRenderProjection *projection) {
    GhosttyRenderStateDirty dirty = GHOSTTY_RENDER_STATE_DIRTY_FULL;
    (void)ghostty_render_state_set(
        projection->resources->state,
        GHOSTTY_RENDER_STATE_OPTION_DIRTY,
        &dirty);
}

void ouro_render_projection_free(OuroRenderProjection *projection) {
    if (projection == NULL) return;
    if (projection->active_frame != NULL) {
        retain_projection_invalidation(projection);
        free(projection->active_frame);
    }
    free_render_resources(projection->resources);
    if (projection->memory.live_bytes != 0 ||
        projection->memory.physical_usable_bytes != 0) {
        abort();
    }
    free(projection);
}

OuroTerminalResult ouro_render_projection_rebind(
    OuroRenderProjection *projection,
    OuroTerminal *terminal) {
    if (projection == NULL || terminal == NULL ||
        projection->active_frame != NULL) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    if (projection->terminal == terminal) {
        retain_projection_invalidation(projection);
        return OURO_TERMINAL_OK;
    }

    OuroRenderResources *candidate = NULL;
    OuroTerminalResult result = new_render_resources(
        &projection->allocator, &candidate);
    if (result != OURO_TERMINAL_OK) return result;
    GhosttyResult engine_result = ghostty_render_state_update(
        candidate->state, terminal->terminal);
    if (engine_result == GHOSTTY_SUCCESS) {
        const GhosttyRenderStateDirty full = GHOSTTY_RENDER_STATE_DIRTY_FULL;
        engine_result = ghostty_render_state_set(
            candidate->state, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &full);
    }
    if (engine_result != GHOSTTY_SUCCESS) {
        free_render_resources(candidate);
        return map_result(engine_result);
    }

    OuroRenderResources *old = projection->resources;
    projection->resources = candidate;
    projection->terminal = terminal;
    free_render_resources(old);
    return OURO_TERMINAL_OK;
}

OuroTerminalResult ouro_render_projection_memory_info(
    OuroRenderProjection *projection,
    OuroRenderProjectionMemoryInfo *out_info) {
    if (projection == NULL || out_info == NULL ||
        out_info->size != sizeof(*out_info) ||
        out_info->abi_version != OURO_TERMINAL_ENGINE_ABI_VERSION) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    const OuroMemoryBudget *memory = &projection->memory;
    out_info->live_bytes = memory->live_bytes;
    out_info->peak_bytes = memory->peak_bytes;
    out_info->limit_bytes = memory->limit_bytes;
    out_info->allocation_failures = memory->allocation_failures;
    return OURO_TERMINAL_OK;
}

OuroTerminalResult ouro_render_projection_begin(
    OuroRenderProjection *projection,
    OuroRenderFrame **out_frame) {
    if (projection == NULL || out_frame == NULL ||
        projection->active_frame != NULL) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    *out_frame = NULL;
    GhosttyResult result = ghostty_render_state_update(
        projection->resources->state, projection->terminal->terminal);
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_render_state_get(
            projection->resources->state,
            GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
            &projection->resources->rows);
    }
    if (result != GHOSTTY_SUCCESS) return map_result(result);

    OuroRenderFrame *frame = calloc(1, sizeof(*frame));
    if (frame == NULL) {
        retain_projection_invalidation(projection);
        return OURO_TERMINAL_OUT_OF_MEMORY;
    }
    projection->generation++;
    if (projection->generation == 0) projection->generation = 1;
    frame->projection = projection;
    frame->fully_drained = true;
    projection->active_frame = frame;
    *out_frame = frame;
    return OURO_TERMINAL_OK;
}

OuroTerminalResult ouro_render_projection_force_full(
    OuroRenderProjection *projection) {
    if (projection == NULL || projection->active_frame != NULL) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    retain_projection_invalidation(projection);
    return OURO_TERMINAL_OK;
}

OuroTerminalResult ouro_render_frame_info(
    OuroRenderFrame *frame,
    OuroRenderFrameInfo *out_info) {
    if (frame == NULL || out_info == NULL ||
        out_info->size != sizeof(*out_info) ||
        out_info->abi_version != OURO_TERMINAL_ENGINE_ABI_VERSION) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    OuroRenderProjection *projection = frame->projection;
    GhosttyRenderState state = projection->resources->state;
    GhosttyRenderStateDirty dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
    GhosttyRenderStateCursorVisualStyle cursor_style =
        GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
    GhosttyRenderStateColors colors =
        GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
    GhosttyResult result = ghostty_render_state_get(
        state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty);
#define GET_RENDER_FIELD(key, field) \
    if (result == GHOSTTY_SUCCESS) result = ghostty_render_state_get(state, key, field)
    GET_RENDER_FIELD(GHOSTTY_RENDER_STATE_DATA_COLS, &out_info->columns);
    GET_RENDER_FIELD(GHOSTTY_RENDER_STATE_DATA_ROWS, &out_info->rows);
    GET_RENDER_FIELD(
        GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE,
        &out_info->cursor_has_value);
    if (result == GHOSTTY_SUCCESS && out_info->cursor_has_value) {
        GET_RENDER_FIELD(
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X,
            &out_info->cursor_x);
        GET_RENDER_FIELD(
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y,
            &out_info->cursor_y);
        GET_RENDER_FIELD(
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_WIDE_TAIL,
            &out_info->cursor_wide_tail);
    } else {
        out_info->cursor_x = 0;
        out_info->cursor_y = 0;
        out_info->cursor_wide_tail = false;
    }
    GET_RENDER_FIELD(
        GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE,
        &out_info->cursor_visible);
    GET_RENDER_FIELD(
        GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING,
        &out_info->cursor_blinking);
    GET_RENDER_FIELD(
        GHOSTTY_RENDER_STATE_DATA_CURSOR_PASSWORD_INPUT,
        &out_info->cursor_password_input);
    GET_RENDER_FIELD(
        GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE,
        &cursor_style);
#undef GET_RENDER_FIELD
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_render_state_colors_get(state, &colors);
    }
    if (result != GHOSTTY_SUCCESS) return map_result(result);
    OuroTerminalResult dirty_result = render_dirty(dirty, &out_info->dirty);
    if (dirty_result != OURO_TERMINAL_OK) return dirty_result;
    out_info->generation = projection->generation;
    out_info->cursor_style = (OuroRenderCursorStyle)cursor_style;
    out_info->background = render_rgb(colors.background);
    out_info->foreground = render_rgb(colors.foreground);
    out_info->cursor_color_has_value = colors.cursor_has_value;
    if (colors.cursor_has_value) {
        out_info->cursor_color = render_rgb(colors.cursor);
    } else {
        out_info->cursor_color = (OuroRenderRgb){0};
    }
    for (size_t i = 0; i < 256; ++i) {
        out_info->palette[i] = render_rgb(colors.palette[i]);
    }
    return OURO_TERMINAL_OK;
}

OuroTerminalResult ouro_render_frame_next_row(
    OuroRenderFrame *frame,
    OuroRenderRowInfo *out_row,
    bool *out_has_row) {
    if (frame == NULL || out_row == NULL || out_has_row == NULL ||
        out_row->size != sizeof(*out_row) ||
        out_row->abi_version != OURO_TERMINAL_ENGINE_ABI_VERSION) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    if (frame->row_active && !frame->row_drained) {
        frame->fully_drained = false;
    }
    frame->row_active = false;
    frame->cell_ready = false;
    if (!ghostty_render_state_row_iterator_next(
            frame->projection->resources->rows)) {
        *out_has_row = false;
        frame->row_drained = true;
        frame->rows_exhausted = true;
        return OURO_TERMINAL_OK;
    }

    GhosttyRow raw = 0;
    bool dirty = false;
    GhosttyRenderStateRowSelection selection =
        GHOSTTY_INIT_SIZED(GhosttyRenderStateRowSelection);
    GhosttyResult result = ghostty_render_state_row_get(
        frame->projection->resources->rows,
        GHOSTTY_RENDER_STATE_ROW_DATA_RAW,
        &raw);
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_render_state_row_get(
            frame->projection->resources->rows,
            GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY,
            &dirty);
    }
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_render_state_row_get(
            frame->projection->resources->rows,
            GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
            &frame->projection->resources->cells);
    }
    if (result != GHOSTTY_SUCCESS) return map_result(result);

    out_row->y = frame->row_y++;
    out_row->dirty = dirty;
    result = ghostty_render_state_row_get(
        frame->projection->resources->rows,
        GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION,
        &selection);
    if (result == GHOSTTY_SUCCESS) {
        out_row->selection_has_value = true;
        out_row->selection_start_x = selection.start_x;
        out_row->selection_end_x = selection.end_x;
    } else if (result == GHOSTTY_NO_VALUE) {
        out_row->selection_has_value = false;
        out_row->selection_start_x = 0;
        out_row->selection_end_x = 0;
    } else {
        return map_result(result);
    }
    GhosttyRowSemanticPrompt semantic = GHOSTTY_ROW_SEMANTIC_NONE;
    result = ghostty_row_get(raw, GHOSTTY_ROW_DATA_WRAP, &out_row->wrap);
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_row_get(
            raw, GHOSTTY_ROW_DATA_WRAP_CONTINUATION, &out_row->wrap_continuation);
    }
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_row_get(raw, GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, &semantic);
    }
    if (result != GHOSTTY_SUCCESS) return map_result(result);
    out_row->semantic = (OuroRenderRowSemantic)semantic;
    frame->row_active = true;
    frame->row_drained = false;
    frame->cell_x = 0;
    *out_has_row = true;
    return OURO_TERMINAL_OK;
}

OuroTerminalResult ouro_render_frame_next_cell(
    OuroRenderFrame *frame,
    uint8_t *grapheme_buffer,
    size_t grapheme_capacity,
    OuroRenderCellInfo *out_cell,
    bool *out_has_cell) {
    if (frame == NULL || out_cell == NULL || out_has_cell == NULL ||
        !frame->row_active ||
        (grapheme_buffer == NULL && grapheme_capacity != 0) ||
        grapheme_capacity > frame->projection->config.max_grapheme_bytes ||
        out_cell->size != sizeof(*out_cell) ||
        out_cell->abi_version != OURO_TERMINAL_ENGINE_ABI_VERSION) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    if (!frame->cell_ready) {
        if (!ghostty_render_state_row_cells_next(
                frame->projection->resources->cells)) {
            frame->row_drained = true;
            frame->row_active = false;
            *out_has_cell = false;
            return OURO_TERMINAL_OK;
        }
        frame->cell_ready = true;
    }

    GhosttyCell raw = 0;
    GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
    GhosttyCellContentTag content_tag = GHOSTTY_CELL_CONTENT_CODEPOINT;
    GhosttyCellSemanticContent semantic = GHOSTTY_CELL_SEMANTIC_OUTPUT;
    GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
    GhosttyResult result = ghostty_render_state_row_cells_get(
        frame->projection->resources->cells,
        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
        &raw);
#define GET_CELL_FIELD(key, field) \
    if (result == GHOSTTY_SUCCESS) result = ghostty_render_state_row_cells_get( \
        frame->projection->resources->cells, key, field)
    GET_CELL_FIELD(GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);
    GET_CELL_FIELD(
        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED,
        &out_cell->selected);
    GET_CELL_FIELD(
        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING,
        &out_cell->has_styling);
#undef GET_CELL_FIELD
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide);
    }
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_cell_get(
            raw, GHOSTTY_CELL_DATA_CONTENT_TAG, &content_tag);
    }
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_cell_get(
            raw, GHOSTTY_CELL_DATA_HAS_HYPERLINK, &out_cell->has_hyperlink);
    }
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_cell_get(
            raw, GHOSTTY_CELL_DATA_SEMANTIC_CONTENT, &semantic);
    }
    if (result != GHOSTTY_SUCCESS) return map_result(result);

    out_cell->x = frame->cell_x;
    out_cell->width = wide == GHOSTTY_CELL_WIDE_WIDE ? 2 :
        (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL ? 0 : 1);
    out_cell->semantic = (OuroRenderCellSemantic)semantic;
    out_cell->foreground = render_style_color(style.fg_color);
    out_cell->foreground_has_value =
        out_cell->foreground.kind != OURO_RENDER_COLOR_DEFAULT;
    out_cell->background = render_style_color(style.bg_color);
    if (content_tag == GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE) {
        out_cell->background.kind = OURO_RENDER_COLOR_PALETTE;
        result = ghostty_cell_get(
            raw,
            GHOSTTY_CELL_DATA_COLOR_PALETTE,
            &out_cell->background.palette_index);
    } else if (content_tag == GHOSTTY_CELL_CONTENT_BG_COLOR_RGB) {
        GhosttyColorRgb rgb = {0};
        out_cell->background.kind = OURO_RENDER_COLOR_RGB;
        result = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_COLOR_RGB, &rgb);
        out_cell->background.rgb = render_rgb(rgb);
    }
    if (result != GHOSTTY_SUCCESS) return map_result(result);
    out_cell->background_has_value =
        out_cell->background.kind != OURO_RENDER_COLOR_DEFAULT;
    out_cell->underline_color = render_style_color(style.underline_color);
    out_cell->underline_color_has_value =
        out_cell->underline_color.kind != OURO_RENDER_COLOR_DEFAULT;
    out_cell->bold = style.bold;
    out_cell->italic = style.italic;
    out_cell->faint = style.faint;
    out_cell->blink = style.blink;
    out_cell->inverse = style.inverse;
    out_cell->invisible = style.invisible;
    out_cell->strikethrough = style.strikethrough;
    out_cell->overline = style.overline;
    out_cell->underline = style.underline;

    GhosttyBuffer buffer = {
        .ptr = grapheme_buffer,
        .cap = grapheme_capacity,
        .len = 0,
    };
    result = ghostty_render_state_row_cells_get(
        frame->projection->resources->cells,
        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,
        &buffer);
    out_cell->grapheme_bytes = buffer.len;
    *out_has_cell = true;
    if (result == GHOSTTY_OUT_OF_SPACE) {
        if (buffer.len <= grapheme_capacity) {
            return OURO_TERMINAL_ENGINE_ERROR;
        }
        return OURO_TERMINAL_BUFFER_TOO_SMALL;
    }
    if (result != GHOSTTY_SUCCESS) return map_result(result);
    frame->cell_ready = false;
    frame->cell_x++;
    return OURO_TERMINAL_OK;
}

static OuroTerminalResult clear_projection_dirty(
    OuroRenderProjection *projection) {
    GhosttyResult result = ghostty_render_state_get(
        projection->resources->state,
        GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
        &projection->resources->rows);
    const bool clean = false;
    while (result == GHOSTTY_SUCCESS &&
           ghostty_render_state_row_iterator_next(
               projection->resources->rows)) {
        result = ghostty_render_state_row_set(
            projection->resources->rows,
            GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY,
            &clean);
    }
    if (result == GHOSTTY_SUCCESS) {
        const GhosttyRenderStateDirty dirty =
            GHOSTTY_RENDER_STATE_DIRTY_FALSE;
        result = ghostty_render_state_set(
            projection->resources->state,
            GHOSTTY_RENDER_STATE_OPTION_DIRTY,
            &dirty);
    }
    return map_result(result);
}

OuroTerminalResult ouro_render_frame_end(
    OuroRenderFrame *frame,
    OuroRenderFrameDisposition disposition) {
    if (frame == NULL || frame->projection == NULL ||
        frame->projection->active_frame != frame ||
        (disposition != OURO_RENDER_FRAME_COMMITTED &&
         disposition != OURO_RENDER_FRAME_DROPPED)) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    OuroRenderProjection *projection = frame->projection;
    OuroTerminalResult result = OURO_TERMINAL_OK;
    if (disposition == OURO_RENDER_FRAME_COMMITTED) {
        if (!frame->fully_drained || !frame->row_drained ||
            !frame->rows_exhausted) {
            retain_projection_invalidation(projection);
            result = OURO_TERMINAL_INVALID_ARGUMENT;
        } else {
            result = clear_projection_dirty(projection);
            if (result != OURO_TERMINAL_OK) {
                retain_projection_invalidation(projection);
            }
        }
    } else {
        retain_projection_invalidation(projection);
    }
    projection->active_frame = NULL;
    free(frame);
    return result;
}

OuroTerminalResult ouro_terminal_memory_info(
    OuroTerminal *terminal,
    OuroTerminalMemoryInfo *out_info) {
    if (terminal == NULL || out_info == NULL ||
        out_info->size != sizeof(*out_info) ||
        out_info->abi_version != OURO_TERMINAL_ENGINE_ABI_VERSION) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }

    out_info->live_bytes = terminal->memory.live_bytes;
    out_info->peak_bytes = terminal->memory.peak_bytes;
    out_info->limit_bytes = terminal->memory.limit_bytes;
    out_info->allocation_failures = terminal->memory.allocation_failures;
    return OURO_TERMINAL_OK;
}

OuroTerminalResult ouro_terminal_compression_activity(
    OuroTerminal *terminal,
    uint64_t *out_activity) {
    if (terminal == NULL || out_activity == NULL) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    return map_result(ghostty_terminal_compression_activity(
        terminal->terminal, out_activity));
}

static OuroTerminalResult compress_terminal(
    OuroTerminal *terminal,
    GhosttyTerminalCompressionMode mode,
    OuroTerminalCompressionResult *out_result) {
    if (terminal == NULL || out_result == NULL) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }

    GhosttyTerminalCompressionResult engine_result =
        GHOSTTY_TERMINAL_COMPRESSION_RESULT_UNSUPPORTED;
    size_t page_epoch_before = 0;
    OuroTerminalResult result = page_failure_epoch(
        terminal, &page_epoch_before);
    if (result != OURO_TERMINAL_OK) return result;
    GhosttyResult engine_status = ghostty_terminal_compress(
        terminal->terminal, mode, &engine_result);
    result = finish_page_observed_operation(
        terminal, page_epoch_before, engine_status);
    if (result != OURO_TERMINAL_OK) return result;

    switch (engine_result) {
        case GHOSTTY_TERMINAL_COMPRESSION_RESULT_UNSUPPORTED:
            *out_result = OURO_TERMINAL_COMPRESSION_UNSUPPORTED;
            break;
        case GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING:
            *out_result = OURO_TERMINAL_COMPRESSION_PENDING;
            break;
        case GHOSTTY_TERMINAL_COMPRESSION_RESULT_COMPLETE:
            *out_result = OURO_TERMINAL_COMPRESSION_COMPLETE;
            break;
        default:
            return OURO_TERMINAL_ENGINE_ERROR;
    }
    return OURO_TERMINAL_OK;
}

OuroTerminalResult ouro_terminal_compress_incremental(
    OuroTerminal *terminal,
    OuroTerminalCompressionResult *out_result) {
    return compress_terminal(
        terminal,
        GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL,
        out_result);
}

OuroTerminalResult ouro_terminal_compress_full_for_testing(
    OuroTerminal *terminal,
    OuroTerminalCompressionResult *out_result) {
    return compress_terminal(
        terminal,
        GHOSTTY_TERMINAL_COMPRESSION_MODE_FULL,
        out_result);
}

OuroTerminalResult ouro_terminal_copy_plain_text(
    OuroTerminal *terminal,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length) {
    if (terminal == NULL || out_length == NULL ||
        (buffer == NULL && capacity != 0)) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }

    GhosttyFormatterTerminalOptions options =
        GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
    options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
    options.trim = true;

    GhosttyFormatter formatter = NULL;
    GhosttyResult result = ghostty_formatter_terminal_new(
        &terminal->allocator, &formatter, terminal->terminal, options);
    if (result != GHOSTTY_SUCCESS) return map_result(result);

    uint8_t *engine_buffer = NULL;
    size_t engine_length = 0;
    result = ghostty_formatter_format_alloc(
        formatter,
        &terminal->allocator,
        &engine_buffer,
        &engine_length);
    if (result != GHOSTTY_SUCCESS) {
        if (engine_buffer != NULL) {
            ghostty_free(
                &terminal->allocator, engine_buffer, engine_length);
        }
        ghostty_formatter_free(formatter);
        return map_result(result);
    }

    *out_length = engine_length;
    OuroTerminalResult adapter_result = OURO_TERMINAL_OK;
    if (capacity < engine_length) {
        adapter_result = OURO_TERMINAL_BUFFER_TOO_SMALL;
    } else if (engine_length != 0) {
        memcpy(buffer, engine_buffer, engine_length);
    }

    ghostty_free(&terminal->allocator, engine_buffer, engine_length);
    ghostty_formatter_free(formatter);
    return adapter_result;
}

OuroTerminalResult ouro_terminal_copy_snapshot(
    OuroTerminal *terminal,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length) {
    if (terminal == NULL || out_length == NULL ||
        (buffer == NULL && capacity != 0)) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }

    size_t required = 0;
    GhosttyResult result = ghostty_snapshot_encode_buf(
        terminal->terminal, NULL, 0, &required);
    if (result != GHOSTTY_SUCCESS && result != GHOSTTY_OUT_OF_SPACE) {
        *out_length = 0;
        return map_result(result);
    }
    *out_length = required;

    if (required > terminal->config.snapshot_max_bytes ||
        capacity < required) {
        return OURO_TERMINAL_BUFFER_TOO_SMALL;
    }
    if (required == 0) return OURO_TERMINAL_ENGINE_ERROR;

    size_t written = 0;
    result = ghostty_snapshot_encode_buf(
        terminal->terminal, buffer, capacity, &written);
    *out_length = written;
    if (result != GHOSTTY_SUCCESS) return map_result(result);
    if (written != required || written > terminal->config.snapshot_max_bytes) {
        return OURO_TERMINAL_ENGINE_ERROR;
    }
    return OURO_TERMINAL_OK;
}

static OuroTerminalResult terminal_restore_internal(
    const OuroTerminalConfig *config,
    OuroTerminalPageBudget *page_budget,
    const uint8_t *bytes,
    size_t length,
    OuroTerminal **out_terminal) {
    if (!valid_config(config) || out_terminal == NULL ||
        (bytes == NULL && length != 0)) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }
    *out_terminal = NULL;
    if (length > config->snapshot_max_bytes) {
        return OURO_TERMINAL_INVALID_ARGUMENT;
    }

    OuroTerminal *adapter = calloc(1, sizeof(*adapter));
    if (adapter == NULL) return OURO_TERMINAL_OUT_OF_MEMORY;
    initialize_adapter(adapter, config);

    GhosttySnapshotDecoder decoder = NULL;
    GhosttyResult result = ghostty_snapshot_decoder_new_buf(
        &adapter->allocator, &decoder, bytes, length);
    if (result != GHOSTTY_SUCCESS) {
        release_adapter_storage(adapter);
        return map_result(result);
    }

    result = ghostty_snapshot_decoder_set(
        decoder,
        GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES,
        &config->continuation_max_bytes);
    if (result == GHOSTTY_SUCCESS && page_budget != NULL) {
        result = ghostty_snapshot_decoder_set(
            decoder,
            GHOSTTY_SNAPSHOT_DECODER_OPT_PAGE_BUDGET,
            &page_budget->budget);
    }
    if (result != GHOSTTY_SUCCESS) {
        ghostty_snapshot_decoder_free(decoder);
        release_adapter_storage(adapter);
        return map_result(result);
    }

    GhosttyTerminal restored = NULL;
    result = ghostty_snapshot_decoder_decode(decoder, &restored);
    if (result != GHOSTTY_SUCCESS) {
        ghostty_snapshot_decoder_free(decoder);
        release_adapter_storage(adapter);
        /* Invalid snapshot data is not an invalid adapter call. */
        if (result == GHOSTTY_INVALID_VALUE ||
            result == GHOSTTY_LIMIT_EXCEEDED) {
            return OURO_TERMINAL_ENGINE_ERROR;
        }
        return map_result(result);
    }

    size_t consumed = 0;
    result = ghostty_snapshot_decoder_get(
        decoder,
        GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET,
        &consumed);
    ghostty_snapshot_decoder_free(decoder);
    if (result != GHOSTTY_SUCCESS || consumed != length) {
        ghostty_terminal_free(restored);
        release_adapter_storage(adapter);
        return OURO_TERMINAL_ENGINE_ERROR;
    }
    adapter->terminal = restored;

    result = install_terminal_effects(adapter);
    if (result == GHOSTTY_SUCCESS) {
        result = apply_runtime_bounds(adapter->terminal, config);
    }
    if (result != GHOSTTY_SUCCESS) {
        ghostty_terminal_free(adapter->terminal);
        release_adapter_storage(adapter);
        return map_result(result);
    }

    *out_terminal = adapter;
    return OURO_TERMINAL_OK;
}

OuroTerminalResult ouro_terminal_restore(
    const OuroTerminalConfig *config,
    const uint8_t *bytes,
    size_t length,
    OuroTerminal **out_terminal) {
    return terminal_restore_internal(
        config, NULL, bytes, length, out_terminal);
}

OuroTerminalResult ouro_terminal_restore_with_page_budget(
    const OuroTerminalConfig *config,
    OuroTerminalPageBudget *page_budget,
    const uint8_t *bytes,
    size_t length,
    OuroTerminal **out_terminal) {
    if (page_budget == NULL) return OURO_TERMINAL_INVALID_ARGUMENT;
    return terminal_restore_internal(
        config, page_budget, bytes, length, out_terminal);
}
