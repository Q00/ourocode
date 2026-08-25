#include "ouro_terminal_engine.h"

#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if SIZE_MAX == UINT64_MAX
_Static_assert(sizeof(OuroTerminalConfig) == 80, "v4 config layout changed");
_Static_assert(sizeof(OuroTerminalFrameInfo) == 24, "v4 frame layout changed");
_Static_assert(sizeof(OuroTerminalMemoryInfo) == 48, "v4 memory layout changed");
_Static_assert(sizeof(OuroTerminalPageBudgetStats) == 56,
               "v4 page budget stats layout changed");
_Static_assert(sizeof(OuroRenderProjectionConfig) == 32,
               "v5 render projection config layout changed");
_Static_assert(sizeof(OuroRenderProjectionMemoryInfo) == 48,
               "v5 render projection memory layout changed");
_Static_assert(sizeof(OuroRenderRgb) == 3, "v5 render RGB layout changed");
_Static_assert(sizeof(OuroRenderColor) == 8, "v5 render color layout changed");
_Static_assert(sizeof(OuroRenderFrameInfo) == 832, "v5 render frame layout changed");
_Static_assert(sizeof(OuroRenderRowInfo) == 32, "v5 render row layout changed");
_Static_assert(sizeof(OuroRenderCellInfo) == 80, "v5 render cell layout changed");
_Static_assert(sizeof(OuroTerminalInputConfig) == 16, "v6 input config layout changed");
_Static_assert(sizeof(OuroTerminalKeyEvent) == 48, "v6 key event layout changed");
_Static_assert(sizeof(OuroTerminalMouseGeometry) == 80, "v6 mouse geometry layout changed");
_Static_assert(sizeof(OuroTerminalMouseEvent) == 40, "v6 mouse event layout changed");
_Static_assert(sizeof(OuroTerminalScrollEvent) == 40, "v6 scroll event layout changed");
_Static_assert(sizeof(OuroTerminalScrollViewportKind) == 4,
               "v6 viewport kind layout changed");
_Static_assert(sizeof(OuroTerminalScrollViewport) == 32,
               "v6 viewport request layout changed");
_Static_assert(sizeof(OuroTerminalScrollbar) == 40,
               "v6 scrollbar layout changed");
_Static_assert(sizeof(OuroTerminalSelectionConfig) == 40, "v6 selection config layout changed");
_Static_assert(sizeof(OuroTerminalSelectionPoint) == 56, "v6 selection point layout changed");
_Static_assert(sizeof(OuroTerminalSelectionGeometry) == 40, "v6 selection geometry layout changed");
#endif

#if defined(__APPLE__)
extern bool ouro_terminal_gate0_test_grow_shrink(
    OuroTerminal *terminal,
    size_t initial_len,
    size_t grown_len,
    size_t shrunk_len,
    size_t *out_initial_usable,
    size_t *out_grown_usable,
    size_t *out_shrunk_usable);
#endif

static OuroTerminalConfig test_config(void) {
    OuroTerminalConfig config = {
        .size = sizeof(OuroTerminalConfig),
        .abi_version = OURO_TERMINAL_ENGINE_ABI_VERSION,
        .columns = 24,
        .rows = 6,
        .cell_width_px = 8,
        .cell_height_px = 16,
        .scrollback_max_bytes = 8 * 1024 * 1024,
        .scrollback_max_lines = 10000,
        .kitty_image_max_bytes = 0,
        .apc_max_bytes = 1024 * 1024,
        .continuation_max_bytes = 64 * 1024,
        .snapshot_max_bytes = 16 * 1024 * 1024,
        .engine_memory_max_bytes = 32 * 1024 * 1024,
    };
    return config;
}

static OuroTerminalMemoryInfo memory_info(OuroTerminal *terminal) {
    OuroTerminalMemoryInfo info = {
        .size = sizeof(OuroTerminalMemoryInfo),
        .abi_version = OURO_TERMINAL_ENGINE_ABI_VERSION,
    };
    assert(ouro_terminal_memory_info(terminal, &info) == OURO_TERMINAL_OK);
    assert(info.live_bytes <= info.peak_bytes);
    assert(info.peak_bytes <= info.limit_bytes);
    return info;
}

static OuroRenderProjectionConfig render_config(void) {
    OuroRenderProjectionConfig config = {
        .size = sizeof(OuroRenderProjectionConfig),
        .abi_version = OURO_TERMINAL_ENGINE_ABI_VERSION,
        .memory_max_bytes = 8 * 1024 * 1024,
        .max_grapheme_bytes = OURO_RENDER_MAX_GRAPHEME_BYTES,
    };
    return config;
}

static OuroRenderProjectionMemoryInfo render_memory_info(
    OuroRenderProjection *projection) {
    OuroRenderProjectionMemoryInfo info = {
        .size = sizeof(OuroRenderProjectionMemoryInfo),
        .abi_version = OURO_TERMINAL_ENGINE_ABI_VERSION,
    };
    assert(ouro_render_projection_memory_info(projection, &info) ==
           OURO_TERMINAL_OK);
    assert(info.live_bytes <= info.peak_bytes);
    assert(info.peak_bytes <= info.limit_bytes);
    return info;
}

static OuroTerminalPageBudgetStats page_budget_stats(
    OuroTerminalPageBudget *budget) {
    OuroTerminalPageBudgetStats stats = {
        .size = sizeof(OuroTerminalPageBudgetStats),
        .abi_version = OURO_TERMINAL_ENGINE_ABI_VERSION,
    };
    assert(ouro_terminal_page_budget_stats(budget, &stats) ==
           OURO_TERMINAL_OK);
    assert(stats.reserved_bytes <= stats.peak_reserved_bytes);
    assert(stats.peak_reserved_bytes <= stats.limit_bytes);
    return stats;
}

static void feed(OuroTerminal *terminal, const char *bytes) {
    assert(ouro_terminal_feed(
               terminal, (const uint8_t *)bytes, strlen(bytes)) ==
           OURO_TERMINAL_OK);
}

static uint8_t *plain_text(OuroTerminal *terminal, size_t *length) {
    *length = 0;
    OuroTerminalResult result =
        ouro_terminal_copy_plain_text(terminal, NULL, 0, length);
    assert(result == OURO_TERMINAL_BUFFER_TOO_SMALL ||
           (result == OURO_TERMINAL_OK && *length == 0));

    uint8_t *buffer = malloc(*length + 1);
    assert(buffer != NULL);
    result = ouro_terminal_copy_plain_text(
        terminal, buffer, *length, length);
    assert(result == OURO_TERMINAL_OK);
    buffer[*length] = 0;
    return buffer;
}

static uint8_t *snapshot(OuroTerminal *terminal, size_t *length) {
    *length = 0;
    assert(ouro_terminal_copy_snapshot(terminal, NULL, 0, length) ==
           OURO_TERMINAL_BUFFER_TOO_SMALL);
    assert(*length > 0);

    uint8_t *buffer = malloc(*length);
    assert(buffer != NULL);
    size_t written = 0;
    assert(ouro_terminal_copy_snapshot(
               terminal, buffer, *length, &written) == OURO_TERMINAL_OK);
    assert(written == *length);
    return buffer;
}

static OuroTerminalFrameInfo frame_info(OuroTerminal *terminal) {
    OuroTerminalFrameInfo frame = {
        .size = sizeof(OuroTerminalFrameInfo),
        .abi_version = OURO_TERMINAL_ENGINE_ABI_VERSION,
    };
    assert(ouro_terminal_frame_info(terminal, &frame) == OURO_TERMINAL_OK);
    return frame;
}

static OuroTerminalScrollbar scrollbar(OuroTerminal *terminal) {
    OuroTerminalScrollbar state = {
        .size = sizeof(OuroTerminalScrollbar),
        .abi_version = OURO_TERMINAL_ENGINE_ABI_VERSION,
    };
    assert(ouro_terminal_scrollbar(terminal, &state) == OURO_TERMINAL_OK);
    assert(state.length <= state.total);
    assert(state.offset <= state.total - state.length);
    return state;
}

static void assert_same_projection(
    OuroTerminal *left,
    OuroTerminal *right) {
    size_t left_length = 0;
    size_t right_length = 0;
    uint8_t *left_text = plain_text(left, &left_length);
    uint8_t *right_text = plain_text(right, &right_length);
    assert(left_length == right_length);
    assert(memcmp(left_text, right_text, left_length) == 0);
    free(left_text);
    free(right_text);

    OuroTerminalFrameInfo left_frame = frame_info(left);
    OuroTerminalFrameInfo right_frame = frame_info(right);
    assert(left_frame.columns == right_frame.columns);
    assert(left_frame.rows == right_frame.rows);
    assert(left_frame.cursor_x == right_frame.cursor_x);
    assert(left_frame.cursor_y == right_frame.cursor_y);
}

static void test_complete_snapshot_round_trip(void) {
    OuroTerminalConfig config = test_config();
    OuroTerminal *source = NULL;
    assert(ouro_terminal_new(&config, &source) == OURO_TERMINAL_OK);

    /* Styled Unicode: CJK, emoji, and an explicit combining codepoint. */
    feed(source,
         "\033[1;38;2;24;120;210mstyled 한글 👻 e\xCC\x81\033[0m\r\n");
    /* OSC 8 with an explicit id exercises snapshot hyperlink tables. */
    feed(source,
         "\033]8;id=ouro;https://example.com/session\033\\linked\033]8;;\033\\\r\n");

    char line[80];
    for (unsigned int i = 0; i < 48; ++i) {
        int count = snprintf(line, sizeof(line), "history-%02u-abcdefghij\r\n", i);
        assert(count > 0 && (size_t)count < sizeof(line));
        feed(source, line);
    }

    /* Reflow in both directions before persistence. */
    assert(ouro_terminal_resize(source, 9, 11, 8, 16) == OURO_TERMINAL_OK);
    assert(ouro_terminal_resize(source, 24, 6, 8, 16) == OURO_TERMINAL_OK);
    feed(source, "MAIN-SCREEN-MARKER\r\n");

    /* Create and leave the alternate screen active; both screens are encoded. */
    feed(source, "\033[?1049hALT-SCREEN 한글 👻 e\xCC\x81\r\n");
    feed(source,
         "\033]8;;https://example.com/alternate\033\\ALT-LINK\033]8;;\033\\");

    size_t encoded_length = 0;
    uint8_t *encoded = snapshot(source, &encoded_length);

    OuroTerminal *restored = NULL;
    assert(ouro_terminal_restore(
               &config, encoded, encoded_length, &restored) ==
           OURO_TERMINAL_OK);
    assert(restored != NULL);
    assert_same_projection(source, restored);

    /* At this exact pin, grounded snapshots canonically re-encode byte-for-byte. */
    size_t reencoded_length = 0;
    uint8_t *reencoded = snapshot(restored, &reencoded_length);
    assert(reencoded_length == encoded_length);
    assert(memcmp(reencoded, encoded, encoded_length) == 0);

    /* Return to primary and prove its reflowed history survived too. */
    feed(source, "\033[?1049l");
    feed(restored, "\033[?1049l");
    assert_same_projection(source, restored);
    size_t primary_length = 0;
    uint8_t *primary = plain_text(restored, &primary_length);
    assert(strstr((const char *)primary, "history-47") != NULL);
    assert(strstr((const char *)primary, "MAIN-SCREEN-MARKER") != NULL);

    free(primary);
    free(reencoded);
    free(encoded);
    ouro_terminal_free(restored);
    ouro_terminal_free(source);
}

static void test_unfinished_continuation(void) {
    OuroTerminalConfig config = test_config();
    OuroTerminal *source = NULL;
    assert(ouro_terminal_new(&config, &source) == OURO_TERMINAL_OK);
    feed(source, "continuation-prefix \033[38;2;200;40");

    size_t encoded_length = 0;
    uint8_t *encoded = snapshot(source, &encoded_length);
    OuroTerminal *restored = NULL;
    assert(ouro_terminal_restore(
               &config, encoded, encoded_length, &restored) ==
           OURO_TERMINAL_OK);

    /*
     * The public decoder restores parser state with tracking disabled. Applying
     * the required runtime cap afterwards cannot reconstruct the already-read
     * prefix, so this exact upstream API rejects an immediate re-snapshot.
     */
    size_t unavailable = 123;
    assert(ouro_terminal_copy_snapshot(restored, NULL, 0, &unavailable) ==
           OURO_TERMINAL_INVALID_ARGUMENT);
    assert(unavailable == 0);

    feed(source, ";80mCONTINUED\033[0m\r\n");
    feed(restored, ";80mCONTINUED\033[0m\r\n");
    assert_same_projection(source, restored);

    /* Grounding repairs tracking, after which canonical encoding is identical. */
    size_t source_length = 0;
    size_t restored_length = 0;
    uint8_t *source_snapshot = snapshot(source, &source_length);
    uint8_t *restored_snapshot = snapshot(restored, &restored_length);
    assert(source_length == restored_length);
    assert(memcmp(source_snapshot, restored_snapshot, source_length) == 0);

    /* Decoder continuation input is capped independently of total size. */
    OuroTerminalConfig limited = config;
    limited.continuation_max_bytes = 4;
    OuroTerminal *rejected = (OuroTerminal *)(uintptr_t)1;
    assert(ouro_terminal_restore(
               &limited, encoded, encoded_length, &rejected) ==
           OURO_TERMINAL_ENGINE_ERROR);
    assert(rejected == NULL);

    free(restored_snapshot);
    free(source_snapshot);
    free(encoded);
    ouro_terminal_free(restored);
    ouro_terminal_free(source);
}

static void test_fail_closed_inputs(void) {
    OuroTerminalConfig config = test_config();
    OuroTerminal *source = NULL;
    assert(ouro_terminal_new(&config, &source) == OURO_TERMINAL_OK);
    feed(source, "snapshot-integrity\r\n");

    size_t encoded_length = 0;
    uint8_t *encoded = snapshot(source, &encoded_length);
    assert(encoded_length > 20);

    OuroTerminal *out = (OuroTerminal *)(uintptr_t)1;
    assert(ouro_terminal_restore(
               &config, encoded, encoded_length - 1, &out) ==
           OURO_TERMINAL_ENGINE_ERROR);
    assert(out == NULL);

    uint8_t *corrupt = malloc(encoded_length);
    assert(corrupt != NULL);
    memcpy(corrupt, encoded, encoded_length);
    /* Fixed envelope is 10 bytes; byte 16 is in the first record's CRC32C. */
    corrupt[16] ^= 0x80;
    out = (OuroTerminal *)(uintptr_t)1;
    assert(ouro_terminal_restore(&config, corrupt, encoded_length, &out) ==
           OURO_TERMINAL_ENGINE_ERROR);
    assert(out == NULL);

    out = (OuroTerminal *)(uintptr_t)1;
    assert(ouro_terminal_restore(&config, NULL, 0, &out) ==
           OURO_TERMINAL_ENGINE_ERROR);
    assert(out == NULL);

    OuroTerminalConfig too_small = config;
    too_small.snapshot_max_bytes = encoded_length - 1;
    out = (OuroTerminal *)(uintptr_t)1;
    assert(ouro_terminal_restore(
               &too_small, encoded, encoded_length, &out) ==
           OURO_TERMINAL_INVALID_ARGUMENT);
    assert(out == NULL);

    OuroTerminalConfig incompatible = config;
    incompatible.abi_version++;
    out = (OuroTerminal *)(uintptr_t)1;
    assert(ouro_terminal_restore(
               &incompatible, encoded, encoded_length, &out) ==
           OURO_TERMINAL_INVALID_ARGUMENT);
    /* Invalid ABI is rejected before the adapter may trust/write the pointer. */
    assert(out == (OuroTerminal *)(uintptr_t)1);

    OuroTerminalFrameInfo incompatible_frame = {
        .size = sizeof(OuroTerminalFrameInfo),
        .abi_version = OURO_TERMINAL_ENGINE_ABI_VERSION + 1,
    };
    assert(ouro_terminal_frame_info(source, &incompatible_frame) ==
           OURO_TERMINAL_INVALID_ARGUMENT);

    OuroTerminalMemoryInfo incompatible_memory = {
        .size = sizeof(OuroTerminalMemoryInfo),
        .abi_version = OURO_TERMINAL_ENGINE_ABI_VERSION + 1,
    };
    assert(ouro_terminal_memory_info(source, &incompatible_memory) ==
           OURO_TERMINAL_INVALID_ARGUMENT);

    /* Export cap is checked before any caller buffer bytes are touched. */
    OuroTerminalConfig capped = config;
    capped.snapshot_max_bytes = 32;
    OuroTerminal *capped_terminal = NULL;
    assert(ouro_terminal_new(&capped, &capped_terminal) == OURO_TERMINAL_OK);
    feed(capped_terminal, "larger-than-thirty-two-byte-snapshot");
    size_t required = 0;
    assert(ouro_terminal_copy_snapshot(capped_terminal, NULL, 0, &required) ==
           OURO_TERMINAL_BUFFER_TOO_SMALL);
    assert(required > capped.snapshot_max_bytes);
    uint8_t *untouched = malloc(required);
    assert(untouched != NULL);
    memset(untouched, 0xA5, required);
    size_t reported = 0;
    assert(ouro_terminal_copy_snapshot(
               capped_terminal, untouched, required, &reported) ==
           OURO_TERMINAL_BUFFER_TOO_SMALL);
    assert(reported == required);
    for (size_t i = 0; i < required; ++i) assert(untouched[i] == 0xA5);

    free(untouched);
    ouro_terminal_free(capped_terminal);
    free(corrupt);
    free(encoded);
    ouro_terminal_free(source);
}

static void test_incremental_idle_compression(void) {
    OuroTerminalConfig config = test_config();
    OuroTerminal *terminal = NULL;
    assert(ouro_terminal_new(&config, &terminal) == OURO_TERMINAL_OK);

    uint64_t initial_activity = UINT64_MAX;
    assert(ouro_terminal_compression_activity(
               terminal, &initial_activity) == OURO_TERMINAL_OK);
    assert(ouro_terminal_compression_activity(NULL, &initial_activity) ==
           OURO_TERMINAL_INVALID_ARGUMENT);
    assert(ouro_terminal_compression_activity(terminal, NULL) ==
           OURO_TERMINAL_INVALID_ARGUMENT);

    char line[96];
    for (unsigned int i = 0; i < 2048; ++i) {
        int count = snprintf(
            line,
            sizeof(line),
            "\033[3%umcompression-%04u-\xE9\x9F\x93\xE5\x9B\xBD-"
            "e\xCC\x81-\xF0\x9F\x8C\x8A-abcdefghij\033[0m\r\n",
            i % 8,
            i);
        assert(count > 0 && (size_t)count < sizeof(line));
        feed(terminal, line);
    }

    uint64_t populated_activity = initial_activity;
    assert(ouro_terminal_compression_activity(
               terminal, &populated_activity) == OURO_TERMINAL_OK);
    assert(populated_activity != initial_activity);

    size_t text_length = 0;
    uint8_t *before_text = plain_text(terminal, &text_length);
    size_t snapshot_length = 0;
    uint8_t *before_snapshot = snapshot(terminal, &snapshot_length);

    OuroTerminalCompressionResult step = OURO_TERMINAL_COMPRESSION_PENDING;
    size_t steps = 0;
    do {
        assert(++steps <= 8192);
        assert(ouro_terminal_compress_incremental(terminal, &step) ==
               OURO_TERMINAL_OK);
    } while (step == OURO_TERMINAL_COMPRESSION_PENDING);
    assert(step == OURO_TERMINAL_COMPRESSION_COMPLETE ||
           step == OURO_TERMINAL_COMPRESSION_UNSUPPORTED);
    assert(ouro_terminal_compress_incremental(NULL, &step) ==
           OURO_TERMINAL_INVALID_ARGUMENT);
    assert(ouro_terminal_compress_incremental(terminal, NULL) ==
           OURO_TERMINAL_INVALID_ARGUMENT);

    uint64_t final_activity = UINT64_MAX;
    assert(ouro_terminal_compression_activity(
               terminal, &final_activity) == OURO_TERMINAL_OK);
    assert(final_activity == populated_activity);

    size_t after_text_length = 0;
    uint8_t *after_text = plain_text(terminal, &after_text_length);
    assert(after_text_length == text_length);
    assert(memcmp(after_text, before_text, text_length) == 0);

    size_t after_snapshot_length = 0;
    uint8_t *after_snapshot = snapshot(terminal, &after_snapshot_length);
    assert(after_snapshot_length == snapshot_length);
    assert(memcmp(after_snapshot, before_snapshot, snapshot_length) == 0);

    feed(terminal, "post-incremental-activity\r\n");
    uint64_t mutated_activity = final_activity;
    assert(ouro_terminal_compression_activity(
               terminal, &mutated_activity) == OURO_TERMINAL_OK);
    assert(mutated_activity != final_activity);

    OuroTerminalCompressionResult full = OURO_TERMINAL_COMPRESSION_PENDING;
    assert(ouro_terminal_compress_full_for_testing(terminal, &full) ==
           OURO_TERMINAL_OK);
    assert(full == OURO_TERMINAL_COMPRESSION_COMPLETE ||
           full == OURO_TERMINAL_COMPRESSION_UNSUPPORTED);
    assert(ouro_terminal_compress_full_for_testing(NULL, &full) ==
           OURO_TERMINAL_INVALID_ARGUMENT);
    assert(ouro_terminal_compress_full_for_testing(terminal, NULL) ==
           OURO_TERMINAL_INVALID_ARGUMENT);

    printf(
        "ABI v6 compression: incremental_steps=%zu result=%d "
        "activity=%llu->%llu->%llu full=%d\n",
        steps,
        (int)step,
        (unsigned long long)initial_activity,
        (unsigned long long)populated_activity,
        (unsigned long long)mutated_activity,
        (int)full);

    free(after_snapshot);
    free(after_text);
    free(before_snapshot);
    free(before_text);
    ouro_terminal_free(terminal);
}

static void test_shared_page_budget(void) {
    OuroTerminalConfig config = test_config();
    OuroTerminalPageBudget *budget = NULL;
    assert(ouro_terminal_page_budget_new(
               128 * 1024 * 1024, &budget) == OURO_TERMINAL_OK);
    assert(budget != NULL);
    assert(page_budget_stats(budget).reserved_bytes == 0);

    OuroTerminal *source = NULL;
    assert(ouro_terminal_new_with_page_budget(
               &config, budget, &source) == OURO_TERMINAL_OK);
    feed(source, "shared-page-budget\r\n");
    size_t source_reserved = page_budget_stats(budget).reserved_bytes;
    assert(source_reserved > 0);

    size_t encoded_length = 0;
    uint8_t *encoded = snapshot(source, &encoded_length);
    OuroTerminal *restored = NULL;
    assert(ouro_terminal_restore_with_page_budget(
               &config,
               budget,
               encoded,
               encoded_length,
               &restored) == OURO_TERMINAL_OK);
    assert(page_budget_stats(budget).reserved_bytes > source_reserved);

    ouro_terminal_free(restored);
    assert(page_budget_stats(budget).reserved_bytes == source_reserved);
    ouro_terminal_free(source);
    assert(page_budget_stats(budget).reserved_bytes == 0);
    free(encoded);
    ouro_terminal_page_budget_free(budget);

    OuroTerminalPageBudget *tiny = NULL;
    assert(ouro_terminal_page_budget_new(1, &tiny) == OURO_TERMINAL_OK);
    OuroTerminal *denied = (OuroTerminal *)(uintptr_t)1;
    assert(ouro_terminal_new_with_page_budget(
               &config, tiny, &denied) == OURO_TERMINAL_OUT_OF_MEMORY);
    assert(denied == NULL);
    assert(page_budget_stats(tiny).denial_count > 0);
    ouro_terminal_page_budget_free(tiny);
}

typedef struct RenderEvidence {
    bool cjk;
    bool wide_tail;
    bool grapheme;
    bool styled;
    bool selected;
    bool hyperlink;
    bool semantic;
    bool retried;
    bool long_grapheme;
} RenderEvidence;

static OuroRenderFrameInfo render_info(OuroRenderFrame *frame) {
    OuroRenderFrameInfo info = {
        .size = sizeof(OuroRenderFrameInfo),
        .abi_version = OURO_TERMINAL_ENGINE_ABI_VERSION,
    };
    assert(ouro_render_frame_info(frame, &info) == OURO_TERMINAL_OK);
    return info;
}

static RenderEvidence drain_render_frame(OuroRenderFrame *frame) {
    RenderEvidence evidence = {0};
    for (;;) {
        OuroRenderRowInfo row = {
            .size = sizeof(OuroRenderRowInfo),
            .abi_version = OURO_TERMINAL_ENGINE_ABI_VERSION,
        };
        bool has_row = false;
        assert(ouro_render_frame_next_row(frame, &row, &has_row) ==
               OURO_TERMINAL_OK);
        if (!has_row) break;
        if (row.selection_has_value) evidence.selected = true;

        for (;;) {
            uint8_t small[1] = {0};
            OuroRenderCellInfo cell = {
                .size = sizeof(OuroRenderCellInfo),
                .abi_version = OURO_TERMINAL_ENGINE_ABI_VERSION,
            };
            bool has_cell = false;
            OuroTerminalResult result = ouro_render_frame_next_cell(
                frame, small, sizeof(small), &cell, &has_cell);
            if (!has_cell) {
                assert(result == OURO_TERMINAL_OK);
                break;
            }

            uint8_t *text = small;
            if (result == OURO_TERMINAL_BUFFER_TOO_SMALL) {
                const uint16_t retry_x = cell.x;
                text = malloc(cell.grapheme_bytes);
                assert(text != NULL);
                result = ouro_render_frame_next_cell(
                    frame,
                    text,
                    cell.grapheme_bytes,
                    &cell,
                    &has_cell);
                assert(has_cell && cell.x == retry_x);
                evidence.retried = true;
            }
            assert(result == OURO_TERMINAL_OK);
            if (cell.grapheme_bytes == 3 &&
                memcmp(text, "\xE7\x95\x8C", 3) == 0) {
                evidence.cjk = cell.width == 2;
            }
            if (cell.width == 0 && cell.grapheme_bytes == 0) {
                evidence.wide_tail = true;
            }
            if (cell.grapheme_bytes == 3 &&
                memcmp(text, "e\xCC\x81", 3) == 0) {
                evidence.grapheme = true;
            }
            if (cell.grapheme_bytes == 19 && text[0] == 'q') {
                evidence.long_grapheme = true;
            }
            if (cell.bold && cell.italic && cell.underline != 0 &&
                cell.foreground.kind == OURO_RENDER_COLOR_PALETTE &&
                cell.foreground.palette_index == 42 &&
                cell.background.kind == OURO_RENDER_COLOR_RGB &&
                cell.background.rgb.r == 1 &&
                cell.background.rgb.g == 2 &&
                cell.background.rgb.b == 3 &&
                cell.underline_color_has_value &&
                cell.underline_color.kind == OURO_RENDER_COLOR_RGB &&
                cell.underline_color.rgb.r == 4 &&
                cell.underline_color.rgb.g == 5 &&
                cell.underline_color.rgb.b == 6) {
                evidence.styled = true;
            }
            if (cell.selected) evidence.selected = true;
            if (cell.has_hyperlink) evidence.hyperlink = true;
            if (cell.semantic == OURO_RENDER_CELL_SEMANTIC_PROMPT) {
                evidence.semantic = true;
            }
            if (text != small) free(text);
        }
    }
    return evidence;
}

static void test_detached_render_projection(void) {
    OuroTerminalConfig config = test_config();
    config.columns = 16;
    config.rows = 4;
    OuroTerminal *terminal = NULL;
    assert(ouro_terminal_new(&config, &terminal) == OURO_TERMINAL_OK);
    OuroTerminalMemoryInfo headless = memory_info(terminal);

    feed(terminal,
         "\033[1;3;4;38;5;42;48;2;1;2;3;58;2;4;5;6m"
         "\xE7\x95\x8C"
         "e\xCC\x81"
         "q\xCC\x81\xCC\x82\xCC\x83\xCC\x84\xCC\x85"
         "\xCC\x86\xCC\x87\xCC\x88\xCC\x89"
         "\033[0m "
         "\033]8;;https://example.com/render\033\\link\033]8;;\033\\"
         "\r\n\033]133;A\aPROMPT");
    assert(ouro_terminal_set_selection(terminal, 0, 0, 2, 0, false) ==
           OURO_TERMINAL_OK);

    OuroRenderProjection *projection = NULL;
    OuroRenderProjectionConfig projection_config = render_config();
    assert(ouro_render_projection_new(
               terminal, &projection_config, &projection) ==
           OURO_TERMINAL_OK);
    assert(memory_info(terminal).live_bytes == headless.live_bytes);
    OuroRenderProjectionMemoryInfo projection_memory =
        render_memory_info(projection);
    assert(projection_memory.live_bytes > 0);

    OuroRenderFrame *frame = NULL;
    assert(ouro_render_projection_begin(projection, &frame) ==
           OURO_TERMINAL_OK);
    OuroRenderFrameInfo first = render_info(frame);
    assert(first.generation == 1);
    assert(first.dirty == OURO_TERMINAL_DIRTY_FULL);
    assert(first.columns == 16 && first.rows == 4);
    assert(first.cursor_has_value && first.cursor_visible);
    RenderEvidence evidence = drain_render_frame(frame);
    assert(evidence.cjk && evidence.wide_tail && evidence.grapheme);
    assert(evidence.long_grapheme);
    assert(evidence.styled && evidence.selected && evidence.hyperlink);
    assert(evidence.semantic && evidence.retried);
    assert(ouro_render_frame_end(frame, OURO_RENDER_FRAME_COMMITTED) ==
           OURO_TERMINAL_OK);

    assert(ouro_render_projection_begin(projection, &frame) ==
           OURO_TERMINAL_OK);
    OuroRenderFrameInfo clean = render_info(frame);
    assert(clean.generation == 2);
    assert(clean.dirty == OURO_TERMINAL_DIRTY_NONE);
    (void)drain_render_frame(frame);
    assert(ouro_render_frame_end(frame, OURO_RENDER_FRAME_COMMITTED) ==
           OURO_TERMINAL_OK);

    feed(terminal, "X");
    assert(ouro_render_projection_begin(projection, &frame) ==
           OURO_TERMINAL_OK);
    assert(render_info(frame).dirty == OURO_TERMINAL_DIRTY_PARTIAL);
    assert(ouro_render_frame_end(frame, OURO_RENDER_FRAME_DROPPED) ==
           OURO_TERMINAL_OK);
    assert(ouro_render_projection_begin(projection, &frame) ==
           OURO_TERMINAL_OK);
    assert(render_info(frame).dirty == OURO_TERMINAL_DIRTY_FULL);
    (void)drain_render_frame(frame);
    assert(ouro_render_frame_end(frame, OURO_RENDER_FRAME_COMMITTED) ==
           OURO_TERMINAL_OK);

    assert(ouro_render_projection_force_full(projection) == OURO_TERMINAL_OK);
    assert(ouro_render_projection_begin(projection, &frame) ==
           OURO_TERMINAL_OK);
    assert(render_info(frame).dirty == OURO_TERMINAL_DIRTY_FULL);
    OuroRenderRowInfo one_row = {
        .size = sizeof(OuroRenderRowInfo),
        .abi_version = OURO_TERMINAL_ENGINE_ABI_VERSION,
    };
    bool has_row = false;
    assert(ouro_render_frame_next_row(frame, &one_row, &has_row) ==
           OURO_TERMINAL_OK);
    assert(has_row);
    assert(ouro_render_frame_end(frame, OURO_RENDER_FRAME_COMMITTED) ==
           OURO_TERMINAL_INVALID_ARGUMENT);
    assert(ouro_render_projection_begin(projection, &frame) ==
           OURO_TERMINAL_OK);
    assert(render_info(frame).dirty == OURO_TERMINAL_DIRTY_FULL);
    (void)drain_render_frame(frame);
    assert(ouro_render_frame_end(frame, OURO_RENDER_FRAME_COMMITTED) ==
           OURO_TERMINAL_OK);

    ouro_render_projection_free(projection);
    assert(memory_info(terminal).live_bytes == headless.live_bytes);
    ouro_terminal_free(terminal);
}

static void test_render_projection_rebind_and_budget(void) {
    OuroTerminalConfig terminal_config = test_config();
    terminal_config.columns = 16;
    terminal_config.rows = 4;
    OuroRenderProjectionConfig projection_config = render_config();

    OuroTerminal *old_terminal = NULL;
    OuroTerminal *candidate = NULL;
    assert(ouro_terminal_new(&terminal_config, &old_terminal) ==
           OURO_TERMINAL_OK);
    assert(ouro_terminal_new(&terminal_config, &candidate) ==
           OURO_TERMINAL_OK);
    feed(old_terminal, "OLD");
    feed(candidate, "CANDIDATE");

    OuroRenderProjection *projection = NULL;
    assert(ouro_render_projection_new(
               old_terminal, &projection_config, &projection) ==
           OURO_TERMINAL_OK);
    OuroRenderFrame *frame = NULL;
    assert(ouro_render_projection_begin(projection, &frame) ==
           OURO_TERMINAL_OK);
    assert(render_info(frame).generation == 1);
    (void)drain_render_frame(frame);
    assert(ouro_render_frame_end(frame, OURO_RENDER_FRAME_COMMITTED) ==
           OURO_TERMINAL_OK);

    assert(ouro_render_projection_rebind(projection, candidate) ==
           OURO_TERMINAL_OK);
    /* The projection allocator is independent, so this cannot invalidate it. */
    ouro_terminal_free(old_terminal);
    old_terminal = NULL;
    feed(candidate, "-AFTER-OLD-DROP");
    assert(ouro_render_projection_begin(projection, &frame) ==
           OURO_TERMINAL_OK);
    OuroRenderFrameInfo rebound = render_info(frame);
    assert(rebound.generation == 2);
    assert(rebound.dirty == OURO_TERMINAL_DIRTY_FULL);
    (void)drain_render_frame(frame);
    assert(ouro_render_frame_end(frame, OURO_RENDER_FRAME_COMMITTED) ==
           OURO_TERMINAL_OK);
    OuroRenderProjectionMemoryInfo rebound_memory =
        render_memory_info(projection);
    assert(rebound_memory.peak_bytes > rebound_memory.live_bytes);
    ouro_render_projection_free(projection);
    ouro_terminal_free(candidate);

    /* The render allocator has its own hard cap and fails closed. */
    OuroTerminal *tiny_terminal = NULL;
    assert(ouro_terminal_new(&terminal_config, &tiny_terminal) ==
           OURO_TERMINAL_OK);
    projection_config.memory_max_bytes = 1;
    projection = (OuroRenderProjection *)(uintptr_t)1;
    assert(ouro_render_projection_new(
               tiny_terminal, &projection_config, &projection) ==
           OURO_TERMINAL_OUT_OF_MEMORY);
    assert(projection == NULL);
    ouro_terminal_free(tiny_terminal);

    /* A failed transactional rebind preserves the old bound state. */
    projection_config = render_config();
    OuroTerminal *probe_terminal = NULL;
    assert(ouro_terminal_new(&terminal_config, &probe_terminal) ==
           OURO_TERMINAL_OK);
    feed(probe_terminal, "PRESERVED-OLD");
    assert(ouro_render_projection_new(
               probe_terminal, &projection_config, &projection) ==
           OURO_TERMINAL_OK);
    const size_t resource_floor = render_memory_info(projection).live_bytes;
    assert(ouro_render_projection_begin(projection, &frame) ==
           OURO_TERMINAL_OK);
    (void)drain_render_frame(frame);
    assert(ouro_render_frame_end(frame, OURO_RENDER_FRAME_COMMITTED) ==
           OURO_TERMINAL_OK);
    const size_t rendered_live = render_memory_info(projection).live_bytes;
    assert(resource_floor > 0 && rendered_live >= resource_floor);
    assert(resource_floor <= SIZE_MAX - rendered_live);
    ouro_render_projection_free(projection);
    ouro_terminal_free(probe_terminal);

    projection_config.memory_max_bytes = rendered_live + resource_floor - 1;
    old_terminal = NULL;
    candidate = NULL;
    assert(ouro_terminal_new(&terminal_config, &old_terminal) ==
           OURO_TERMINAL_OK);
    assert(ouro_terminal_new(&terminal_config, &candidate) ==
           OURO_TERMINAL_OK);
    feed(old_terminal, "PRESERVED-OLD");
    feed(candidate, "REJECTED-CANDIDATE");
    assert(ouro_render_projection_new(
               old_terminal, &projection_config, &projection) ==
           OURO_TERMINAL_OK);
    assert(ouro_render_projection_begin(projection, &frame) ==
           OURO_TERMINAL_OK);
    (void)drain_render_frame(frame);
    assert(ouro_render_frame_end(frame, OURO_RENDER_FRAME_COMMITTED) ==
           OURO_TERMINAL_OK);
    assert(ouro_render_projection_rebind(projection, candidate) ==
           OURO_TERMINAL_OUT_OF_MEMORY);
    assert(render_memory_info(projection).allocation_failures > 0);
    assert(ouro_render_projection_force_full(projection) == OURO_TERMINAL_OK);
    assert(ouro_render_projection_begin(projection, &frame) ==
           OURO_TERMINAL_OK);
    assert(render_info(frame).dirty == OURO_TERMINAL_DIRTY_FULL);
    (void)drain_render_frame(frame);
    assert(ouro_render_frame_end(frame, OURO_RENDER_FRAME_COMMITTED) ==
           OURO_TERMINAL_OK);
    ouro_render_projection_free(projection);
    ouro_terminal_free(old_terminal);
    ouro_terminal_free(candidate);
}

static bool create_succeeds_with_limit(
    const OuroTerminalConfig *base,
    size_t limit) {
    OuroTerminalConfig config = *base;
    config.engine_memory_max_bytes = limit;
    OuroTerminal *terminal = (OuroTerminal *)(uintptr_t)1;
    OuroTerminalResult result = ouro_terminal_new(&config, &terminal);
    if (result == OURO_TERMINAL_OK) {
        assert(terminal != NULL);
        OuroTerminalMemoryInfo info = memory_info(terminal);
        assert(info.limit_bytes == limit);
        ouro_terminal_free(terminal);
        return true;
    }
    assert(result == OURO_TERMINAL_OUT_OF_MEMORY);
    assert(terminal == NULL);
    return false;
}

static size_t minimum_create_limit(const OuroTerminalConfig *config) {
    size_t low = 1;
    size_t high = config->engine_memory_max_bytes;
    assert(create_succeeds_with_limit(config, high));
    while (low < high) {
        const size_t middle = low + (high - low) / 2;
        if (create_succeeds_with_limit(config, middle)) {
            high = middle;
        } else {
            low = middle + 1;
        }
    }
    return low;
}

static bool restore_succeeds_with_limit(
    const OuroTerminalConfig *base,
    const uint8_t *encoded,
    size_t encoded_length,
    size_t limit) {
    OuroTerminalConfig config = *base;
    config.engine_memory_max_bytes = limit;
    OuroTerminal *terminal = (OuroTerminal *)(uintptr_t)1;
    OuroTerminalResult result = ouro_terminal_restore(
        &config, encoded, encoded_length, &terminal);
    if (result == OURO_TERMINAL_OK) {
        assert(terminal != NULL);
        OuroTerminalMemoryInfo info = memory_info(terminal);
        assert(info.limit_bytes == limit);
        ouro_terminal_free(terminal);
        return true;
    }
    assert(result == OURO_TERMINAL_OUT_OF_MEMORY);
    assert(terminal == NULL);
    return false;
}

static void test_hard_memory_budget(void) {
    OuroTerminalConfig config = test_config();

    /* A literal tiny cap fails closed before exposing a partial terminal. */
    assert(!create_succeeds_with_limit(&config, 1));

    /* Find the exact create watermark, then force a rollback-safe growth OOM. */
    const size_t minimum = minimum_create_limit(&config);
    config.engine_memory_max_bytes = minimum;
    OuroTerminal *terminal = NULL;
    assert(ouro_terminal_new(&config, &terminal) == OURO_TERMINAL_OK);
    OuroTerminalMemoryInfo before_failure = memory_info(terminal);
    OuroTerminalResult resize_result = ouro_terminal_resize(
        terminal, UINT16_MAX, UINT16_MAX, 8, 16);
    assert(resize_result != OURO_TERMINAL_OK);
    OuroTerminalMemoryInfo after_failure = memory_info(terminal);
    assert(after_failure.live_bytes == before_failure.live_bytes);
    assert(after_failure.peak_bytes >= before_failure.peak_bytes);
    assert(after_failure.allocation_failures >
           before_failure.allocation_failures);
    ouro_terminal_free(terminal);

    /*
     * The pinned vt_write returns void. At the exact creation watermark, the
     * first allocator-backed input growth is denied and feed must surface OOM.
     * The terminal is discarded immediately because it may contain a prefix.
     */
    assert(ouro_terminal_new(&config, &terminal) == OURO_TERMINAL_OK);
    OuroTerminalMemoryInfo before_feed_failure = memory_info(terminal);
    assert(ouro_terminal_feed(terminal, NULL, 0) == OURO_TERMINAL_OK);
    assert(memory_info(terminal).allocation_failures ==
           before_feed_failure.allocation_failures);
    const char *allocation_requiring_input =
        "\033]8;id=feed-oom;https://example.com/feed-oom\033\\"
        "linked-\xE9\x9F\x93\xE5\x9B\xBD-\xF0\x9F\x8C\x8A"
        "\033]8;;\033\\\r\n";
    assert(ouro_terminal_feed(
               terminal,
               (const uint8_t *)allocation_requiring_input,
               strlen(allocation_requiring_input)) ==
           OURO_TERMINAL_OUT_OF_MEMORY);
    OuroTerminalMemoryInfo after_feed_failure = memory_info(terminal);
    assert(after_feed_failure.allocation_failures >
           before_feed_failure.allocation_failures);
    ouro_terminal_free(terminal);

    /* Temporary formatter output must not remain charged to the terminal. */
    config = test_config();
    assert(ouro_terminal_new(&config, &terminal) == OURO_TERMINAL_OK);
    feed(terminal, "budget-accounting 한글 formatter\r\n");
    OuroTerminalMemoryInfo before_formatter = memory_info(terminal);
    size_t text_length = 0;
    uint8_t *text = plain_text(terminal, &text_length);
    free(text);
    OuroTerminalMemoryInfo after_formatter = memory_info(terminal);
    assert(after_formatter.live_bytes == before_formatter.live_bytes);
    assert(after_formatter.peak_bytes >= before_formatter.peak_bytes);

#if defined(__APPLE__)
    /* A logical shrink must release the large malloc region physically. */
    size_t initial_usable = 0;
    size_t grown_usable = 0;
    size_t shrunk_usable = 0;
    OuroTerminalMemoryInfo before_physical_probe = memory_info(terminal);
    assert(ouro_terminal_gate0_test_grow_shrink(
        terminal,
        4 * 1024,
        8 * 1024 * 1024,
        4 * 1024,
        &initial_usable,
        &grown_usable,
        &shrunk_usable));
    OuroTerminalMemoryInfo after_physical_probe = memory_info(terminal);
    assert(initial_usable >= 4 * 1024);
    assert(grown_usable >= 8 * 1024 * 1024);
    assert(shrunk_usable >= 4 * 1024);
    assert(shrunk_usable < grown_usable / 16);
    assert(after_physical_probe.live_bytes ==
           before_physical_probe.live_bytes);
    assert(after_physical_probe.peak_bytes >=
           before_physical_probe.peak_bytes);
    assert(after_physical_probe.allocation_failures ==
           before_physical_probe.allocation_failures);
    printf(
        "ABI v6 malloc_size: initial=%zu grown=%zu shrunk=%zu\n",
        initial_usable,
        grown_usable,
        shrunk_usable);
#endif

    /* Decoder bookkeeping shares the cap; native page mmaps do not. */
    char line[80];
    for (unsigned int i = 0; i < 96; ++i) {
        int count = snprintf(
            line, sizeof(line), "budget-history-%03u-abcdefghij\r\n", i);
        assert(count > 0 && (size_t)count < sizeof(line));
        feed(terminal, line);
    }
    size_t encoded_length = 0;
    uint8_t *encoded = snapshot(terminal, &encoded_length);
    OuroTerminalMemoryInfo after_snapshot = memory_info(terminal);
    assert(after_snapshot.live_bytes >= after_formatter.live_bytes);
    assert(after_snapshot.peak_bytes >= after_formatter.peak_bytes);

    size_t low = 1;
    size_t high = config.engine_memory_max_bytes;
    assert(restore_succeeds_with_limit(
        &config, encoded, encoded_length, high));
    while (low < high) {
        const size_t middle = low + (high - low) / 2;
        if (restore_succeeds_with_limit(
                &config, encoded, encoded_length, middle)) {
            high = middle;
        } else {
            low = middle + 1;
        }
    }
    assert(low > 1);
    assert(!restore_succeeds_with_limit(
        &config, encoded, encoded_length, low - 1));

    OuroTerminal *restored = NULL;
    assert(ouro_terminal_restore(
               &config, encoded, encoded_length, &restored) ==
           OURO_TERMINAL_OK);
    OuroTerminalMemoryInfo restored_info = memory_info(restored);
    /* Peak retains decoder work; live contains only returned engine objects. */
    assert(restored_info.peak_bytes > restored_info.live_bytes);
    OuroTerminalMemoryInfo before_restored_formatter = restored_info;
    text = plain_text(restored, &text_length);
    free(text);
    OuroTerminalMemoryInfo after_restored_formatter = memory_info(restored);
    assert(after_restored_formatter.live_bytes ==
           before_restored_formatter.live_bytes);
    assert(after_restored_formatter.peak_bytes >=
           before_restored_formatter.peak_bytes);

    printf(
        "ABI v6 memory: create_min=%zu restore_min=%zu "
        "source_live=%zu source_peak=%zu restored_live=%zu "
        "restored_peak=%zu limit=%zu resize_failures=%llu\n",
        minimum,
        low,
        after_snapshot.live_bytes,
        after_snapshot.peak_bytes,
        after_restored_formatter.live_bytes,
        after_restored_formatter.peak_bytes,
        after_restored_formatter.limit_bytes,
        (unsigned long long)after_failure.allocation_failures);

    free(encoded);
    ouro_terminal_free(restored);
    ouro_terminal_free(terminal);
}

static void test_input_and_selection_lane(void) {
    OuroTerminalConfig config = test_config();
    config.columns = 20;
    config.rows = 4;
    OuroTerminal *terminal = NULL;
    assert(ouro_terminal_new(&config, &terminal) == OURO_TERMINAL_OK);

    OuroTerminalInputConfig input_config = {
        .size = sizeof(OuroTerminalInputConfig),
        .abi_version = OURO_TERMINAL_ENGINE_ABI_VERSION,
        .option_as_alt = OURO_TERMINAL_OPTION_AS_ALT_TRUE,
    };
    OuroTerminalInput *input = NULL;
    assert(ouro_terminal_input_new(terminal, &input_config, &input) ==
           OURO_TERMINAL_OK);

    OuroTerminalInputConfig old_abi = input_config;
    old_abi.abi_version = 5;
    OuroTerminalInput *untouched = (OuroTerminalInput *)(uintptr_t)1;
    assert(ouro_terminal_input_new(terminal, &old_abi, &untouched) ==
           OURO_TERMINAL_INVALID_ARGUMENT);
    assert(untouched == (OuroTerminalInput *)(uintptr_t)1);
    old_abi.abi_version = 7;
    assert(ouro_terminal_input_new(terminal, &old_abi, &untouched) ==
           OURO_TERMINAL_INVALID_ARGUMENT);

    OuroTerminalKeyEvent key = {
        .size = sizeof(OuroTerminalKeyEvent),
        .abi_version = OURO_TERMINAL_ENGINE_ABI_VERSION,
        .hid_usage = 0x52,
        .action = OURO_TERMINAL_KEY_PRESS,
    };
    uint8_t output[128] = {0};
    size_t length = 0;
    assert(ouro_terminal_input_encode_key(
               input, &key, output, sizeof(output), &length) ==
           OURO_TERMINAL_OK);
    assert(length == 3 && memcmp(output, "\033[A", 3) == 0);
    feed(terminal, "\033[?1h");
    assert(ouro_terminal_input_encode_key(
               input, &key, output, sizeof(output), &length) ==
           OURO_TERMINAL_OK);
    assert(length == 3 && memcmp(output, "\033OA", 3) == 0);

    const uint8_t paste[] = "hello\033world";
    uint8_t paste_before[sizeof(paste)];
    memcpy(paste_before, paste, sizeof(paste));
    feed(terminal, "\033[?2004h");
    assert(ouro_terminal_input_encode_paste(
               input,
               paste,
               sizeof(paste) - 1,
               output,
               sizeof(output),
               &length) == OURO_TERMINAL_OK);
    assert(memcmp(paste, paste_before, sizeof(paste)) == 0);
    assert(length == sizeof(paste) - 1 + 12);
    bool safe = true;
    assert(ouro_terminal_input_paste_is_safe(
               input,
               (const uint8_t *)"x\ry",
               3,
               &safe) == OURO_TERMINAL_OK);
    assert(!safe);

    OuroTerminalMouseGeometry mouse_geometry = {
        .size = sizeof(OuroTerminalMouseGeometry),
        .abi_version = OURO_TERMINAL_ENGINE_ABI_VERSION,
        .screen_width = 800,
        .screen_height = 600,
        .cell_width = 8,
        .cell_height = 16,
    };
    assert(ouro_terminal_input_set_mouse_geometry(
               input, &mouse_geometry) == OURO_TERMINAL_OK);
    feed(terminal, "\033[?1003h\033[?1006h");
    OuroTerminalMouseEvent mouse = {
        .size = sizeof(OuroTerminalMouseEvent),
        .abi_version = OURO_TERMINAL_ENGINE_ABI_VERSION,
        .action = OURO_TERMINAL_MOUSE_MOTION,
        .button = OURO_TERMINAL_MOUSE_BUTTON_NONE,
        .x = 17,
        .y = 17,
    };
    assert(ouro_terminal_input_encode_mouse(
               input, &mouse, NULL, 0, &length) ==
           OURO_TERMINAL_BUFFER_TOO_SMALL);
    assert(length > 0 && length <= sizeof(output));
    const size_t required = length;
    assert(ouro_terminal_input_encode_mouse(
               input, &mouse, output, required, &length) ==
           OURO_TERMINAL_OK);
    assert(length == required);
    assert(ouro_terminal_input_encode_mouse(
               input, &mouse, output, sizeof(output), &length) ==
           OURO_TERMINAL_OK);
    assert(length == 0);

    OuroTerminalSelectionConfig selection_config = {
        .size = sizeof(OuroTerminalSelectionConfig),
        .abi_version = OURO_TERMINAL_ENGINE_ABI_VERSION,
        .copy_max_bytes = 1024,
        .repeat_distance_px = 5,
        .repeat_interval_ns = 500000000,
    };
    OuroTerminalSelection *selection = NULL;
    assert(ouro_terminal_selection_new(
               terminal, &selection_config, &selection) ==
           OURO_TERMINAL_OK);
    feed(terminal, "\033c");
    feed(terminal, "hello world\r\nsecond line");
    OuroTerminalSelectionPoint start = {
        .size = sizeof(OuroTerminalSelectionPoint),
        .abi_version = OURO_TERMINAL_ENGINE_ABI_VERSION,
        .column = 0,
        .row = 0,
        .surface_x = 2,
        .surface_y = 8,
        .has_time = true,
        .time_ns = 1,
    };
    assert(ouro_terminal_selection_begin(selection, &start) ==
           OURO_TERMINAL_NO_VALUE);
    OuroTerminalSelectionPoint end = start;
    end.column = 4;
    end.surface_x = 46;
    end.has_time = false;
    OuroTerminalSelectionGeometry geometry = {
        .size = sizeof(OuroTerminalSelectionGeometry),
        .abi_version = OURO_TERMINAL_ENGINE_ABI_VERSION,
        .columns = 20,
        .cell_width = 10,
        .screen_height = 40,
    };
    assert(ouro_terminal_selection_update(
               selection, &end, &geometry, false) == OURO_TERMINAL_OK);
    assert(ouro_terminal_selection_copy(
               selection, output, sizeof(output), &length) ==
           OURO_TERMINAL_OK);
    assert(length == 5 && memcmp(output, "hello", 5) == 0);
    assert(ouro_terminal_selection_end(selection, &end) ==
           OURO_TERMINAL_NO_VALUE);
    assert(ouro_terminal_selection_cancel(selection) == OURO_TERMINAL_OK);
    assert(ouro_terminal_selection_copy(
               selection, output, sizeof(output), &length) ==
           OURO_TERMINAL_NO_VALUE);

    ouro_terminal_selection_free(selection);
    ouro_terminal_input_free(input);
    ouro_terminal_free(terminal);
}

static void test_viewport_and_scrollbar(void) {
    OuroTerminalConfig config = test_config();
    config.columns = 12;
    config.rows = 4;
    OuroTerminal *terminal = NULL;
    assert(ouro_terminal_new(&config, &terminal) == OURO_TERMINAL_OK);

    char line[32];
    for (unsigned int i = 0; i < 24; ++i) {
        int count = snprintf(line, sizeof(line), "history-%02u\r\n", i);
        assert(count > 0 && (size_t)count < sizeof(line));
        feed(terminal, line);
    }

    OuroTerminalScrollbar bottom = scrollbar(terminal);
    assert(bottom.length == config.rows);
    assert(bottom.total > bottom.length);
    assert(bottom.offset == bottom.total - bottom.length);

    OuroTerminalScrollViewport viewport = {
        .size = sizeof(OuroTerminalScrollViewport),
        .abi_version = OURO_TERMINAL_ENGINE_ABI_VERSION,
        .kind = OURO_TERMINAL_SCROLL_VIEWPORT_TOP,
    };
    assert(ouro_terminal_scroll_viewport(terminal, &viewport) ==
           OURO_TERMINAL_OK);
    assert(scrollbar(terminal).offset == 0);

    viewport.kind = OURO_TERMINAL_SCROLL_VIEWPORT_DELTA;
    viewport.delta = 2;
    assert(ouro_terminal_scroll_viewport(terminal, &viewport) ==
           OURO_TERMINAL_OK);
    assert(scrollbar(terminal).offset == 2);
    viewport.delta = -1;
    assert(ouro_terminal_scroll_viewport(terminal, &viewport) ==
           OURO_TERMINAL_OK);
    assert(scrollbar(terminal).offset == 1);

    viewport.kind = OURO_TERMINAL_SCROLL_VIEWPORT_ROW;
    viewport.delta = 0;
    viewport.row = UINT64_MAX;
    assert(ouro_terminal_scroll_viewport(terminal, &viewport) ==
           OURO_TERMINAL_OK);
    assert(scrollbar(terminal).offset == bottom.total - bottom.length);
    viewport.row = 3;
    assert(ouro_terminal_scroll_viewport(terminal, &viewport) ==
           OURO_TERMINAL_OK);
    assert(scrollbar(terminal).offset == 3);

    viewport.kind = OURO_TERMINAL_SCROLL_VIEWPORT_BOTTOM;
    viewport.row = 0;
    assert(ouro_terminal_scroll_viewport(terminal, &viewport) ==
           OURO_TERMINAL_OK);
    assert(scrollbar(terminal).offset == bottom.total - bottom.length);

    /* Every request field is validated; inactive union-like fields are zero. */
    OuroTerminalScrollViewport invalid = viewport;
    invalid.size--;
    assert(ouro_terminal_scroll_viewport(terminal, &invalid) ==
           OURO_TERMINAL_INVALID_ARGUMENT);
    invalid = viewport;
    invalid.abi_version--;
    assert(ouro_terminal_scroll_viewport(terminal, &invalid) ==
           OURO_TERMINAL_INVALID_ARGUMENT);
    invalid = viewport;
    invalid.kind = (OuroTerminalScrollViewportKind)99;
    assert(ouro_terminal_scroll_viewport(terminal, &invalid) ==
           OURO_TERMINAL_INVALID_ARGUMENT);
    invalid = viewport;
    invalid.delta = 1;
    assert(ouro_terminal_scroll_viewport(terminal, &invalid) ==
           OURO_TERMINAL_INVALID_ARGUMENT);
    invalid = viewport;
    invalid.kind = OURO_TERMINAL_SCROLL_VIEWPORT_DELTA;
    invalid.row = 1;
    assert(ouro_terminal_scroll_viewport(terminal, &invalid) ==
           OURO_TERMINAL_INVALID_ARGUMENT);
    assert(ouro_terminal_scroll_viewport(NULL, &viewport) ==
           OURO_TERMINAL_INVALID_ARGUMENT);
    assert(ouro_terminal_scroll_viewport(terminal, NULL) ==
           OURO_TERMINAL_INVALID_ARGUMENT);

    OuroTerminalScrollbar invalid_out = {
        .size = sizeof(OuroTerminalScrollbar) - 1,
        .abi_version = OURO_TERMINAL_ENGINE_ABI_VERSION,
        .total = 101,
        .offset = 102,
        .length = 103,
    };
    assert(ouro_terminal_scrollbar(terminal, &invalid_out) ==
           OURO_TERMINAL_INVALID_ARGUMENT);
    assert(invalid_out.total == 101 && invalid_out.offset == 102 &&
           invalid_out.length == 103);
    invalid_out.size = sizeof(OuroTerminalScrollbar);
    invalid_out.abi_version--;
    assert(ouro_terminal_scrollbar(terminal, &invalid_out) ==
           OURO_TERMINAL_INVALID_ARGUMENT);
    assert(ouro_terminal_scrollbar(NULL, &invalid_out) ==
           OURO_TERMINAL_INVALID_ARGUMENT);
    assert(ouro_terminal_scrollbar(terminal, NULL) ==
           OURO_TERMINAL_INVALID_ARGUMENT);

    /* Alternate screen exposes only its active rows and clamps every move. */
    feed(terminal, "\033[?1049halternate");
    viewport.kind = OURO_TERMINAL_SCROLL_VIEWPORT_TOP;
    assert(ouro_terminal_scroll_viewport(terminal, &viewport) ==
           OURO_TERMINAL_OK);
    OuroTerminalScrollbar alternate = scrollbar(terminal);
    assert(alternate.total == alternate.length);
    assert(alternate.offset == 0);

    ouro_terminal_free(terminal);
}

int main(void) {
    assert(OURO_TERMINAL_ENGINE_ABI_VERSION == 6u);
    test_complete_snapshot_round_trip();
    test_unfinished_continuation();
    test_fail_closed_inputs();
    test_incremental_idle_compression();
    test_shared_page_budget();
    test_detached_render_projection();
    test_render_projection_rebind_and_budget();
    test_hard_memory_budget();
    test_input_and_selection_lane();
    test_viewport_and_scrollbar();
    puts("libghostty Gate 0 snapshot/accounting/compression/render/input ABI v6 conformance: PASS");
    return 0;
}
