#!/usr/bin/env bash
# tmux-picker TPM plugin entrypoint
# Binds prefix + s to open the picker in a popup

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tmux bind-key s display-popup -E -w 80% -h 80% "$CURRENT_DIR/picker.sh"
