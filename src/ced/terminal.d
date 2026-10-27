module ced.terminal;

import core.stdc.errno : errno, EAGAIN, EINTR;
import core.sys.posix.sys.ioctl : ioctl, winsize, TIOCGWINSZ;
import core.sys.posix.termios;
import core.sys.posix.unistd : read, write, STDIN_FILENO, STDOUT_FILENO;
import std.string : indexOf;
import std.utf : decode, UTFException;
import ced.keys;

private termios origTermios;

void enableRawMode() {
    if (tcgetattr(STDIN_FILENO, &origTermios) == -1) throw new Exception("tcgetattr failed");
    termios raw = origTermios;
    raw.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    raw.c_oflag &= ~OPOST;
    raw.c_cflag |= CS8;
    raw.c_lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);
    raw.c_cc[VMIN] = 0;
    raw.c_cc[VTIME] = 1; // read() gives up after 100 ms without input
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == -1) throw new Exception("tcsetattr failed");
}

void disableRawMode() {
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &origTermios);
}

void writeAll(const(char)[] s) {
    while (s.length) {
        long n = write(STDOUT_FILENO, s.ptr, s.length);
        if (n < 0) {
            if (errno == EINTR) continue;
            return;
        }
        s = s[n .. $];
    }
}

bool getWindowSize(ref int rows, ref int cols) {
    winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == -1 || ws.ws_col == 0) return false;
    rows = ws.ws_row;
    cols = ws.ws_col;
    return true;
}

// Returns the next input byte, or -1 if none arrived within the timeout
int readByte() {
    ubyte b;
    long n = read(STDIN_FILENO, &b, 1);
    if (n == 1) return b;
    if (n == -1 && errno != EAGAIN && errno != EINTR) throw new Exception("read failed");
    return -1;
}

int readKey() {
    int c = readByte();
    if (c == -1)   return keyNone;
    if (c != 0x1b) return readUtf8(c);

    int next = readByte();
    if (next == -1)  return 0x1b; // a lone Escape press
    if (next == '[') return readCsi();
    // SS3: some terminals send arrows, Home/End and F1-F4 this way
    if (next == 'O') {
        switch (readByte()) {
            case 'A': return keyUp;
            case 'B': return keyDown;
            case 'C': return keyRight;
            case 'D': return keyLeft;
            case 'H': return keyHome;
            case 'F': return keyEnd;
            case 'P': return keyF1;
            case 'Q': return keyF2;
            case 'R': return keyF3;
            case 'S': return keyF4;
            default:  return keyNone;
        }
    }
    // Terminals send Alt+key as Escape followed by the key.
    int key = readUtf8(next);
    return key == keyNone ? keyNone : altFlag | key;
}

// Completes a UTF-8 sequence that starts with `first`.
int readUtf8(int first) {
    if (first < 0x80) return first;
    size_t len = first >= 0xF0 ? 4 : first >= 0xE0 ? 3 : first >= 0xC0 ? 2 : 0;
    if (len == 0) return keyNone;
    char[4] buf;
    buf[0] = cast(char) first;
    foreach (i; 1 .. len) {
        int b = readByte();
        if (b == -1) return keyNone;
        buf[i] = cast(char) b;
    }
    try {
        size_t index = 0;
        return decode(buf[0 .. len], index);
    } catch (UTFException) {
        return keyNone;
    }
}

// Reads the rest of an "ESC [ params final" sequence
// Unknown sequences are consumed to never appear as text
int readCsi() {
    string params;
    int c;
    for (;;) {
        c = readByte();
        if (c == -1) return keyNone;
        if (c >= 0x40 && c <= 0x7E) break;
        params ~= cast(char) c;
    }
    return csiKey(params, cast(char) c);
}

// Key for the parameters and final byte of a CSI sequence.
// xterm sends modifiers as a second parameter
// 1 + bitmask of Shift = 1, Alt = 2, Ctrl = 4: "1;5C" is Ctrl+Right
int csiKey(const(char)[] params, char last) {
    long semi = params.indexOf(';');
    int key;
    switch (last) {
        case 'A': key = keyUp;    break;
        case 'B': key = keyDown;  break;
        case 'C': key = keyRight; break;
        case 'D': key = keyLeft;  break;
        case 'H': key = keyHome;  break;
        case 'F': key = keyEnd;   break;
        case 'P': key = keyF1;    break; // F1-F4 with modifiers, "1;2P" is Shift+F1
        case 'Q': key = keyF2;    break;
        case 'R': key = keyF3;    break;
        case 'S': key = keyF4;    break;
        case '~':
            switch (semi < 0 ? params : params[0 .. semi]) {
                case "1", "7": key = keyHome;     break;
                case "4", "8": key = keyEnd;      break;
                case "3":      key = keyDelete;   break;
                case "5":      key = keyPageUp;   break;
                case "6":      key = keyPageDown; break;
                case "11":     key = keyF1;       break;
                case "12":     key = keyF2;       break;
                case "13":     key = keyF3;       break;
                case "14":     key = keyF4;       break;
                case "15":     key = keyF5;       break;
                case "17":     key = keyF6;       break;
                case "18":     key = keyF7;       break;
                case "19":     key = keyF8;       break;
                case "20":     key = keyF9;       break;
                case "21":     key = keyF10;      break;
                case "23":     key = keyF11;      break;
                case "24":     key = keyF12;      break;
                default: return keyNone;
            }
            break;
        default: return keyNone;
    }
    if (semi < 0) return key;

    int mods = 0;
    foreach (c; params[semi + 1 .. $]) {
        if (c < '0' || c > '9') break;
        mods = mods * 10 + (c - '0');
    }
    if (mods <= 1) return key;
    mods--;
    if (mods & 1) key |= shiftFlag;
    if (mods & 2) key |= altFlag;
    if (mods & 4) key |= ctrlFlag;
    return key;
}

unittest {
    assert(csiKey("", 'C')     == keyRight);
    assert(csiKey("1;1", 'C')  == keyRight);
    assert(csiKey("1;2", 'A')  == (shiftFlag | keyUp));
    assert(csiKey("1;3", 'D')  == (altFlag | keyLeft));
    assert(csiKey("1;5", 'C')  == (ctrlFlag | keyRight));
    assert(csiKey("1;8", 'H')  == (shiftFlag | altFlag | ctrlFlag | keyHome));
    assert(csiKey("3", '~')    == keyDelete);
    assert(csiKey("3;5", '~')  == (ctrlFlag | keyDelete));
    assert(csiKey("1;2", 'P')  == (shiftFlag | keyF1));
    assert(csiKey("11", '~')   == keyF1);
    assert(csiKey("15", '~')   == keyF5);
    assert(csiKey("24;6", '~') == (shiftFlag | ctrlFlag | keyF12));
    assert(csiKey("16", '~')   == keyNone);
    assert(csiKey("", 'Z')     == keyNone);
}
