#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAG="$CURRENT_DIR/scripts/bag.sh"
chmod +x "$BAG"

# Defaults only when unset: respect user overrides.
default() { [ -n "$(tmux show-options -gqv "$1")" ] || tmux set-option -g "$1" "$2"; }
default @bag-key 'b'
default @bag-open-key 'B'
default @bag-session 'bag'
default @bag-style 'fg=colour214'
default @bag-silence '30'

# A drag whose release never arrived leaves the drop zone up; a reload clears it.
"$BAG" end

# Prints the command a root key had before tmux-bag wrapped it, or $2 when it
# was unbound. A binding that isn't a tmux-bag wrapper is the user's (first
# load, or a config reload that rebound the key) and gets saved; a wrapper
# means a plain plugin reload, which re-wraps the saved original.
original() {
    local saved="@bag_original_$1" body
    body="$(tmux list-keys -T root "$1" 2>/dev/null | sed -E "s/^bind-key +(-r +)?-T root +$1 +//")"
    case "$body" in
        *"@bag_armed"*) body="$(tmux show-options -gqv "$saved")" ;;
        *) tmux set-option -g "$saved" "${body:-none}" ;;
    esac
    case "$body" in "" | none) body="$2" ;; esac
    echo "$body"
}

# A press on a window entry arms the drag with that window; any release
# without motion disarms it. The first motion after arming starts the drag
# wherever it lands: clicking re-centres the window list, so it can fall
# outside the entry that was pressed.
start="if -F '#{?#{@bag_dragging},0,#{?#{@bag_armed},1,0}}' { run-shell '$BAG start' }"
end="if -F '#{@bag_armed}' { run-shell '$BAG end' }"

# The wrappers keep each original binding for when no drag is armed.
# Crossing a pane or border mid-drag would otherwise start copy-mode or a
# resize, and the release would never reach the bag.
tmux bind-key -n MouseDrag1Pane "if -F '#{@bag_armed}' { $start } { $(original MouseDrag1Pane 'send-keys -M') }"
tmux bind-key -n MouseDrag1Border "if -F '#{@bag_armed}' { $start } { $(original MouseDrag1Border 'resize-pane -M') }"
# tmux forwards an unbound MouseDragEnd1Pane to the pane; send-keys -M does the same.
tmux bind-key -n MouseDragEnd1Pane "if -F '#{@bag_armed}' { run-shell '$BAG end' } { $(original MouseDragEnd1Pane 'send-keys -M') }"
# A press can't arrive mid-drag, so a set flag here means a lost release.
tmux bind-key -n MouseDown1Status "$end ; if -F '#{!=:#{mouse_status_range},bag}' { $(original MouseDown1Status 'switch-client -t =') ; if -F '#{==:#{mouse_status_range},window}' { set-option -gF @bag_armed '#{window_id}' } }"
# The bag opens on release: anything opened on press would get the release.
up="$(original MouseUp1Status '')"
tmux bind-key -n MouseUp1Status "set-option -gu @bag_armed ; if -F '#{==:#{mouse_status_range},bag}' { run-shell '$BAG open #{client_name}' }${up:+ ; $up}"
# The re-centred list can put a gap or status-left/right under a click's release.
for key in MouseUp1StatusLeft MouseUp1StatusRight MouseUp1StatusDefault; do
    up="$(original "$key" '')"
    tmux bind-key -n "$key" "set-option -gu @bag_armed${up:+ ; $up}"
done

# Dragging owns MouseDrag1Status: a drop on the bag bags the window, a drop on
# another window moves it there, anything else cancels.
for key in MouseDrag1Status MouseDrag1StatusLeft MouseDrag1StatusRight MouseDrag1StatusDefault; do
    tmux bind-key -n "$key" "$start"
done
tmux bind-key -n MouseDragEnd1Status "if -F '#{@bag_armed}' { run-shell '$BAG end #{?#{==:#{mouse_status_range},bag},drop,#{?#{==:#{mouse_status_range},window},move:#{window_id},none}} #{client_name}' }"
for key in MouseDragEnd1StatusLeft MouseDragEnd1StatusRight MouseDragEnd1StatusDefault MouseDragEnd1Border; do
    tmux bind-key -n "$key" "$end"
done

tmux bind-key "$(tmux show-options -gv @bag-key)" run-shell "$BAG stash #{window_id} #{client_name}"
tmux bind-key "$(tmux show-options -gv @bag-open-key)" run-shell "$BAG open #{client_name}"

# The bag button sits at the right end of status-right and keeps one width in
# every state, so the window list doesn't shift when a drag starts:
#   idle      "   bag   "  dim when empty, "  bag 3  ", "  bag 3! " when a bagged window is idle or rang
#   dragging  "\_bag 3_/"  base of the bag art (".-bag 3-." with the status bar on top)
in_bag="#{==:#{session_name},#{@bag-session}}"
count="#{S:#{?${in_bag},#{session_windows},}}"
alert="#{S:#{?${in_bag},#{W:#{?#{||:#{window_bell_flag},#{window_silence_flag}},1,}},}}"
top="#{==:#{status-position},top}"
dragging="#{?${count},#{?${top},.-bag ${count}-.,\\_bag ${count}_/},#{?${top},.--bag--.,\\__bag__/}}"
idle="#{?${count},#{?${alert},  bag ${count}! ,  bag ${count}  },#[dim]   bag   }"
segment="#[range=user|bag]#{?#{@bag_dragging},#[#{@bag-style}] ${dragging},#{?${alert},#[#{@bag-style}],} ${idle}}#[norange default]"
existing="$(tmux show-options -gv status-right)"
case "$existing" in
    *"range=user|bag"*) existing="${existing%%#\[range=user|bag\]*}" ;; # reload: replace the old button
    *) tmux set-option -g status-right-length "$(($(tmux show-options -gv status-right-length) + 12))" ;;
esac
tmux set-option -g status-right "${existing}${segment}"

if [ "$(tmux show-options -gv mouse)" != "on" ]; then
    tmux display-message "tmux-bag: dragging needs 'set -g mouse on'; prefix + $(tmux show-options -gv @bag-key) still bags the current window"
fi
