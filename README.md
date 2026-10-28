# tmux-bag

Drag a window out of the status bar into a bag, and take it back out when you need it.

## Usage

- **Bag a window.** Press a window in the status bar and drag. A bag pops up at the right end of the status bar. Release over it and the window moves into a detached `bag` session.
- **Open the bag.** Click `bag N` at the right end of the status bar, or press `prefix + B`. Pick a window (or press its number) to move it back to the end of the current session and switch to it.
- **Bag the current window from the keyboard.** Press `prefix + b`.

Release anywhere other than the bag to cancel the drag.

A bagged window keeps running: the plugin moves it to another session and doesn't stop its processes. The `bag` session disappears once it is empty.

The plugin won't bag a session's last window, because moving that window out destroys the session.

## Install (tpm)

Add to `~/.tmux.conf`, with `set -g mouse on`:

```tmux
set -g @plugin 'perzhul/tmux-bag'
```

Then press `prefix + I` to install.

## How it works

- During a drag the status bar grows to three lines. The bag art fills the top two lines, and your original first line moves to the bottom, so the window list stays under the mouse. The plugin saves `status` and `status-format[0..2]` when the drag starts and restores them when it ends.
- The drop zone is a `range=user|bag` status range, appended to the end of `status-right`. The plugin raises `status-right-length` by 16 so the zone doesn't get cut off.
- The plugin wraps the existing `MouseDown1Status`, `MouseUp1Status`, `MouseDrag1Pane`, `MouseDrag1Border` and `MouseDragEnd1Pane` bindings. Each wrapper runs your original command when no drag is in progress. During a drag, crossing a pane does nothing, instead of starting copy-mode and losing the release.
- If a release is lost and the drop zone stays up, the next click on the status bar or a config reload clears it.
