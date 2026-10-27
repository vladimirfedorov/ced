// ced: code editor
//
// Build:  ldc2 -O -i -Isrc src/ced/main.d -of=ced
// Usage:  ./ced filename
//
// Keys:   arrows, Home/End, PgUp/PgDn  move the cursor
//         Alt+s or Ctrl+s  save
//         Alt+q or Ctrl+q  quit; asks again if there are unsaved changes

module ced.main;

import core.sys.posix.unistd : isatty, STDIN_FILENO, STDOUT_FILENO;
import std.stdio : stderr;
import ced.editor;

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
