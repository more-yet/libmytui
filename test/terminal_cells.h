#include <vterm.h>

typedef struct {
    uint32_t chars[VTERM_MAX_CHARS_PER_CELL];
    uint32_t width, foreground, background, attributes;
} TestCell;

int test_vterm_cell(VTermScreen *screen, VTermPos pos, TestCell *cell);
