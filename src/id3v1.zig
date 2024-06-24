const std = @import("std");
const Allocator = std.mem.Allocator;
const Metadata = @import("metadata.zig").Metadata;
const latin1ToUtf8 = @import("latin1.zig").latin1ToUtf8;

pub const id3v1_identifier = "TAG";
pub const tag_size = 128;

/// Assumes the stream cursor is at the end of the ID3v1 tag
pub fn read(allocator: Allocator, reader: anytype, seekable_stream: anytype) !Metadata {
    var metadata: Metadata = Metadata.init(allocator);
    errdefer metadata.deinit();

    var metadata_map = &metadata.map;

    const end_pos = try seekable_stream.getPos();
    if (end_pos < tag_size) {
        return error.EndOfStream;
    }

    const start_offset = end_pos - tag_size;
    metadata.start_offset = start_offset;
    metadata.end_offset = end_pos;

    try seekable_stream.seekTo(start_offset);
    const data = try reader.readBytesNoEof(tag_size);
    if (!std.mem.eql(u8, data[0..3], id3v1_identifier)) {
        return error.InvalidIdentifier;
    }

    const song_name = std.mem.trimRight(u8, std.mem.sliceTo(data[3..33], '\x00'), " ");
    const artist = std.mem.trimRight(u8, std.mem.sliceTo(data[33..63], '\x00'), " ");
    const album_name = std.mem.trimRight(u8, std.mem.sliceTo(data[63..93], '\x00'), " ");
    const year = std.mem.trimRight(u8, std.mem.sliceTo(data[93..97], '\x00'), " ");
    const comment = std.mem.trimRight(u8, std.mem.sliceTo(data[97..127], '\x00'), " ");
    const could_be_v1_1 = data[125] == '\x00';
    const track_num = data[126];
    const genre = data[127];

    // 60 is twice as large as the largest id3v1 field
    var utf8_buf: [60]u8 = undefined;

    if (song_name.len > 0) {
        const utf8_song_name = latin1ToUtf8(song_name, &utf8_buf);
        try metadata_map.put("title", utf8_song_name);
    }
    if (artist.len > 0) {
        const utf8_artist = latin1ToUtf8(artist, &utf8_buf);
        try metadata_map.put("artist", utf8_artist);
    }
    if (album_name.len > 0) {
        const utf8_album_name = latin1ToUtf8(album_name, &utf8_buf);
        try metadata_map.put("album", utf8_album_name);
    }
    if (year.len > 0) {
        const utf8_year = latin1ToUtf8(year, &utf8_buf);
        try metadata_map.put("date", utf8_year);
    }
    if (comment.len > 0) {
        const utf8_comment = latin1ToUtf8(comment, &utf8_buf);
        try metadata_map.put("comment", utf8_comment);
    }
    if (could_be_v1_1 and track_num > 0) {
        var buf: [3]u8 = undefined;
        const track_num_string = try std.fmt.bufPrint(buf[0..], "{}", .{track_num});
        try metadata_map.put("track", track_num_string);
    }
    if (genre < id3v1_genre_names.len) {
        try metadata_map.put("genre", id3v1_genre_names[genre]);
    }

    return metadata;
}

pub const id3v1_genre_names = [_][]const u8{
    "Blues",
    "Classic Rock",
    "Country",
    "Dance",
    "Disco",
    "Funk",
    "Grunge",
    "Hip-Hop",
    "Jazz",
    "Metal",
    "New Age",
    "Oldies",
    "Other",
    "Pop",
    "R&B",
    "Rap",
    "Reggae",
    "Rock",
    "Techno",
    "Industrial",
    "Alternative",
    "Ska",
    "Death Metal",
    "Pranks",
    "Soundtrack",
    "Euro-Techno",
    "Ambient",
    "Trip-Hop",
    "Vocal",
    "Jazz+Funk",
    "Fusion",
    "Trance",
    "Classical",
    "Instrumental",
    "Acid",
    "House",
    "Game",
    "Sound Clip",
    "Gospel",
    "Noise",
    "AlternRock",
    "Bass",
    "Soul",
    "Punk",
    "Space",
    "Meditative",
    "Instrumental Pop",
    "Instrumental Rock",
    "Ethnic",
    "Gothic",
    "Darkwave",
    "Techno-Industrial",
    "Electronic",
    "Pop-Folk",
    "Eurodance",
    "Dream",
    "Southern Rock",
    "Comedy",
    "Cult",
    "Gangsta",
    "Top 40",
    "Christian Rap",
    "Pop/Funk",
    "Jungle",
    "Native American",
    "Cabaret",
    "New Wave",
    "Psychedelic",
    "Rave",
    "Showtunes",
    "Trailer",
    "Lo-Fi",
    "Tribal",
    "Acid Punk",
    "Acid Jazz",
    "Polka",
    "Retro",
    "Musical",
    "Rock & Roll",
    "Hard Rock",
    "Folk",
    "Folk-Rock",
    "National Folk",
    "Swing",
    "Fast Fusion",
    "Bebop",
    "Latin",
    "Revival",
    "Celtic",
    "Bluegrass",
    "Avantgarde",
    "Gothic Rock",
    "Progressive Rock",
    "Psychedelic Rock",
    "Symphonic Rock",
    "Slow Rock",
    "Big Band",
    "Chorus",
    "Easy Listening",
    "Acoustic",
    "Humour",
    "Speech",
    "Chanson",
    "Opera",
    "Chamber Music",
    "Sonata",
    "Symphony",
    "Booty Bass",
    "Primus",
    "Porn Groove",
    "Satire",
    "Slow Jam",
    "Club",
    "Tango",
    "Samba",
    "Folklore",
    "Ballad",
    "Power Ballad",
    "Rhythmic Soul",
    "Freestyle",
    "Duet",
    "Punk Rock",
    "Drum Solo",
    "A Cappella",
    "Euro-House",
    "Dance Hall",
    "Goa",
    "Drum & Bass",
    "Club-House",
    "Hardcore Techno",
    "Terror",
    "Indie",
    "BritPop",
    "Negerpunk",
    "Polsk Punk",
    "Beat",
    "Christian Gangsta Rap",
    "Heavy Metal",
    "Black Metal",
    "Crossover",
    "Contemporary Christian",
    "Christian Rock",
    "Merengue",
    "Salsa",
    "Thrash Metal",
    "Anime",
    "Jpop",
    "Synthpop",
    "Abstract",
    "Art Rock",
    "Baroque",
    "Bhangra",
    "Big Beat",
    "Breakbeat",
    "Chillout",
    "Downtempo",
    "Dub",
    "EBM",
    "Eclectic",
    "Electro",
    "Electroclash",
    "Emo",
    "Experimental",
    "Garage",
    "Global",
    "IDM",
    "Illbient",
    "Industro-Goth",
    "Jam Band",
    "Krautrock",
    "Leftfield",
    "Lounge",
    "Math Rock",
    "New Romantic",
    "Nu-Breakz",
    "Post-Punk",
    "Post-Rock",
    "Psytrance",
    "Shoegaze",
    "Space Rock",
    "Trop Rock",
    "World Music",
    "Neoclassical",
    "Audiobook",
    "Audio Theatre",
    "Neue Deutsche Welle",
    "Podcast",
    "Indie Rock",
    "G-Funk",
    "Dubstep",
    "Garage Rock",
    "Psybient",
};
