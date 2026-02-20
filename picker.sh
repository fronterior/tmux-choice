#!/usr/bin/env bash
# tmux-choice: Shell-based tmux session picker with TUI
# Pure shell script — no fzf dependency, ANSI escape rendering

set -euo pipefail

# ── State ──────────────────────────────────────────────────────
LEVEL=0          # 0=sessions, 1=windows, 2=panes
CURSOR=0         # selected index in current list
OFFSET=0         # scroll offset
ITEMS=()         # display labels
TARGETS=()       # tmux target identifiers
EXTRA=()         # extra info (window count, pane info, etc.)
PARENT_SESSION="" # selected session name (for level 1,2)
PARENT_WINDOW=""      # selected window index (for level 2)
PARENT_WINDOW_NAME="" # selected window name (for breadcrumb)

# Navigation history — remember cursor position when drilling down
HIST_CURSOR_0=0
HIST_OFFSET_0=0
HIST_CURSOR_1=0
HIST_OFFSET_1=0

# ── Terminal setup ─────────────────────────────────────────────
cleanup() {
  printf '\033[?25h\033[?1049l'
  stty "$ORIG_STTY" 2>/dev/null || true
}
trap cleanup EXIT

ORIG_STTY=$(stty -g)
stty -echo -icanon min 1 time 0
printf '\033[?1049h\033[?25l\033[2J'

# ── Colors ─────────────────────────────────────────────────────
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_GREEN='\033[32m'
C_BLACK_ON_GREEN='\033[30;42m'
C_WHITE='\033[97m'
C_GRAY='\033[90m'
C_BORDER='\033[90m'
C_ACTIVE='\033[36m' # cyan for active indicator

# ── Helpers ────────────────────────────────────────────────────
get_term_size() {
  local size
  size=$(stty size)
  TERM_LINES=${size% *}
  TERM_COLS=${size#* }
}

# ── Data loading ───────────────────────────────────────────────
load_sessions() {
  ITEMS=()
  TARGETS=()
  EXTRA=()
  local name windows attached
  while IFS='|' read -r name windows attached; do
    ITEMS+=("$name")
    TARGETS+=("$name")
    local suffix="${windows}W"
    [[ "$attached" == "1" ]] && suffix="$suffix *"
    EXTRA+=("$suffix")
  done < <(tmux list-sessions -F '#{session_name}|#{session_windows}|#{session_attached}' 2>/dev/null)
}

load_windows() {
  ITEMS=()
  TARGETS=()
  EXTRA=()
  local idx name panes active
  while IFS='|' read -r idx name panes active; do
    ITEMS+=("$name")
    TARGETS+=("$idx")
    local suffix="${panes}P"
    [[ "$active" == "1" ]] && suffix="$suffix *"
    EXTRA+=("$suffix")
  done < <(tmux list-windows -t "$PARENT_SESSION" -F '#{window_index}|#{window_name}|#{window_panes}|#{window_active}' 2>/dev/null)
}

load_panes() {
  ITEMS=()
  TARGETS=()
  EXTRA=()
  local idx cmd active tty
  while IFS='|' read -r idx cmd active tty; do
    ITEMS+=("$cmd")
    TARGETS+=("$idx")
    local suffix="$tty"
    [[ "$active" == "1" ]] && suffix="$suffix *"
    EXTRA+=("$suffix")
  done < <(tmux list-panes -t "$PARENT_SESSION:$PARENT_WINDOW" -F '#{pane_index}|#{pane_current_command}|#{pane_active}|#{pane_tty}' 2>/dev/null)
}

# Find the active item index (marked with *) — sets REPLY
find_active_index() {
  local i
  for i in "${!EXTRA[@]}"; do
    if [[ "${EXTRA[$i]}" == *"*"* ]]; then
      REPLY=$i
      return
    fi
  done
  REPLY=0
}

# ── Rendering ──────────────────────────────────────────────────
render() {
  get_term_size
  local total=${#ITEMS[@]}

  # Layout: list on left (40%), preview on right (60%)
  local list_w=$((TERM_COLS * 25 / 100))
  local preview_w=$((TERM_COLS - list_w - 1)) # -1 for border
  local list_col=1
  local border_col=$((list_w + 1))
  local preview_col=$((list_w + 2))

  # Header height = 1 (breadcrumb), footer = 0
  local header_h=1
  local content_h=$((TERM_LINES - header_h))

  # ── Header / Breadcrumb (list panel only) ──
  printf '\033[H\033[0m'
  printf "${C_GREEN}${C_BOLD}"
  local breadcrumb=" tmux-choice"
  case $LEVEL in
    1) breadcrumb="$breadcrumb > $PARENT_SESSION" ;;
    2) breadcrumb="$breadcrumb > $PARENT_SESSION > $PARENT_WINDOW_NAME" ;;
  esac
  local nav_l=" " nav_r=" "
  if ((LEVEL > 0)); then nav_l="<"; fi
  if ((LEVEL < 2)); then nav_r=">"; fi
  local right_part=" $nav_l $nav_r "
  local right_len=${#right_part}
  local left_len=$((list_w - right_len))
  printf '%-*.*s' "$left_len" "$left_len" "$breadcrumb"
  printf "${C_RESET}${C_DIM}%s${C_RESET}" "$right_part"

  # ── Vertical border (full height including header) ──
  printf "${C_BORDER}"
  for ((r = 1; r <= TERM_LINES; r++)); do
    printf '\033[%d;%dH│' "$r" "$border_col"
  done
  printf "${C_RESET}"

  # ── List panel ──
  local visible_h=$content_h

  # Adjust scroll offset
  if ((CURSOR < OFFSET)); then
    OFFSET=$CURSOR
  elif ((CURSOR >= OFFSET + visible_h)); then
    OFFSET=$((CURSOR - visible_h + 1))
  fi

  local usable_w=$((list_w - 1)) # padding
  for ((i = 0; i < visible_h; i++)); do
    local idx=$((OFFSET + i))
    local row=$((header_h + 1 + i))
    printf '\033[%d;%dH' "$row" "$list_col"

    if ((idx >= total)); then
      # Empty line
      printf '%*s' "$usable_w" ''
      continue
    fi

    local label="${ITEMS[$idx]}"
    local extra="${EXTRA[$idx]}"
    local is_active=0
    [[ "$extra" == *"*"* ]] && is_active=1
    # Remove * from display extra
    extra="${extra% \*}"

    # Calculate padding: label on left, extra on right
    local extra_len=${#extra}
    local max_label=$((usable_w - extra_len - 5)) # 5 = marker(3) + gap(1) + trailing(1)
    ((max_label < 1)) && max_label=1

    # Truncate label
    local display_label="${label:0:$max_label}"
    local label_len=${#display_label}
    local padding=$((usable_w - label_len - extra_len - 5))
    ((padding < 0)) && padding=0

    if ((idx == CURSOR)); then
      # Selected item — highlighted
      printf "${C_BLACK_ON_GREEN}"
      if ((is_active)); then
        printf ' %s ' "*"
      else
        printf '   '
      fi
      printf '%s' "$display_label"
      printf '%*s' "$padding" ''
      printf '%s ' "$extra"
      printf "${C_RESET}"
    else
      if ((is_active)); then
        printf " ${C_ACTIVE}*${C_RESET} "
      else
        printf '   '
      fi
      printf "${C_WHITE}%s${C_RESET}" "$display_label"
      printf '%*s' "$padding" ''
      printf "${C_DIM}%s${C_RESET} " "$extra"
    fi
  done

  # ── Preview panel ──
  if ((total > 0)); then
    local target
    case $LEVEL in
      0) target="${TARGETS[$CURSOR]}" ;;
      1) target="$PARENT_SESSION:${TARGETS[$CURSOR]}" ;;
      2) target="$PARENT_SESSION:$PARENT_WINDOW.${TARGETS[$CURSOR]}" ;;
    esac

    local pw=$((preview_w - 2))
    local preview_h=$TERM_LINES
    # Clear preview area first
    local _r
    for ((_r = 0; _r < preview_h; _r++)); do
      printf '\033[%d;%dH\033[K' "$((_r + 1))" "$preview_col"
    done
    # Draw preview content (disable line wrap to clip at terminal edge)
    printf '\033[?7l'
    local line_num=0
    while IFS= read -r line; do
      ((line_num >= preview_h)) && break
      printf '\033[%d;%dH %s' "$((line_num + 1))" "$preview_col" "$line"
      ((++line_num))
    done < <(tmux capture-pane -ep -t "$target" 2>/dev/null || echo "(no preview)")
    printf '\033[?7h'
  fi

  # ── Scrollbar indicator ──
  if ((total > visible_h)); then
    local sb_top=$((OFFSET * visible_h / total))
    local sb_len=$((visible_h * visible_h / total))
    ((sb_len < 1)) && sb_len=1
    for ((i = 0; i < visible_h; i++)); do
      printf '\033[%d;%dH' "$((header_h + 1 + i))" "$TERM_COLS"
      if ((i >= sb_top && i < sb_top + sb_len)); then
        printf "${C_GREEN}▐${C_RESET}"
      else
        printf "${C_DIM}│${C_RESET}"
      fi
    done
  fi
}

# ── Navigation ─────────────────────────────────────────────────
navigate_down() {
  local total=${#ITEMS[@]}
  ((total == 0)) && return
  CURSOR=$(( (CURSOR + 1) % total ))
}

navigate_up() {
  local total=${#ITEMS[@]}
  ((total == 0)) && return
  CURSOR=$(( (CURSOR - 1 + total) % total ))
}

navigate_right() {
  local total=${#ITEMS[@]}
  ((total == 0)) && return

  if ((LEVEL == 0)); then
    # Save history
    HIST_CURSOR_0=$CURSOR
    HIST_OFFSET_0=$OFFSET
    # Drill into session
    PARENT_SESSION="${TARGETS[$CURSOR]}"
    LEVEL=1
    load_windows
    find_active_index; CURSOR=$REPLY
    OFFSET=0
  elif ((LEVEL == 1)); then
    # Save history
    HIST_CURSOR_1=$CURSOR
    HIST_OFFSET_1=$OFFSET
    # Drill into window
    PARENT_WINDOW="${TARGETS[$CURSOR]}"
    PARENT_WINDOW_NAME="${ITEMS[$CURSOR]}"
    LEVEL=2
    load_panes
    find_active_index; CURSOR=$REPLY
    OFFSET=0
  fi
  # Level 2 — no deeper
}

navigate_left() {
  if ((LEVEL == 2)); then
    LEVEL=1
    load_windows
    CURSOR=$HIST_CURSOR_1
    OFFSET=$HIST_OFFSET_1
  elif ((LEVEL == 1)); then
    LEVEL=0
    load_sessions
    CURSOR=$HIST_CURSOR_0
    OFFSET=$HIST_OFFSET_0
  fi
  # Level 0 — no higher
}

do_select() {
  local total=${#ITEMS[@]}
  ((total == 0)) && return

  case $LEVEL in
    0)
      tmux switch-client -t "${TARGETS[$CURSOR]}"
      ;;
    1)
      tmux switch-client -t "$PARENT_SESSION"
      tmux select-window -t "$PARENT_SESSION:${TARGETS[$CURSOR]}"
      ;;
    2)
      tmux switch-client -t "$PARENT_SESSION"
      tmux select-window -t "$PARENT_SESSION:$PARENT_WINDOW"
      tmux select-pane -t "$PARENT_SESSION:$PARENT_WINDOW.${TARGETS[$CURSOR]}"
      ;;
  esac
  exit 0
}

# ── Key reading ────────────────────────────────────────────────
read_key() {
  local c
  IFS= read -rsn1 c

  case "$c" in
    $'\x1b')
      local seq
      IFS= read -rsn1 -t 0.05 seq || true
      if [[ "$seq" == "[" ]]; then
        IFS= read -rsn1 -t 0.05 seq || true
        case "$seq" in
          A) REPLY=UP ;; B) REPLY=DOWN ;;
          C) REPLY=RIGHT ;; D) REPLY=LEFT ;;
          *) REPLY=ESC ;;
        esac
      else
        REPLY=ESC
      fi
      ;;
    k) REPLY=UP ;; j) REPLY=DOWN ;;
    l) REPLY=RIGHT ;; h) REPLY=LEFT ;;
    '') REPLY=ENTER ;; q) REPLY=QUIT ;;
    *) REPLY=UNKNOWN ;;
  esac
}

# ── Main ───────────────────────────────────────────────────────
main() {
  load_sessions

  if ((${#ITEMS[@]} == 0)); then
    echo "No tmux sessions found."
    exit 1
  fi

  # Find and highlight current session
  local current_session
  current_session=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "")
  for i in "${!TARGETS[@]}"; do
    if [[ "${TARGETS[$i]}" == "$current_session" ]]; then
      CURSOR=$i
      break
    fi
  done

  render

  while true; do
    read_key

    case "$REPLY" in
      UP)    navigate_up ;;
      DOWN)  navigate_down ;;
      RIGHT) navigate_right ;;
      LEFT)  navigate_left ;;
      ENTER) do_select ;;
      QUIT|ESC) exit 0 ;;
      *) continue ;;
    esac

    render
  done
}

main
