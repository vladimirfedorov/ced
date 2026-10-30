// ve: code editor
//
// Build:  ldc2 -O -i -Isrc src/ve/main.d -of=ve
// Usage:  ./ve filename
//
// Keys:   arrows, Home/End, PgUp/PgDn  move the cursor
//         Alt+s or Ctrl+s  save
//         Alt+q or Ctrl+q  quit; asks again if there are unsaved changes
// Custom keys: ~/.config/ve/keys

module ve.main;

import core.sys.posix.unistd : isatty, STDIN_FILENO, STDOUT_FILENO;
import std.stdio : stderr;
import ve.commands;
import ve.editor;

int main(string[] args) {
    if (args.length != 2) {
        stderr.writeln("usage: ve filename");
        return 2;
    }
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) {
        stderr.writeln("ve: must be run in a terminal");
        return 1;
    }
    try {
        Editor editor = new Editor;
        editor.open(args[1]);
        if (string error = loadKeys(editor.keymap)) editor.message = error;
        editor.run();
    } catch (Exception e) {
        stderr.writeln("ve: ", e.msg);
        return 1;
    }
    return 0;
}
