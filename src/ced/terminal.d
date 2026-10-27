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
    // SS3: some terminals send arrows and Home/End this way
    if (next == 'O') {
        switch (readByte()) {
            case 'A': return keyUp;
            case 'B': return keyDown;
            case 'C': return keyRight;
            case 'D': return keyLeft;
            case 'H': return keyHome;
            case 'F': return keyEnd;
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
// Unknown sequences, such as Ctrl+arrows, are consumed to never appear as text
int readCsi() {
    string params;
    int c;
    for (;;) {
        c = readByte();
        if (c == -1) return keyNone;
        if (c >= 0x40 && c <= 0x7E) break;
        params ~= cast(char) c;
    }
    switch (c) {
        case 'A': return keyUp;
        case 'B': return keyDown;
        case 'C': return keyRight;
        case 'D': return keyLeft;
        case 'H': return keyHome;
        case 'F': return keyEnd;
        case '~':
            long semi = params.indexOf(';');
            switch (semi < 0 ? params : params[0 .. semi]) {
                case "1", "7": return keyHome;
                case "4", "8": return keyEnd;
                case "3": return keyDelete;
                case "5": return keyPageUp;
                case "6": return keyPageDown;
                default: return keyNone;
            }
        default: return keyNone;
    }
}
