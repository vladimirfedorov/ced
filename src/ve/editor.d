module ve.editor;

import std.algorithm : canFind, map, min;
import std.algorithm.mutation : remove;
import std.array : Appender, appender, insertInPlace, join, split;
import std.conv : to;
import std.file : exists, readText, writeFile = write;
import std.format : format;
import std.utf : UTFException;
import ve.keys;
import ve.terminal;
import ve.commands;

enum tabStop = 4;

final class Editor {
    string filename;
    dchar[][] lines = [[]];
    bool crlf;                      // the file used "\r\n"; keep it that way on save
    bool dirty;
    size_t cx, cy;                  // cursor: index into lines[cy], line index
    size_t rowOff, colOff;          // first visible line and screen column
    int termRows, termCols;
    size_t screenRows, screenCols;  // text area, excluding the two bottom bars
    string message;
    bool quitPending;               // Alt-Q was pressed once with unsaved changes
    bool running = true;
    Keymap keymap;

    this() {
        keymap = defaultKeymap();
    }

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
                if (sizeChanged()) refresh();
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

        Cmd cmd = keymap.lookup("text", key);
        final switch (cmd) {
            case Cmd.none:
                // display unbound printable characters
                if (key >= 0x20 && key != 0x7F && key < 0x110000) insertChar(cast(dchar) key);
                break;
            case Cmd.quit:
                if (dirty && !confirmQuit) {
                    message = "Unsaved changes, Alt+q again to quit without saving, Alt+s to save.";
                    quitPending = true;
                } else {
                    running = false;
                }
                break;
            case Cmd.save:
                save();
                break;
            case Cmd.newline:
                insertNewline();
                break;
            case Cmd.deleteBack:
                deleteBack();
                break;
            case Cmd.deleteForward:
                deleteForward();
                break;
            case Cmd.cursorLeft, Cmd.cursorRight, Cmd.cursorUp, Cmd.cursorDown,
                 Cmd.lineStart, Cmd.lineEnd, Cmd.pageUp, Cmd.pageDown:
                moveCursor(cmd);
                break;
            case Cmd.insertTab:
                insertChar('\t');
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

    void moveCursor(Cmd cmd) {
        switch (cmd) {
            case Cmd.cursorLeft:
                if (cx > 0) {
                    cx--;
                } else if (cy > 0) {
                    cx = lines[--cy].length;
                }
                break;
            case Cmd.cursorRight:
                if (cx < lines[cy].length) {
                    cx++;
                } else if (cy + 1 < lines.length) {
                    cy++;
                    cx = 0;
                }
                break;
            case Cmd.cursorUp:
                if (cy > 0) cy--;
                break;
            case Cmd.cursorDown:
                if (cy + 1 < lines.length) cy++;
                break;
            case Cmd.lineStart:
                cx = 0;
                break;
            case Cmd.lineEnd:
                cx = lines[cy].length;
                break;
            case Cmd.pageUp:
                cy = cy > screenRows ? cy - screenRows : 0;
                break;
            case Cmd.pageDown:
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
