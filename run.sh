#!/bin/bash
# Builds a real Filipendula.app bundle (debug, this Mac's architecture) and launches it.
#   ./run.sh         bundle + open (icon, Dock identity, proper app behavior)
#   ./run.sh --raw   plain `swift run` (bare executable, no icon; handy for console logs)
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" = "--raw" ]; then
    shift
    exec swift run FilipendulaApp "$@"
fi

pkill -x Filipendula 2>/dev/null || true
CONFIG=debug QUICK=1 ARCHS="$(uname -m)" ./scripts/make_app.sh
open build/Filipendula.app
