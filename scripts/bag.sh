#!/usr/bin/env bash
# bag.sh start | end [drop] | stash <window_id> | menu <client>
set -u

BAG_SESSION="bag"

opt() { tmux show-options -gqv "$1"; }

# The drop zone grows the status bar to three lines: two lines of bag art on
# top, and the user's original first line moved to the bottom so the window
# list stays under the mouse.
start() {
    [ -n "$(opt @bag_dragging)" ] && return
    local i
    tmux set-option -g @bag_saved_status "$(opt status)"
    for i in 0 1 2; do
        tmux set-option -g "@bag_saved_format_$i" "$(opt "status-format[$i]")"
    done
    tmux set-option -g @bag_dragging 1
    tmux set-option -g 'status-format[0]' "#[align=right range=user|bag fg=colour214]   .-~~~~~-.  #[norange default]" \; \
        set-option -g 'status-format[1]' "#[align=right range=user|bag fg=colour214]  ( drop me ) #[norange default]" \; \
        set-option -g 'status-format[2]' "$(opt @bag_saved_format_0)" \; \
        set-option -g status 3
}

# Always disarms; restores the status bar only if a drag started.
end() {
    local src i
    src="$(opt @bag_armed)"
    tmux set-option -gu @bag_armed
    [ -z "$(opt @bag_dragging)" ] && return
    for i in 0 1 2; do
        tmux set-option -g "status-format[$i]" "$(opt "@bag_saved_format_$i")"
    done
    tmux set-option -g status "$(opt @bag_saved_status)"
    tmux set-option -gu @bag_dragging \; set-option -gu @bag_saved_status \; \
        set-option -gu @bag_saved_format_0 \; set-option -gu @bag_saved_format_1 \; set-option -gu @bag_saved_format_2
    if [ "${1:-}" = "drop" ] && [ -n "$src" ]; then
        stash "$src"
    fi
}

# Moves the window into the detached bag session. Its processes keep running.
stash() {
    local src="$1" session windows placeholder=""
    session="$(tmux display-message -p -t "$src" '#{session_name}')" || return
    [ "$session" = "$BAG_SESSION" ] && return
    windows="$(tmux display-message -p -t "$src" '#{session_windows}')"
    # Moving a session's last window out destroys the session and detaches the client.
    if [ "$windows" -le 1 ]; then
        tmux display-message "bag: can't bag the last window of $session"
        return
    fi
    if ! tmux has-session -t "=$BAG_SESSION" 2>/dev/null; then
        placeholder="$(tmux new-session -d -s "$BAG_SESSION" -P -F '#{window_id}')"
    fi
    tmux move-window -d -s "$src" -t "=$BAG_SESSION:"
    [ -n "$placeholder" ] && tmux kill-window -t "$placeholder"
    # move-window leaves a gap in the source session even with renumber-windows on.
    if [ "$(tmux display-message -p -t "=$session:" '#{renumber-windows}')" = "1" ]; then
        tmux move-window -r -t "=$session"
    fi
    tmux refresh-client -S
}

menu() {
    local client="$1" id name path key i=1
    local args=(display-menu -c "$client" -T "#[align=centre] bag " -x R -y S)
    if ! tmux has-session -t "=$BAG_SESSION" 2>/dev/null; then
        tmux display-message -c "$client" "bag is empty"
        return
    fi
    while IFS=$'\t' read -r id name path; do
        key=""
        [ "$i" -le 9 ] && key="$i"
        # Menu item names are formats: escape '#' so a window name prints as is.
        args+=("${name//#/##}  ${path##*/}" "$key" "move-window -s $id -t : ; select-window -t $id")
        i=$((i + 1))
    done < <(tmux list-windows -t "=$BAG_SESSION" -F "#{window_id}	#{window_name}	#{pane_current_path}")
    tmux "${args[@]}"
}

cmd="${1:-}"
shift || true
case "$cmd" in
    start | end | stash | menu) "$cmd" "$@" ;;
    *) exit 1 ;;
esac
