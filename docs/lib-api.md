# Available Plugin Libraries

# FfmpegPipeline

## aggregate_frame_results


```lua
fun(frame_results: table[], max_tags?: number):table
```

Combine per-frame AI results into one metadata map.

## extract_video_sample_frames


```lua
fun(input_path: string, output_stem?: string, frame_count?: number, image_extension?: string):table[]|nil, string?
```

Evenly-spaced sample frames.

## get_video_metadata


```lua
fun(video_path: string):table|nil, string?
```

Probe a video for format/duration/codecs/dimensions.

## make_video_proxy


```lua
fun(input_path: string, output_path: string):table|nil, string?
```

Transcode to an mp4 or webm proxy.

## make_video_thumbnail


```lua
fun(input_path: string, output_path: string, time_offset?: string|number):table|nil, string?
```

Single-frame video thumbnail.

---
# MagickPipeline

## get_image_metadata


```lua
fun(image_path: string):table|nil, string?
```

Probe an image for format/dimensions/dpi/size.

## get_pdf_metadata


```lua
fun(pdf_path: string):table|nil, string?
```

PDF document metadata (title, pages, dimensions, ...).

## make_pdf_thumbnail


```lua
fun(pdf_path: string, output_path: string, density_dpi?: number):table|nil, string?
```

First-page PDF thumbnail.

## make_thumbnail


```lua
fun(image_path: string, output_path: string):table|nil, string?
```

320x320 image thumbnail.


---

# RioUtils

## create_proxy_name


```lua
fun(path: string, extension?: string, output_path: string):string
```

Build a `<dir><stem>-Proxy.<ext>` path.

## create_thumbnail_name


```lua
fun(path: string, extension?: string, output_path: string):string
```

Build a `<dir><stem>-Thumbnail.<ext>` path.

## format_timestamp


```lua
fun(total_seconds: number):string
```

Seconds -> `HH:MM:SS.mmm`.

## format_timestamp_for_filename


```lua
fun(total_seconds: number):string
```

Seconds -> filename-safe `HH-MM-SS_mmm`.

## get_file_extension


```lua
fun(path: string):string|nil
```

Lowercase extension without the dot.

## join_command


```lua
fun(parts: (string|nil)[]):string
```

Join command parts with spaces, dropping nils.

## merge_as_strings


```lua
fun(dst: table, src: table, prefix?: string)
```

Copy src into dst, stringifying values (for save_techical_metadata).

## parse_bytes


```lua
fun(s: string|nil):number|nil
```

Parse a byte count with B/K/M/G suffix into bytes.

## parse_num


```lua
fun(s: string|nil):number|nil
```

Parse the leading number from a string.

## parse_ratio


```lua
fun(value: string|nil):number|nil
```

Parse "num/den" or a plain number.

## run_command


```lua
fun(cmd: string):string|nil
```

Run a command, return stdout (nil + logs stderr on failure).

## run_quiet_command


```lua
fun(cmd: string):boolean
```

Run a command for its side effects; true on success.

## shell_quote


```lua
fun(path: any):string
```

Single-quote a value as one safe shell argument.

## split_file_name


```lua
fun(path: string):string, string|nil
```

Split a path into filename stem and extension.

## trim


```lua
fun(value: any):string
```

Trim surrounding whitespace.