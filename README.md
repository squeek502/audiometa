# audiometa

An audio metadata/tag reading library written in [Zig](https://ziglang.org/). Currently supports ID3v2, ID3v1, FLAC, APE, Ogg Vorbis, and MP4/M4A (iTunes Metadata Format).

**still heavily work-in-progress, everything is subject to change**

The general idea is to:

1. Parse all metadata verbatim, with no de-duplication, and as little interpretation as possible. *(this part is mostly working/complete)*
2. Run the metadata through a 'collator' that does some (potentially subjective) interpretation of the metadata, and then provides only the 'best' set of metadata (doing things like de-duplication, prioritization between different types of metadata, conversion from inferred character encodings, etc). *(this part is unfinished)*

In terms of code, usage will probably look something like:

```zig
var stream_source = std.io.StreamSource{ .file = file };

// Step 1: Parse the metadata
var metadata = try audiometa.metadata.readAll(allocator, &stream_source);
defer metadata.deinit();

// Step 2: Collate the metadata
var collator = audiometa.collate.Collator.init(allocator, &metadata);
defer collator.deinit();

// Get the parts of the collated data you care about and do what you want with it
const artists = try collator.artists();
```

## Limitations

- No compression support, all compressed tags/frames are ignored (haven't ever seen one of these in the wild)
- Only supports text frames, so things like embedded images are skipped (maybe TODO)
- No synchronized lyric frame support in ID3v2 tags (maybe TODO)
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

- TagLib completely ignores all ID3v2 tags past the first one
