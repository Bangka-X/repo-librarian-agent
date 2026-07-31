#!/usr/bin/env bash
#
# uninstall.sh — stop & remove the librarian systemd *user* service.
#
# Stops the unit (which runs stop.sh via ExecStop), disables it, removes the unit
# file, and reloads the user manager. Leaves linger alone — disable it yourself
# with `loginctl disable-linger $USER` if nothing else needs it.
#
#   bash systemd/uninstall.sh
#
set -uo pipefail

UNIT_NAME="librarian.service"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

systemctl --user disable --now "$UNIT_NAME" 2>/dev/null || true
rm -f "$UNIT_DIR/$UNIT_NAME" && echo "Removed $UNIT_DIR/$UNIT_NAME"
systemctl --user daemon-reload
echo "Done. (Linger left as-is — 'loginctl disable-linger $USER' to turn it off.)"
