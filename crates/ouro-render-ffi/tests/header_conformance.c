#include "ouro_render_client.h"
#include "ouro_split_layout.h"

typedef OuroRenderClientResult (*SelectionBeginFn)(
    OuroRenderClient *,
    const OuroRenderClientProjectionContext *,
    const OuroRenderClientSelectionPoint *,
    OuroRenderClientSelectionOutcome *);
typedef OuroRenderClientResult (*SelectionUpdateFn)(
    OuroRenderClient *,
    const OuroRenderClientProjectionContext *,
    const OuroRenderClientSelectionPoint *,
    const OuroRenderClientSelectionGeometry *,
    uint8_t,
    OuroRenderClientSelectionOutcome *);
typedef OuroRenderClientResult (*SelectionAutoscrollFn)(
    OuroRenderClient *,
    const OuroRenderClientProjectionContext *,
    uint16_t,
    uint32_t,
    double,
    double,
    const OuroRenderClientSelectionGeometry *,
    uint8_t,
    OuroRenderClientSelectionOutcome *);
typedef OuroRenderClientResult (*SelectionEndFn)(
    OuroRenderClient *,
    const OuroRenderClientProjectionContext *,
    const OuroRenderClientSelectionPoint *,
    OuroRenderClientSelectionOutcome *);
typedef OuroRenderClientResult (*SelectionCancelFn)(
    OuroRenderClient *,
    const OuroRenderClientProjectionContext *,
    OuroRenderClientSelectionOutcome *);
typedef OuroRenderClientResult (*SelectionCopyFn)(
    OuroRenderClient *,
    const OuroRenderClientProjectionContext *,
    uint8_t *,
    size_t,
    size_t *);
typedef OuroRenderClientResult (*ViewportScrollFn)(
    OuroRenderClient *,
    const OuroRenderClientProjectionContext *,
    const OuroRenderClientViewportScroll *);
typedef OuroRenderClientResult (*ScrollbarFn)(
    OuroRenderClient *,
    const OuroRenderClientProjectionContext *,
    OuroRenderClientScrollbar *);
typedef OuroSplitLayoutResult (*SplitNewFn)(
    const OuroSplitLayoutConfig *,
    const OuroSplitTerminalId *,
    OuroSplitLayout **);
typedef OuroSplitLayoutResult (*SplitGeometryFn)(
    OuroSplitLayout *,
    uint64_t,
    OuroSplitLeafGeometry *,
    size_t,
    size_t *);
typedef OuroSplitLayoutResult (*SplitMutationFn)(
    OuroSplitLayout *,
    OuroSplitAxis,
    const OuroSplitTerminalId *,
    OuroSplitPlacement,
    uint64_t *);
typedef OuroSplitLayoutResult (*SplitCommitFn)(
    OuroSplitLayout *,
    OuroSplitTerminalId *,
    size_t,
    OuroSplitResizeIntent *);

int main(void) {
    SelectionBeginFn begin = ouro_render_client_active_selection_begin;
    SelectionUpdateFn update = ouro_render_client_active_selection_update;
    SelectionAutoscrollFn autoscroll =
        ouro_render_client_active_selection_autoscroll;
    SelectionEndFn end = ouro_render_client_active_selection_end;
    SelectionCancelFn cancel = ouro_render_client_active_selection_cancel;
    SelectionCopyFn copy = ouro_render_client_active_selection_copy;
    ViewportScrollFn viewport_scroll =
        ouro_render_client_active_viewport_scroll;
    ScrollbarFn scrollbar = ouro_render_client_active_scrollbar;
    SplitNewFn split_new = ouro_split_layout_new;
    SplitGeometryFn split_geometry = ouro_split_layout_copy_leaf_geometries;
    SplitMutationFn split_mutation = ouro_split_layout_split_focused;
    SplitCommitFn split_commit = ouro_split_layout_commit_divider_drag;
    (void)begin;
    (void)update;
    (void)autoscroll;
    (void)end;
    (void)cancel;
    (void)copy;
    (void)viewport_scroll;
    (void)scrollbar;
    (void)split_new;
    (void)split_geometry;
    (void)split_mutation;
    (void)split_commit;
    return OURO_RENDER_CLIENT_ABI_VERSION == 1u &&
                   OURO_RENDER_CLIENT_NO_VALUE == 14 &&
                   OURO_RENDER_SELECTION_COPY_MAX_BYTES == 1024u * 1024u &&
                   OURO_RENDER_CLIENT_VIEWPORT_SCROLL_TOP == 0 &&
                   OURO_RENDER_CLIENT_VIEWPORT_SCROLL_BOTTOM == 1 &&
                   OURO_RENDER_CLIENT_VIEWPORT_SCROLL_DELTA == 2 &&
                   OURO_RENDER_CLIENT_VIEWPORT_SCROLL_ROW == 3 &&
                   OURO_SPLIT_LAYOUT_ABI_VERSION == 1u &&
                   OURO_SPLIT_TERMINAL_ID_MAX_BYTES == 256u &&
                   OURO_SPLIT_LAYOUT_MAX_LEAVES == 32u &&
                   OURO_SPLIT_LAYOUT_UNITS == 1000000u &&
                   OURO_SPLIT_LAYOUT_STALE_SNAPSHOT == 7 &&
                   OURO_SPLIT_RESIZE_KEYBOARD == 1
               ? 0
               : 1;
}
