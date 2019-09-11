#!/bin/sh -e
cd "$(dirname "$0")"
exec "$(nix-build --builders "" -Q --no-out-link updater)/bin/update" "$@"
