#!/usr/bin/env bash
# Only run if we're in a graphical session
if [ -n "$WAYLAND_DISPLAY" ]; then
  systemctl --user daemon-reload
  systemctl --user enable --now hyprsunset-check.timer 2>/dev/null || true
  systemctl --user enable --now wallpaper-rotate.timer 2>/dev/null || true
fi
