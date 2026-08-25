#include <metal_stdlib>
using namespace metal;

struct OuroTerminalCellInstance {
    float4 cell_rect;
    float4 glyph_uv;
    float4 foreground;
    float4 background;
    uint terminal_flags;
    uint underline_style;
    uint surface_flags;
    uint decoration_color_bits;
};

struct OuroTerminalUniforms {
    float4 viewport_cell;
    float4 origin_grid;
    uint4 cursor;
    float4 semantic_canvas;
    float4 semantic_foreground;
    float4 semantic_turn_background;
    float4 selection;
    float4 cursor_color;
};

struct OuroTerminalVertexOut {
    float4 position [[position]];
    float2 glyph_uv;
    float2 local;
    float4 foreground;
    float4 background;
    uint terminal_flags [[flat]];
    uint underline_style [[flat]];
    uint surface_flags [[flat]];
    uint decoration_color_bits [[flat]];
    uint2 cell [[flat]];
};

vertex OuroTerminalVertexOut ouro_terminal_vertex(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    const device OuroTerminalCellInstance *instances [[buffer(0)]],
    constant OuroTerminalUniforms &uniforms [[buffer(1)]]) {
    constexpr float2 corners[4] = {
        float2(0.0, 0.0), float2(1.0, 0.0),
        float2(0.0, 1.0), float2(1.0, 1.0)
    };
    const OuroTerminalCellInstance instance = instances[instance_id];
    const float2 corner = corners[vertex_id];
    const float2 viewport = max(uniforms.viewport_cell.xy, float2(1.0));
    const float2 cell_size = uniforms.viewport_cell.zw;
    const float2 pixel = uniforms.origin_grid.xy
        + (instance.cell_rect.xy + corner * instance.cell_rect.zw) * cell_size;
    const float2 ndc = float2(
        pixel.x / viewport.x * 2.0 - 1.0,
        1.0 - pixel.y / viewport.y * 2.0);

    OuroTerminalVertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.glyph_uv = mix(instance.glyph_uv.xy, instance.glyph_uv.zw, corner);
    out.local = corner;
    out.foreground = instance.foreground;
    out.background = instance.background;
    out.terminal_flags = instance.terminal_flags;
    out.underline_style = instance.underline_style;
    out.surface_flags = instance.surface_flags;
    out.decoration_color_bits = instance.decoration_color_bits;
    out.cell = uint2(instance.cell_rect.xy);
    return out;
}

float ouro_srgb_to_linear(float component) {
    return component <= 0.04045
        ? component / 12.92
        : pow((component + 0.055) / 1.055, 2.4);
}

float3 ouro_unpack_linear_rgb(uint packed) {
    const float3 srgb = float3(
        float((packed >> 16) & 0xffu),
        float((packed >> 8) & 0xffu),
        float(packed & 0xffu)
    ) / 255.0;
    return float3(
        ouro_srgb_to_linear(srgb.r),
        ouro_srgb_to_linear(srgb.g),
        ouro_srgb_to_linear(srgb.b)
    );
}

float ouro_luminance(float3 color) {
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

float ouro_contrast(float3 a, float3 b) {
    const float lighter = max(ouro_luminance(a), ouro_luminance(b));
    const float darker = min(ouro_luminance(a), ouro_luminance(b));
    return (lighter + 0.05) / (darker + 0.05);
}

float4 ouro_selection_foreground(float4 background, float4 preferred) {
    if (ouro_contrast(background.rgb, preferred.rgb) >= 4.5) return preferred;
    const float4 black = float4(0.0, 0.0, 0.0, 1.0);
    const float4 white = float4(1.0, 1.0, 1.0, 1.0);
    return ouro_contrast(background.rgb, black.rgb) >= ouro_contrast(background.rgb, white.rgb)
        ? black : white;
}

fragment float4 ouro_terminal_fragment(
    OuroTerminalVertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlas_sampler [[sampler(0)]],
    constant OuroTerminalUniforms &uniforms [[buffer(1)]]) {
    constexpr uint has_glyph = 1u << 0;
    constexpr uint skip_cell = 1u << 1;
    constexpr uint default_foreground = 1u << 2;
    constexpr uint default_background = 1u << 3;
    constexpr uint custom_underline_color = 1u << 4;
    constexpr uint foreground_uses_canvas = 1u << 5;
    constexpr uint background_uses_foreground = 1u << 6;
    constexpr uint semantic_prompt_row = 1u << 7;
    constexpr uint semantic_input = 1u << 8;
    constexpr uint semantic_prompt = 1u << 9;
    constexpr uint semantic_prompt_start_row = 1u << 10;
    constexpr uint selected = 1u << 0;
    constexpr uint faint = 1u << 5;
    constexpr uint blink = 1u << 6;
    constexpr uint invisible = 1u << 8;
    constexpr uint strike = 1u << 9;
    constexpr uint overline = 1u << 10;

    if ((in.surface_flags & skip_cell) != 0) discard_fragment();
    float coverage = 0.0;
    if ((in.surface_flags & has_glyph) != 0 && (in.terminal_flags & invisible) == 0) {
        coverage = atlas.sample(atlas_sampler, in.glyph_uv).r;
        if ((in.terminal_flags & faint) != 0) coverage *= 0.55;
        if ((in.terminal_flags & blink) != 0
            && (uint(uniforms.origin_grid.w) & 1u) == 0u) coverage = 0.0;
    }

    float4 background = (in.surface_flags & default_background) != 0
        ? uniforms.semantic_canvas
        : ((in.surface_flags & background_uses_foreground) != 0
            ? uniforms.semantic_foreground : in.background);
    // Prompt/input metadata remains available to accessibility and focus
    // routing, but it must not recolor terminal rows. ANSI/default palette
    // colors are the single visual source of truth for the terminal surface.
    const bool is_selected = (in.terminal_flags & selected) != 0;
    if (is_selected) background = uniforms.selection;
    float4 foreground = (in.surface_flags & default_foreground) != 0
        ? uniforms.semantic_foreground
        : ((in.surface_flags & foreground_uses_canvas) != 0
            ? uniforms.semantic_canvas : in.foreground);
    if (is_selected) foreground = ouro_selection_foreground(background, foreground);
    float4 color = mix(background, foreground, coverage * foreground.a);
    const float y = in.local.y;
    bool underline_decoration = false;
    if (in.underline_style == 1u) underline_decoration = y > 0.86 && y < 0.93;
    if (in.underline_style == 2u) underline_decoration = (y > 0.80 && y < 0.85) || (y > 0.91 && y < 0.96);
    if (in.underline_style == 3u) underline_decoration = abs(y - (0.88 + 0.035 * sin(in.local.x * 18.8496))) < 0.025;
    if (in.underline_style == 4u) underline_decoration = y > 0.86 && y < 0.93 && fract(in.local.x * 8.0) < 0.42;
    if (in.underline_style == 5u) underline_decoration = y > 0.86 && y < 0.93 && fract(in.local.x * 4.0) < 0.66;
    if (underline_decoration) {
        color = !is_selected && (in.surface_flags & custom_underline_color) != 0
            ? float4(ouro_unpack_linear_rgb(in.decoration_color_bits), 1.0)
            : foreground;
    }
    const bool foreground_decoration =
        ((in.terminal_flags & strike) != 0 && y > 0.47 && y < 0.53)
        || ((in.terminal_flags & overline) != 0 && y > 0.04 && y < 0.10);
    if (foreground_decoration) color = foreground;

    const bool cursor_visible = uniforms.cursor.z != 0u;
    const bool cursor_focused = (uniforms.cursor.z & 2u) != 0u;
    if (cursor_visible && all(in.cell == uniforms.cursor.xy)) {
        const uint style = uniforms.cursor.w;
        const bool hollow_style = style == 3u;
        const bool cursor_pixel = !cursor_focused || hollow_style
            ? (in.local.x < 0.09 || in.local.x > 0.91
                || in.local.y < 0.09 || in.local.y > 0.91)
            : (style == 0u ? in.local.x < 0.14
                : (style == 2u ? in.local.y > 0.84 : true));
        if (cursor_pixel) {
            // A block cursor is still text, not a solid status indicator. Keep
            // the grapheme legible by drawing its coverage in the canvas color.
            color = style == 1u
                ? mix(uniforms.cursor_color, uniforms.semantic_canvas, coverage)
                : uniforms.cursor_color;
        }
    }
    return color;
}
