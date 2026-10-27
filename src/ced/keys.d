module ced.keys;

import std.utf : decode, UTFException;

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

// Named keys
private immutable int[string] namedKeys = [
    "left":   keyLeft, "right": keyRight, "up":     keyUp,     "down":     keyDown,
    "home":   keyHome, "end":   keyEnd,   "pageup": keyPageUp, "pagedown": keyPageDown,
    "delete": keyDelete,
    "f1": keyF1, "f2": keyF2, "f3": keyF3, "f4":  keyF4,  "f5":  keyF5,  "f6":  keyF6,
    "f7": keyF7, "f8": keyF8, "f9": keyF9, "f10": keyF10, "f11": keyF11, "f12": keyF12,
    "tab": '\t', "enter": '\r', "backspace": 0x7F, "esc": 0x1B, "space": ' ',
];

// Parses a key string (e.g. "ctrl+s", "alt+Q", "alt++", "ctrl+alt+right", "f2")
// - alt+Q is alt + shift + q
// - ctrl+S is recognized as ctrl+s
// - ctrl works with characters only when terminal send a control code for it
// - shift works with keys that have no character
// keyNone when key is not recognized
int parseKey(string s) {
    // Compares bytes rather than decoded characters, so invalid UTF-8 doesn't throw
    bool skip(string prefix) {
        if (s.length < prefix.length || s[0 .. prefix.length] != prefix) return false;
        s = s[prefix.length .. $];
        return true;
    }

    bool ctrlMod, altMod, shiftMod;
    for (;;) {
        if (skip("ctrl+"))       ctrlMod = true;
        else if (skip("alt+"))   altMod = true;
        else if (skip("shift+")) shiftMod = true;
        else break;
    }
    if (s.length == 0) return keyNone;

    int key;
    if (auto named = s in namedKeys) {
        key = *named;
    } else {
        size_t i = 0;
        try {
            key = decode(s, i);
        } catch (UTFException) {
            return keyNone;
        }
        if (i != s.length) return keyNone;
    }

    bool hasChar = key < 0x110000;
    if (shiftMod) {
        if (hasChar) return keyNone;
        key |= shiftFlag;
    }
    if (ctrlMod) {
        if (!hasChar) {
            key |= ctrlFlag;
        } else if (key == ' ' || (key >= '@' && key <= '_') || (key >= 'a' && key <= 'z')) {
            key = ctrl(cast(char) key);
        } else {
            return keyNone;
        }
    }
    if (altMod) key |= altFlag;
    return key;
}

unittest {
    assert(parseKey("q")          == 'q');
    assert(parseKey("Q")          == 'Q');
    assert(parseKey("+")          == '+');
    assert(parseKey("я")          == 'я');
    assert(parseKey("ctrl+s")     == ctrl('s'));
    assert(parseKey("ctrl+S")     == ctrl('s'));
    assert(parseKey("ctrl+h")     == 0x08);
    assert(parseKey("ctrl+space") == 0);
    assert(parseKey("ctrl+\\")    == 0x1C);
    assert(parseKey("alt+q")      == alt('q'));
    assert(parseKey("alt+Q")      == alt('Q'));
    assert(parseKey("alt++")      == alt('+'));
    assert(parseKey("alt+\\")     == alt('\\'));
    assert(parseKey("alt+я")      == (altFlag | 'я'));
    assert(parseKey("ctrl+alt+s") == (altFlag | ctrl('s')));
    assert(parseKey("enter")      == '\r');
    assert(parseKey("tab")        == '\t');
    assert(parseKey("backspace")  == 0x7F);
    assert(parseKey("esc")        == 0x1B);
    assert(parseKey("space")      == ' ');
    assert(parseKey("right")      == keyRight);
    assert(parseKey("f12")        == keyF12);
    assert(parseKey("shift+up")   == (shiftFlag | keyUp));
    assert(parseKey("ctrl+right") == (ctrlFlag | keyRight));
    assert(parseKey("alt+shift+ctrl+f2") == (ctrlFlag | altFlag | shiftFlag | keyF2));

    // Not a key, or not one that a terminal can tell apart
    foreach (s; ["", "ctrl+", "alt+", "foo", "ab", "f13", "shift+q", "ctrl+shift+s",
                 "ctrl+1", "ctrl+tab", "ctrl+enter", "shift+tab", "\xFF", "alt+\xFF"])
        assert(parseKey(s) == keyNone, s);
}
