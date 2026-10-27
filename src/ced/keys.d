module ced.keys;

// Key codes: values below 0x110000 are Unicode code points (including control characters)
// the rest are keys that have no character
enum: int {
    keyNone = -1,
    keyLeft = 0x110000, keyRight, keyUp, keyDown,
    keyHome, keyEnd, keyPageUp, keyPageDown, keyDelete,
    altFlag = 0x200000, // OR-ed with the character for Alt+key
}

int ctrl(char c) { return c & 0x1f; }
