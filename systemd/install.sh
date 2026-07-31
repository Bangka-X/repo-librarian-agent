#!/usr/bin/env bash
#
# install.sh — install & start the librarian as a systemd *user* service.
#
# Renders systemd/librarian.service with this checkout's absolute path, drops it
# into ~/.config/systemd/user/, enables lingering (so it starts at boot without a
# login), and enables + starts the unit. Idempotent: re-run after pulling changes
# to refresh the unit. Pair with systemd/uninstall.sh to remove it.
#
#   bash systemd/install.sh
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_NAME="librarian.service"
TEMPLATE="$REPO_DIR/systemd/$UNIT_NAME"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

[ -f "$TEMPLATE" ] || { echo "error: $TEMPLATE not found" >&2; exit 1; }

# Render the template, substituting this checkout's absolute path.
mkdir -p "$UNIT_DIR"
sed "s|@WORKDIR@|$REPO_DIR|g" "$TEMPLATE" > "$UNIT_DIR/$UNIT_NAME"
echo "Installed $UNIT_DIR/$UNIT_NAME  (WorkingDirectory=$REPO_DIR)"

# Linger keeps your user systemd manager running without an active login, so the
# service comes up on boot. A user may enable their own linger without sudo.
if command -v loginctl >/dev/null 2>&1; then
  if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo no)" != "yes" ]; then
    echo "Enabling linger for $USER (so the service starts at boot)…"
    loginctl enable-linger "$USER" 2>/dev/null || \
      echo "warning: could not enable linger automatically — run: sudo loginctl enable-linger $USER" >&2
  fi
fi

systemctl --user daemon-reload
systemctl --user enable --now "$UNIT_NAME"

echo
systemctl --user --no-pager status "$UNIT_NAME" || true
echo
echo "Manage it with:"
echo "  systemctl --user status librarian       # current state"
echo "  systemctl --user restart librarian       # re-run init.sh"
echo "  systemctl --user stop librarian          # runs stop.sh"
echo "  journalctl --user -u librarian -f        # init.sh / stop.sh output"
echo "  tmux ls                                  # the daemons it launched"
