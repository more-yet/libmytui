#include "terminal_cells.h"

static uint32_t color(VTermColor value) {
    if (value.type & VTERM_COLOR_DEFAULT_MASK) return 0;
    if (VTERM_COLOR_IS_INDEXED(&value)) return 0x1000000 | value.indexed.idx;
    return 0x2000000 | value.rgb.red << 16 | value.rgb.green << 8 | value.rgb.blue;
}

int test_vterm_cell(VTermScreen *screen, VTermPos pos, TestCell *cell) {
    VTermScreenCell source = {0};
    if (!vterm_screen_get_cell(screen, pos, &source)) return 0;
    for (size_t i = 0; i < VTERM_MAX_CHARS_PER_CELL; i++) cell->chars[i] = source.chars[i];
    cell->width = source.width;
    if (source.chars[0] == UINT32_MAX) {
        cell->chars[0] = 0;
        cell->width = 0;
        pos.col--;
        if (!vterm_screen_get_cell(screen, pos, &source)) return 0;
    } else if (source.chars[0] == 0) {
        cell->chars[0] = ' ';
    }
    cell->foreground = color(source.fg);
    cell->background = color(source.bg);
    cell->attributes = source.attrs.bold | (source.attrs.italic << 1) |
        ((source.attrs.underline != 0) << 2) | (source.attrs.reverse << 3);
    return 1;
}
