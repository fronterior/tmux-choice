#!/usr/bin/env bash
# tmux-choice TPM plugin entrypoint
# Binds prefix + s to open the session picker in a popup

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tmux bind-key s display-popup -E -w 60% -h 40% "$CURRENT_DIR/picker.sh"
