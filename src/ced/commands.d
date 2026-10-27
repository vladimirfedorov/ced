module ced.commands;

import ced.keys;

// Editor actions that keys are bound to
enum Cmd {
    quit, save,
    cursorLeft, cursorRight, cursorUp, cursorDown,
    lineStart, lineEnd, pageUp, pageDown,
    newline, deleteBack, deleteForward, insertTab,
}

// Built-in key bindings
immutable Cmd[int] defaultKeymap = [
    alt('q'):       Cmd.quit,
    ctrl('q'):      Cmd.quit,
    alt('s'):       Cmd.save,
    ctrl('s'):      Cmd.save,
    keyLeft:        Cmd.cursorLeft,
    keyRight:       Cmd.cursorRight,
    keyUp:          Cmd.cursorUp,
    keyDown:        Cmd.cursorDown,
    keyHome:        Cmd.lineStart,
    keyEnd:         Cmd.lineEnd,
    keyPageUp:      Cmd.pageUp,
    keyPageDown:    Cmd.pageDown,
    '\r':           Cmd.newline, // Enter arrives as CR because ICRNL is off
    0x7F:           Cmd.deleteBack,
    ctrl('h'):      Cmd.deleteBack, // Backspace
    keyDelete:      Cmd.deleteForward,
    '\t':           Cmd.insertTab,
];
