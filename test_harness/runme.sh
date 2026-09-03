#!/bin/sh
# Usage: ./runme.sh <script> <input> [settings-json] [output]
if [ $# -lt 2 ]; then
    echo "Usage: $0 <script> <input> [settings-json] [output]" >&2
    exit 1
fi

if ! command -v java >/dev/null 2>&1; then
    echo "Error: java not found in PATH" >&2
    exit 1
fi

script="$1"
input="$2"
settings="$3"
settings_opt=""
if [ -n "$settings" ]; then
    settings_opt="-DluaSettings=$settings"
fi
output="${4:-$HOME/proxy/lua-output}"
exec java -DluaInput="$input" -DluaOutput="$output" $settings_opt $clip_opt \
     -jar build/libs/plugin_test_harness-all.jar "$script"
