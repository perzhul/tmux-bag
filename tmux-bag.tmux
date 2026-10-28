#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAG="$CURRENT_DIR/scripts/bag.sh"
chmod +x "$BAG"

# A drag whose release never arrived leaves the three-line drop zone up; a reload clears it.
"$BAG" end

# Prints the command bound to a root key, or $2 when the key is unbound.
original() {
    local body
    body="$(tmux list-keys -T root "$1" 2>/dev/null | sed -E "s/^bind-key +(-r +)?-T root +$1 +//")"
    echo "${body:-$2}"
}

# A press on a window entry arms the drag with that window; a plain click
# (MouseUp1Status) disarms it. The first motion after arming starts the drag
# wherever it lands: clicking re-centres the window list, so it can fall
# outside the entry that was pressed.
start="if -F '#{&&:#{@bag_armed},#{!:#{@bag_dragging}}}' { run-shell '$BAG start' }"
end="if -F '#{@bag_armed}' { run-shell '$BAG end' }"

# The wrappers keep each existing binding for when no drag is armed. Skipped on re-source.
case "$(original MouseDown1Status '')" in
    *"$BAG"*) ;;
    *)
        # Crossing a pane or border mid-drag would otherwise start copy-mode or
        # a resize, and the release would never reach the bag.
        tmux bind-key -n MouseDrag1Pane "if -F '#{@bag_armed}' { $start } { $(original MouseDrag1Pane 'send-keys -M') }"
        tmux bind-key -n MouseDrag1Border "if -F '#{@bag_armed}' { $start } { $(original MouseDrag1Border 'send-keys -M') }"
        # tmux forwards an unbound MouseDragEnd1Pane to the pane; send-keys -M does the same.
        tmux bind-key -n MouseDragEnd1Pane "if -F '#{@bag_armed}' { run-shell '$BAG end' } { $(original MouseDragEnd1Pane 'send-keys -M') }"
        # A press can't arrive mid-drag, so a set flag here means a lost release.
        tmux bind-key -n MouseDown1Status "$end ; if -F '#{!=:#{mouse_status_range},bag}' { $(original MouseDown1Status 'switch-client -t =') ; if -F '#{==:#{mouse_status_range},window}' { set-option -gF @bag_armed '#{window_id}' } }"
        # The bag opens on release: a menu opened on press closes when the press releases outside it.
        up="$(original MouseUp1Status '')"
        tmux bind-key -n MouseUp1Status "set-option -gu @bag_armed ; if -F '#{==:#{mouse_status_range},bag}' { run-shell '$BAG menu #{client_name}' }${up:+ ; $up}"
        # The re-centred list can put a gap or status-left/right under a click's release.
        for key in MouseUp1StatusLeft MouseUp1StatusRight MouseUp1StatusDefault; do
            up="$(original "$key" '')"
            tmux bind-key -n "$key" "set-option -gu @bag_armed${up:+ ; $up}"
        done
        ;;
esac

for key in MouseDrag1Status MouseDrag1StatusLeft MouseDrag1StatusRight MouseDrag1StatusDefault; do
    tmux bind-key -n "$key" "$start"
done
tmux bind-key -n MouseDragEnd1Status "if -F '#{@bag_armed}' { run-shell '$BAG end #{?#{==:#{mouse_status_range},bag},drop,}' }"
for key in MouseDragEnd1StatusLeft MouseDragEnd1StatusRight MouseDragEnd1StatusDefault MouseDragEnd1Border; do
    tmux bind-key -n "$key" "$end"
done

tmux bind-key b run-shell "$BAG stash #{window_id}"
tmux bind-key B run-shell "$BAG menu #{client_name}"

# The bag sits at the right end of status-right: a "bag N" button while it holds
# windows, and the base of the bag art during a drag.
count="#{S:#{?#{==:#{session_name},bag},#{session_windows},}}"
segment="#{?#{@bag_dragging},#[range=user|bag fg=colour214]  \\_ bag ${count} _/ #[norange default],#{?${count},#[range=user|bag] bag ${count} #[norange default],}}"
existing="$(tmux show-options -gv status-right)"
case "$existing" in
    *"range=user|bag"*) ;; # already composed (re-source)
    *)
        tmux set-option -g status-right "${existing}${segment}"
        tmux set-option -g status-right-length "$(($(tmux show-options -gv status-right-length) + 16))"
        ;;
esac
