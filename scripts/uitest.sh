#!/usr/bin/env bash
# Drives the real Pocket window with synthetic mouse events and checks the UI wiring.
# Runs in-process (no Accessibility permission needed); the optional real cursor drag reports
# SKIP when the binary is not trusted for Accessibility.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build
exec "./.build/debug/Pocket" --uitest
