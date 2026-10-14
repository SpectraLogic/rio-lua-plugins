#!/bin/sh
# Test environment and required tools for Media Insight processing

# check_tools tool...  -- prints OK/FAIL for each tool; returns 1 if any are missing.
check_tools() {
    _failed=0
    for tool in "$@"; do
        if command -v "$tool" >/dev/null 2>&1; then
            printf "OK    %-12s %s\n" "$tool" "$(command -v "$tool")"
        else
            printf "FAIL  %-12s not found in PATH\n" "$tool"
            _failed=1
        fi
    done
    return $_failed
}

# Always run from this script's own folder, so scripts/, settings.json and the
# ../ test files are found no matter where the user launched it from.
cd "$(dirname "$0")" || exit 1
type=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')

case "$type" in
    CHECK)
        echo "Checking all tools"
        check_tools ffmpeg ffprobe magick whisper-cli gs aws
        ;;
    IMAGE_OLLAMA)
        echo "image_ollama.lua"
        check_tools magick &&
            ./runme.sh scripts/image_ollama.lua ../Spectra-Cube.jpg settings.json
        ;;
    IMAGE_AWS)
        echo "image_aws.lua"
        check_tools magick aws &&
            ./runme.sh scripts/image_aws.lua ../Spectra-Cube.jpg settings.json
        ;;
    PDF)
        echo "pdf.lua"
        check_tools gs magick &&
            ./runme.sh scripts/pdf.lua ../lto9_tape_technology.pdf settings.json
        ;;
    AUDIO_OLLAMA)
        echo "audio_ollama.lua"
        check_tools ffmpeg magick whisper-cli &&
            ./runme.sh scripts/audio_ollama.lua "../University of Utah Backup Strategy.mp3" settings.json
        ;;
    AUDIO_AWS)
        echo "audio_aws.lua"
        check_tools ffmpeg magick aws &&
            ./runme.sh scripts/audio_aws.lua "../University of Utah Backup Strategy.mp3" settings.json
        ;;
    VIDEO_OLLAMA)
        echo "video_ollama.lua"
        check_tools ffmpeg ffprobe magick whisper-cli &&
            ./runme.sh scripts/video_ollama.lua "../Introducing Rio Media Suite for Media Management & Archiving.mp4" settings.json
        ;;
    VIDEO_AWS)
        echo "video_aws.lua"
        check_tools ffmpeg ffprobe magick aws &&
            ./runme.sh scripts/video_aws.lua "../Introducing Rio Media Suite for Media Management & Archiving.mp4" settings.json
        ;;
    OPATOM_AWS)
        echo "opatom_aws.lua"
        check_tools ffmpeg ffprobe magick aws &&
            ./runme.sh scripts/opatom_aws.lua "SVG HZS Interview" settings.json "../HZS/"
        ;;
    OPATOM_OLLAMA)
        echo "opatom_ollama.lua"
        check_tools ffmpeg ffprobe magick whisper-cli &&
            ./runme.sh scripts/opatom_ollama.lua "SVG HZS Interview" settings.json "../HZS/"
        ;;
    *)
        echo "Usage: $0 {check|image_ollama|image_aws|pdf|audio_ollama|audio_aws|video_ollama|video_aws|opatom_aws|opatom_ollama}"
        exit 1
        ;;
esac
