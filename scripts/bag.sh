#!/usr/bin/env bash
# bag.sh start | end [drop | move:<window_id>] | stash <window_id> <client> | open <client> | unbag <target> <client>
set -u

opt() { tmux show-options -gqv "$1"; }

BAG_SESSION="$(opt @bag-session)"
BAG_SESSION="${BAG_SESSION:-bag}"

# The drop zone adds two lines of bag art to the status bar. At the bottom the
# art goes above the original lines and the bag pops up; at the top it goes
# below them and the bag drops down. Either way the original lines stay put,
# so the window list stays under the mouse.
start() {
    [ -n "$(opt @bag_dragging)" ] && return
    local i lines art style
    tmux set-option -g @bag_saved_status "$(opt status)"
    for i in 0 1 2 3 4; do
        tmux set-option -g "@bag_saved_format_$i" "$(opt "status-format[$i]")"
    done
    tmux set-option -g @bag_dragging 1
    case "$(opt status)" in
        on) lines=1 ;;
        off) return ;;
        *) lines="$(opt status)" ;;
    esac
    # tmux draws at most five status lines.
    art=$((5 - lines))
    [ "$art" -gt 2 ] && art=2
    [ "$art" -eq 0 ] && return
    style="$(opt @bag-style)"
    local row_a row_b
    if [ "$(opt status-position)" = "top" ]; then
        row_a="( drop! )" row_b=" '-___-' "
    else
        row_a=" .-~~~-. " row_b="( drop! )"
    fi
    local formats=()
    for ((i = 0; i < lines; i++)); do
        formats+=("$(opt "@bag_saved_format_$i")")
    done
    if [ "$(opt status-position)" = "top" ]; then
        formats+=("#[align=right range=user|bag $style] $row_a#[norange default]")
        [ "$art" -eq 2 ] && formats+=("#[align=right range=user|bag $style] $row_b#[norange default]")
    else
        local above=("#[align=right range=user|bag $style] $row_b#[norange default]")
        [ "$art" -eq 2 ] && above=("#[align=right range=user|bag $style] $row_a#[norange default]" "${above[@]}")
        formats=("${above[@]}" "${formats[@]}")
    fi
    local cmd=()
    for i in "${!formats[@]}"; do
        cmd+=(set-option -g "status-format[$i]" "${formats[$i]}" \;)
    done
    tmux "${cmd[@]}" set-option -g status "${#formats[@]}"
}

# Always disarms; restores the status bar only if a drag started.
end() {
    local src i saved
    src="$(opt @bag_armed)"
    tmux set-option -gu @bag_armed
    [ -z "$(opt @bag_dragging)" ] && return
    for i in 0 1 2 3 4; do
        saved="$(opt "@bag_saved_format_$i")"
        if [ -n "$saved" ]; then
            tmux set-option -g "status-format[$i]" "$saved"
        else
            tmux set-option -gu "status-format[$i]"
        fi
        tmux set-option -gu "@bag_saved_format_$i"
    done
    tmux set-option -g status "$(opt @bag_saved_status)"
    tmux set-option -gu @bag_dragging \; set-option -gu @bag_saved_status
    [ -z "$src" ] && return
    case "${1:-}" in
        drop) stash "$src" "${2:-}" ;;
        move:*) move "$src" "${1#move:}" ;;
    esac
}

# Moves a window to where another window of the same session was dropped:
# before it when dragged left, after it when dragged right.
move() {
    local src="$1" dst="$2" where
    [ "$src" = "$dst" ] && return
    read -r src_session src_index < <(tmux display-message -p -t "$src" '#{session_id} #{window_index}')
    read -r dst_session dst_index < <(tmux display-message -p -t "$dst" '#{session_id} #{window_index}')
    [ "$src_session" = "$dst_session" ] || return
    where="-b"
    [ "$src_index" -lt "$dst_index" ] && where="-a"
    tmux move-window "$where" -s "$src" -t "$dst" \; select-window -t "$src"
    if [ "$(tmux display-message -p -t "$src" '#{renumber-windows}')" = "1" ]; then
        tmux move-window -r -t "$src_session"
    fi
}

# Moves the window into the detached bag session. Its processes keep running.
stash() {
    local src="$1" client="${2:-}" session name windows placeholder="" silence
    read -r session windows name < <(tmux display-message -p -t "$src" '#{session_name} #{session_windows} #{window_name}') || return
    [ "$session" = "$BAG_SESSION" ] && return
    # Moving a session's last window out destroys the session and detaches the client.
    if [ "$windows" -le 1 ]; then
        message "$client" "can't bag the last window of $session: open another window first"
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
    # A bagged window that stops printing gets marked idle: a task waiting for you.
    silence="$(opt @bag-silence)"
    if [ "${silence:-0}" -gt 0 ] && [ "$(tmux display-message -p -t "$src" '#{monitor-silence}')" = "0" ]; then
        tmux set-option -w -t "$src" monitor-silence "$silence" \; set-option -w -t "$src" @bag_silence 1
    fi
    message "$client" "bagged $name ($(tmux display-message -p -t "=$BAG_SESSION:" '#{session_windows}') in the bag)"
}

open() {
    local client="$1" pane
    if ! tmux has-session -t "=$BAG_SESSION" 2>/dev/null; then
        message "$client" "empty. Drag a window onto it or press prefix + $(opt @bag-key)"
        return
    fi
    pane="$(tmux display-message -p -c "$client" '#{pane_id}')"
    tmux choose-tree -Zw -t "$pane" \
        -f "#{==:#{session_name},$BAG_SESSION}" \
        -F "#{?window_format,#{window_name}  #{b:pane_current_path}#{?window_silence_flag,  idle,}#{?window_bell_flag,  bell,},}" \
        "run-shell \"$0 unbag '%%' '$client'\""
}

unbag() {
    local target="$1" client="$2" id name session
    read -r id name < <(tmux display-message -p -t "$target" '#{window_id} #{window_name}') || return
    session="$(tmux display-message -p -c "$client" '#{session_id}')"
    if [ -n "$(tmux show-options -wqv -t "$id" @bag_silence)" ]; then
        tmux set-option -wu -t "$id" monitor-silence \; set-option -wu -t "$id" @bag_silence
    fi
    tmux move-window -s "$id" -t "$session:" \; select-window -t "$id"
    message "$client" "unbagged $name"
}

message() {
    if [ -n "$1" ]; then
        tmux display-message -c "$1" "bag: $2"
    else
        tmux display-message "bag: $2"
    fi
}

cmd="${1:-}"
shift || true
case "$cmd" in
    start | end | stash | open | unbag) "$cmd" "$@" ;;
    *) exit 1 ;;
esac
