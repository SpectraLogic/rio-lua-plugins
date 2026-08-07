#!/bin/sh
# Usage: ./runme.sh <script> <input> [output] [settings-json]
if [ $# -lt 2 ]; then
    echo "Usage: $0 <script> <input> [output] [settings-json]" >&2
    exit 1
fi

if ! command -v java >/dev/null 2>&1; then
    echo "Error: java not found in PATH" >&2
    exit 1
fi

script="$1"
input="$2"
output="${3:-$HOME/proxy/lua-output}"
clip_dir="$4"
if [ -n "$clip_dir" ]; then
    clip_opt="-DluaClip=$clip_dir"
fi
settings="$5"
settings_opt=""
if [ -n "$settings" ]; then
    settings_opt="-DluaSettings=$settings"
fi
exec java -DluaInput="$input" -DluaOutput="$output" $settings_opt $clip_opt \
     -jar build/libs/plugin_test_harness-all.jar "$script"
