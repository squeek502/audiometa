# audiometa

An audio metadata/tag reader (currently supports ID3v2, ID3v1, FLAC, APE, Ogg Vorbis) written in [Zig](https://ziglang.org/).

**still heavily work-in-progress, everything is subject to change**

## Limitations

- No compression support, all compressed tags/frames are ignored
- Only supports text frames, so things like embedded images are skipped (maybe TODO)
- No comment frame support in ID3v2 tags (TODO)
- No unsynchronized/synchronized lyric/text transcription frame support in ID3v2 tags (TODO)
- No support for trailing ID3v2 tags (TODO)
- No support for SEEK frame in ID3v2.4 tags (TODO)
- No support for tag formats not listed above (TODO)
- Only supports reading tags, no support for writing/modifying tags (maybe TODO)

## Comparisons to other libraries

`audiometa`:
- Provides all metadata as UTF-8 strings, regardless of their encodings within the tags
- Does not de-duplicate or otherwise have any opinion about how to handle duplicate frames/tags while parsing, and instead leaves that up to the user

### ffmpeg/ffprobe/libavformat

- ffmpeg drops all duplicate frames during the parsing of ID3v2 tags, and therefore has some slightly strange/unexpected results (i.e. it will return frames from duplicate tags only if they don't exist in earlier tags)

### TagLib

- TagLib seems to be heavily geared towards reading tags for direct manipulation rather than for display. For example, as far as I can tell, its API makes it hard to get UTF-8 strings for all frames.
- TagLib completely ignores all ID3v2 tags past the first one
