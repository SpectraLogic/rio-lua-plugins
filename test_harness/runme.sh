#!/bin/sh
# Usage: runme.sh <script> <input> [settings-json] [clip-dir] [output]
# Can be run from any directory (or symlinked onto PATH). Script, input,
# settings, clip and output paths are resolved relative to the current directory;
# a bare input name not found there falls back to ./source-input/<input>.
# clip-dir (OP-Atom only) is the folder of essence files for the object.
if [ $# -lt 2 ]; then
    echo "Usage: $0 <script> <input> [settings-json] [clip-dir] [output]" >&2
    exit 1
fi

if ! command -v java >/dev/null 2>&1; then
    echo "Error: java not found in PATH" >&2
    exit 1
fi

# Locate the directory this launcher really lives in, following symlinks.
self="$0"
while [ -L "$self" ]; do
    link=$(readlink "$self")
    case "$link" in
        /*) self="$link" ;;
        *) self="$(dirname "$self")/$link" ;;
    esac
done
here=$(cd "$(dirname "$self")" && pwd)

jar_name=plugin_test_harness-all.jar
if [ -f "$here/$jar_name" ]; then
    jar="$here/$jar_name"
elif [ -f "$here/build/libs/$jar_name" ]; then
    jar="$here/build/libs/$jar_name"
else
    echo "Error: $jar_name not found next to $self or in $here/build/libs (run ./gradlew shadowJar)" >&2
    exit 1
fi

script="$1"
input="$2"
settings="$3"
clip_dir="$4"
output="$5"
set -- -DluaInput="$input"
if [ -n "$settings" ]; then
    set -- "$@" -DluaSettings="$settings"
fi
if [ -n "$clip_dir" ]; then
    set -- "$@" -DluaClip="$clip_dir"
fi
if [ -n "$output" ]; then
    set -- "$@" -DluaOutput="$output"
fi
exec java "$@" -jar "$jar" "$script"
