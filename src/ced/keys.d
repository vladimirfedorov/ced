module ced.keys;

// Key codes: values below 0x110000 are Unicode code points (including control characters)
// the rest are keys that have no character
enum: int {
    keyNone = -1,
    keyLeft = 0x110000, keyRight, keyUp, keyDown,
    keyHome, keyEnd, keyPageUp, keyPageDown, keyDelete,
    keyF1, keyF2, keyF3, keyF4, keyF5, keyF6, keyF7, keyF8, keyF9, keyF10, keyF11, keyF12,

    altFlag   = 0x200000,   // OR-ed with the character for Alt+key
    ctrlFlag  = 0x400000,   // OR-ed with keys that have no character, for Ctrl+key
    shiftFlag = 0x800000,   // OR-ed with keys that have no character, for Shift+key
    ctrlMask  =  0x1f       // AND-mask for Ctrl+key
}

int ctrl(char c) { return c & ctrlMask; }
int alt(char c)  { return c | altFlag;  }
