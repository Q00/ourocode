#include "ouro_terminal_engine.h"

#include <cstddef>
#include <type_traits>

static_assert(OURO_TERMINAL_ENGINE_ABI_VERSION == 6u);
static_assert(std::is_standard_layout_v<OuroTerminalConfig>);
static_assert(sizeof(OuroTerminalConfig) == 80);
static_assert(sizeof(OuroTerminalFrameInfo) == 24);
static_assert(sizeof(OuroTerminalMemoryInfo) == 48);
static_assert(sizeof(OuroTerminalPageBudgetStats) == 56);
static_assert(sizeof(OuroRenderProjectionConfig) == 32);
static_assert(sizeof(OuroRenderProjectionMemoryInfo) == 48);
static_assert(sizeof(OuroRenderRgb) == 3);
static_assert(sizeof(OuroRenderColor) == 8);
static_assert(sizeof(OuroRenderFrameInfo) == 832);
static_assert(sizeof(OuroRenderRowInfo) == 32);
static_assert(sizeof(OuroRenderCellInfo) == 80);
static_assert(sizeof(OuroTerminalInputConfig) == 16);
static_assert(sizeof(OuroTerminalKeyEvent) == 48);
static_assert(sizeof(OuroTerminalMouseGeometry) == 80);
static_assert(sizeof(OuroTerminalMouseEvent) == 40);
static_assert(sizeof(OuroTerminalScrollEvent) == 40);
static_assert(sizeof(OuroTerminalScrollViewportKind) == 4);
static_assert(sizeof(OuroTerminalScrollViewport) == 32);
static_assert(sizeof(OuroTerminalScrollbar) == 40);
static_assert(sizeof(OuroTerminalSelectionConfig) == 40);
static_assert(sizeof(OuroTerminalSelectionPoint) == 56);
static_assert(sizeof(OuroTerminalSelectionGeometry) == 40);

int main() { return 0; }
