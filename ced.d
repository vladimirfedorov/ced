// ced: code editor
//
// Build:  ldc2 -O ced.d -of=ced
// Usage:  ./ced filename
//
// Keys:   arrows, Home/End, PgUp/PgDn  move the cursor
//         Alt+s or Ctrl+s  save
//         Alt+q or Ctrl+q  quit; asks again if there are unsaved changes

module ced;

import core.stdc.errno : errno, EAGAIN, EINTR;
import core.sys.posix.sys.ioctl : ioctl, winsize, TIOCGWINSZ;
import core.sys.posix.termios;
import core.sys.posix.unistd : read, write, isatty, STDIN_FILENO, STDOUT_FILENO;
import std.algorithm : canFind, map, min;
import std.algorithm.mutation : remove;
import std.array : Appender, appender, insertInPlace, join, split;
import std.conv : to;
import std.file : exists, readText, writeFile = write;
import std.format : format;
import std.stdio : stderr;
import std.string : indexOf;
import std.utf : decode, UTFException;

enum tabStop = 4;

// Key codes: values below 0x110000 are Unicode code points (including control characters)
// the rest are keys that have no character
enum: int {
    keyNone = -1,
    keyLeft = 0x110000, keyRight, keyUp, keyDown,
    keyHome, keyEnd, keyPageUp, keyPageDown, keyDelete,
    altFlag = 0x200000, // OR-ed with the character for Alt+key
}

int ctrl(char c) { return c & 0x1f; }

// - Terminal -----------------------------------------------------------------

termios origTermios;

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

// - Editor -------------------------------------------------------------------

final class Editor {
    string filename;
    dchar[][] lines = [[]];
    bool crlf;              // the file used "\r\n"; keep it that way on save
    bool dirty;
    size_t cx, cy;          // cursor: index into lines[cy], line index
    size_t rowOff, colOff;  // first visible line and screen column
    int termRows, termCols;
    size_t screenRows, screenCols; // text area, excluding the two bottom bars
    string message;
    bool quitPending;       // Alt-Q was pressed once with unsaved changes
    bool running = true;

    void open(string path) {
        filename = path;
        if (!exists(path)) {
            message = "New file";
            return;
        }
        string text;
        try {
            text = readText(path);
        } catch (UTFException) {
            throw new Exception(path ~ " is not valid UTF-8 text");
        }

        crlf = text.canFind("\r\n");
        lines = null;
        foreach (line; text.split('\n')) {
            if (crlf && line.length && line[$ - 1] == '\r') line = line[0 .. $ - 1];
            lines ~= line.to!(dchar[]);
        }
        if (lines.length == 0) lines = [[]];
    }

    void save() {
        string text = lines.map!(l => l.to!string).join(crlf ? "\r\n" : "\n");
        try {
            writeFile(filename, text);
            dirty = false;
            message = format("Saved %s (%d bytes)", filename, text.length);
        } catch (Exception e) {
            message = "Save failed: " ~ e.msg;
        }
    }

    void run() {
        enableRawMode();
        scope(exit) disableRawMode();
        writeAll("\x1b[?1049h");             // switch to the alternate screen
        scope(exit) writeAll("\x1b[?1049l"); // and give the shell its screen back

        refresh();
        while (running) {
            int key = readKey();
            if (key == keyNone) {
                if (sizeChanged())
                    refresh();
                continue;
            }
            processKey(key);
            if (running) refresh();
        }
    }

    void processKey(int key) {
        bool confirmQuit = quitPending;
        quitPending = false;
        message = null;

        switch (key) {
            case altFlag | 'q', altFlag | 'Q', ctrl('q'):
                if (dirty && !confirmQuit)
                {
                    message = "Unsaved changes, Alt+q again to quit without saving, Alt+s to save.";
                    quitPending = true;
                }
                else
                    running = false;
                break;
            case altFlag | 's', altFlag | 'S', ctrl('s'):
                save();
                break;
            case '\r': // Enter arrives as CR because ICRNL is off
                insertNewline();
                break;
            case 0x7F, ctrl('h'): // Backspace
                deleteBack();
                break;
            case keyDelete:
                deleteForward();
                break;
            case keyLeft, keyRight, keyUp, keyDown, keyHome, keyEnd, keyPageUp, keyPageDown:
                moveCursor(key);
                break;
            case '\t':
                insertChar('\t');
                break;
            default:
                // Printable characters only; other control and Alt keys are ignored.
                if (key >= 0x20 && key != 0x7F && key < 0x110000)
                    insertChar(cast(dchar) key);
                break;
        }
    }

    // - Editor Commands ------------------------------------------------------

    void insertChar(dchar c) {
        lines[cy].insertInPlace(cx, c);
        cx++;
        dirty = true;
    }

    void insertNewline() {
        dchar[] rest = lines[cy][cx .. $].dup;
        lines[cy] = lines[cy][0 .. cx];
        lines.insertInPlace(cy + 1, rest);
        cy++;
        cx = 0;
        dirty = true;
    }

    void deleteBack() {
        if (cx > 0) {
            lines[cy] = lines[cy].remove(cx - 1);
            cx--;
        } else if (cy > 0) {
            cx = lines[cy - 1].length;
            lines[cy - 1] ~= lines[cy];
            lines = lines.remove(cy);
            cy--;
        } else {
            return;
        }
        dirty = true;
    }

    void deleteForward() {
        if (cx < lines[cy].length) {
            lines[cy] = lines[cy].remove(cx);
        } else if (cy + 1 < lines.length) {
            lines[cy] ~= lines[cy + 1];
            lines = lines.remove(cy + 1);
        } else {
            return;
        }
        dirty = true;
    }

    void moveCursor(int key) {
        switch (key) {
            case keyLeft:
                if (cx > 0) {
                    cx--;
                } else if (cy > 0) {
                    cx = lines[--cy].length;
                }
                break;
            case keyRight:
                if (cx < lines[cy].length) {
                    cx++;
                } else if (cy + 1 < lines.length) {
                    cy++;
                    cx = 0;
                }
                break;
            case keyUp:
                if (cy > 0) cy--;
                break;
            case keyDown:
                if (cy + 1 < lines.length) cy++;
                break;
            case keyHome:
                cx = 0;
                break;
            case keyEnd:
                cx = lines[cy].length;
                break;
            case keyPageUp:
                cy = cy > screenRows ? cy - screenRows : 0;
                break;
            case keyPageDown:
                cy = min(cy + screenRows, lines.length - 1);
                break;
            default:
                break;
        }
        cx = min(cx, lines[cy].length);
    }

    // - Rendering ------------------------------------------------------------

    void updateSize() {
        int rows = 24, cols = 80;
        getWindowSize(rows, cols);
        termRows = rows;
        termCols = cols;
        screenRows = rows > 2 ? rows - 2 : 1;
        screenCols = cols > 0 ? cols : 1;
    }

    bool sizeChanged() {
        int rows = termRows, cols = termCols;
        getWindowSize(rows, cols);
        return rows != termRows || cols != termCols;
    }

    // Screen column of character index `idx`, with tabs expanded.
    static size_t renderCol(const(dchar)[] line, size_t idx) {
        size_t rx = 0;
        foreach (c; line[0 .. idx]) rx = c == '\t' ? (rx / tabStop + 1) * tabStop : rx + 1;
        return rx;
    }

    void scroll() {
        if (cy < rowOff) rowOff = cy;
        if (cy >= rowOff + screenRows) rowOff = cy - screenRows + 1;
        ulong rx = renderCol(lines[cy], cx);
        if (rx < colOff) colOff = rx;
        if (rx >= colOff + screenCols) colOff = rx - screenCols + 1;
    }

    void refresh() {
        updateSize();
        scroll();

        Appender!string buf = appender!string;
        buf ~= "\x1b[?25l\x1b[H"; // hide the cursor while drawing, go home
        foreach (y; 0 .. screenRows) {
            ulong lineNo = rowOff + y;
            if (lineNo < lines.length) {
                drawLine(buf, lines[lineNo]);
            } else {
                buf ~= "\x1b[2m~\x1b[m"; // dim marker for lines past the end
            }
            buf ~= "\x1b[K\r\n";
        }
        drawStatusBar(buf);
        drawMessageBar(buf);
        buf ~= format("\x1b[%d;%dH\x1b[?25h", cy - rowOff + 1, renderCol(lines[cy], cx) - colOff + 1);
        writeAll(buf.data);
    }

    void drawLine(ref Appender!string buf, const(dchar)[] line) {
        size_t col = 0;
        foreach (c; line) {
            size_t width = c == '\t' ? tabStop - col % tabStop : 1;
            foreach (_; 0 .. width) {
                if (col >= colOff + screenCols) return;
                if (col >= colOff) {
                    if (c == '\t') {
                        buf ~= ' ';
                    } else if (c < 0x20 || (c >= 0x7F && c < 0xA0)) {
                        // Show control characters as an inverted letter rather
                        // than letting the terminal interpret them.
                        buf ~= "\x1b[7m";
                        buf ~= c < 0x20 ? cast(char)('@' + c) : '?';
                        buf ~= "\x1b[m";
                    } else {
                        buf ~= c;
                    }
                }
                col++;
            }
        }
    }

    void drawStatusBar(ref Appender!string buf) {
        dchar[] left = format(" %s%s", filename, dirty ? " [modified]" : "").to!(dchar[]);
        dchar[] right = format("Ln %d/%d, Col %d ", cy + 1, lines.length, cx + 1).to!(dchar[]);
        dchar[] bar = new dchar[](screenCols);
        bar[] = ' ';
        if (right.length <= bar.length) bar[$ - right.length .. $] = right[];
        ulong n = min(left.length, bar.length);
        bar[0 .. n] = left[0 .. n];
        buf ~= "\x1b[7m";
        buf ~= bar.to!string;
        buf ~= "\x1b[m\r\n";
    }

    void drawMessageBar(ref Appender!string buf) {
        dchar[] text = (message.length ? message : "Alt+s save | Alt+q quit").to!(dchar[]);
        buf ~= text[0 .. min(text.length, screenCols)].to!string;
        buf ~= "\x1b[K";
    }
}

int main(string[] args) {
    if (args.length != 2) {
        stderr.writeln("usage: ced filename");
        return 2;
    }
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) {
        stderr.writeln("ced: must be run in a terminal");
        return 1;
    }
    try {
        Editor editor = new Editor;
        editor.open(args[1]);
        editor.run();
    } catch (Exception e) {
        stderr.writeln("ced: ", e.msg);
        return 1;
    }
    return 0;
}
