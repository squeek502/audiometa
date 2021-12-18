const std = @import("std");
const audiometa = @import("audiometa");
const id3 = audiometa.id3v2;
const flac = audiometa.flac;
const fmtUtf8SliceEscapeUpper = audiometa.util.fmtUtf8SliceEscapeUpper;
const meta = audiometa.metadata;
const MetadataMap = meta.MetadataMap;
const Metadata = meta.Metadata;
const TypedMetadata = meta.TypedMetadata;
const ID3v2Metadata = meta.ID3v2Metadata;
const FullTextEntry = audiometa.id3v2_data.FullTextMap.Entry;
const AllMetadata = meta.AllMetadata;
const unsynch = audiometa.unsynch;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const assert = std.debug.assert;

const start_testing_at_prefix = "";

const buggy_files = buggy_files: {
    @setEvalBranchQuota(10000);
    break :buggy_files std.ComptimeStringMap(void, .{
        // TagLib gives no ID3v2 frames for these files, but they have valid tags AFAICT
        .{"Dawn Treader/(2002) Dawn Treader/DAWN TREADER - demo - 4 - Roller Coaster in a Theme Park.mp3"},
        .{"DAWNTREADER-disco/Dawn Treader/(2002) Dawn Treader/DAWN TREADER - demo - 4 - Roller Coaster in a Theme Park.mp3"},
        .{"Discography/Dawn Treader - Roller Coaster in a Theme Park.mp3"},
        .{"flattery/sunday.mp3"},
        .{"V.A. - I Love D-Crust V/En Tus Ojos.mp3"},

        // TagLib gives nothing but a COMM for these files, but they have valid tags AFAICT
        .{"behind enemy lines - the global cannibal/behind enemy lines - the global cannibal - 01 - the global cannibal.mp3"},
        .{"behind enemy lines - the global cannibal/behind enemy lines - the global cannibal - 02 - what did we expect.mp3"},
        .{"behind enemy lines - the global cannibal/behind enemy lines - the global cannibal - 03 - advancing the cause.mp3"},
        .{"behind enemy lines - the global cannibal/behind enemy lines - the global cannibal - 04 - as long as i'm safe.mp3"},
        .{"behind enemy lines - the global cannibal/behind enemy lines - the global cannibal - 05 - hooked on chirst.mp3"},
        .{"behind enemy lines - the global cannibal/behind enemy lines - the global cannibal - 06 - cycle of violence.mp3"},
        .{"behind enemy lines - the global cannibal/behind enemy lines - the global cannibal - 07 - self-inflicted extinction.mp3"},
        .{"behind enemy lines - the global cannibal/behind enemy lines - the global cannibal - 08 - her body. her decision.mp3"},
        .{"behind enemy lines - the global cannibal/behind enemy lines - the global cannibal - 09 - the army of god.mp3"},
        .{"behind enemy lines - the global cannibal/behind enemy lines - the global cannibal - 10 - the politics of hunger.mp3"},
        .{"behind enemy lines - the global cannibal/behind enemy lines - the global cannibal - 11 - non-lethal weapons.mp3"},
        .{"behind enemy lines - the global cannibal/behind enemy lines - the global cannibal - 12 - light it up.mp3"},
        .{"blue_monday-rewritten/blue monday - ...a moving train.mp3"},
        .{"blue_monday-rewritten/blue monday - 100 inari.mp3"},
        .{"blue_monday-rewritten/blue monday - bereaved.mp3"},
        .{"blue_monday-rewritten/blue monday - bloody knuckles.mp3"},
        .{"blue_monday-rewritten/blue monday - drenched.mp3"},
        .{"blue_monday-rewritten/blue monday - it's your life.mp3"},
        .{"blue_monday-rewritten/blue monday - let it out.mp3"},
        .{"blue_monday-rewritten/blue monday - lost and found.mp3"},
        .{"blue_monday-rewritten/blue monday - next breath.mp3"},
        .{"blue_monday-rewritten/blue monday - on the outside.mp3"},
        .{"blue_monday-rewritten/blue monday - the everything festival.mp3"},
        .{"blue_monday-rewritten/blue monday - turning the tables.mp3"},
        .{"comeback_kid-wake_the_dead-2005/01 false idols fall.mp3"},
        .{"comeback_kid-wake_the_dead-2005/02 my other side.mp3"},
        .{"comeback_kid-wake_the_dead-2005/03 wake the dead.mp3"},
        .{"comeback_kid-wake_the_dead-2005/04 the trouble i love.mp3"},
        .{"comeback_kid-wake_the_dead-2005/05 talk is cheap.mp3"},
        .{"comeback_kid-wake_the_dead-2005/06 partners in crime.mp3"},
        .{"comeback_kid-wake_the_dead-2005/07 our distance.mp3"},
        .{"comeback_kid-wake_the_dead-2005/08 bright lights keep shining.mp3"},
        .{"comeback_kid-wake_the_dead-2005/09 falling apart.mp3"},
        .{"comeback_kid-wake_the_dead-2005/10 losing patience.mp3"},
        .{"comeback_kid-wake_the_dead-2005/11 final goodbye.mp3"},
        .{"carry_on-its all our blood/06 - check yourself.mp3"},
        .{"final_fight-under_attack/final fight - 01 - it's in the blood.mp3"},
        .{"final_fight-under_attack/final fight - 02 - getting my eyes checked.mp3"},
        .{"final_fight-under_attack/final fight - 03 - dying of laughter.mp3"},
        .{"final_fight-under_attack/final fight - 04 - notes on bombs and fists.mp3"},
        .{"final_fight-under_attack/final fight - 05 - when actions go unchallenged.mp3"},
        .{"final_fight-under_attack/final fight - 06 - lost loyalty.mp3"},
        .{"final_fight-under_attack/final fight - 07 - shifting the center.mp3"},
        .{"final_fight-under_attack/final fight - 08 - one and two.mp3"},
        .{"final_fight-under_attack/final fight - 09 - when words go unchallenged.mp3"},
        .{"final_fight-under_attack/final fight - 10 - three years ago.mp3"},
        .{"final_fight-under_attack/final fight - 11 - modified people.mp3"},
        .{"final_fight-under_attack/final fight - 12 - waste of mind, waste of life.mp3"},
        .{"kids_like_us-outta_control-advance-2005-sdr/01-kids_like_us-outta_control.mp3"},
        .{"kids_like_us-outta_control-advance-2005-sdr/02-kids_like_us-box_of_buttholes.mp3"},
        .{"kids_like_us-outta_control-advance-2005-sdr/03-kids_like_us-dont_fake_the_punk.mp3"},
        .{"kids_like_us-outta_control-advance-2005-sdr/04-kids_like_us-dont_eat_rocks._we_rocks.mp3"},
        .{"kids_like_us-outta_control-advance-2005-sdr/05-kids_like_us-skate_hate.mp3"},
        .{"kids_like_us-outta_control-advance-2005-sdr/06-kids_like_us-soda_jerk.mp3"},
        .{"kids_like_us-outta_control-advance-2005-sdr/07-kids_like_us-dog_food.mp3"},
        .{"kids_like_us-outta_control-advance-2005-sdr/08-kids_like_us-lantern_corps.mp3"},
        .{"kids_like_us-outta_control-advance-2005-sdr/09-kids_like_us-monster_squad.mp3"},
        .{"kids_like_us-outta_control-advance-2005-sdr/10-kids_like_us-asshat.mp3"},
        .{"kids_like_us-outta_control-advance-2005-sdr/11-kids_like_us-you_know_your_life_sucks.mp3"},
        .{"kids_like_us-outta_control-advance-2005-sdr/12-kids_like_us-the_clock_on_the_wall.mp3"},
        .{"kids_like_us-outta_control-advance-2005-sdr/13-kids_like_us-gator_smash.mp3"},
        .{"Wake Up On Fire Demo/01 Holes.mp3"},
        .{"Wake Up On Fire Demo/02 Green Mouth.mp3"},
        .{"Wake Up On Fire Demo/03 Dust.mp3"},
        .{"Wake Up On Fire Demo/04 Stress By Design, Crazy 'Ole Boss.mp3"},
        .{"Wake Up On Fire Demo/05 Jihad the Buffy Slayer.mp3"},
        .{"Wake Up On Fire Demo/06 Will To Be Hollow.mp3"},
        .{"Wake Up On Fire Demo/07 Stay Out Of the World.mp3"},

        // TagLib gives partial frames for these files, but they have valid tags AFAICT
        .{"cro-mags - the age of quarrel/01 we gotta know.mp3"},
        .{"have_heart-what_counts/have heart -01- lionheart.mp3"},
        .{"have_heart-what_counts/have heart -02- get the knife.mp3"},
        .{"have_heart-what_counts/have heart -03- something more than ink.mp3"},
        .{"have_heart-what_counts/have heart -04- what counts.mp3"},
        .{"have_heart-what_counts/have heart -05- dig somewhere else.mp3"},
        .{"have_heart-what_counts/have heart -06- reinforced(outspoken).mp3"},
        .{"Immanu El - Theyll Come They Come 2007/05-immanu_el-panda.mp3"},
        .{"Mortal Treason - A Call To The Martyrs [2004]/06 Bridens Last Kiss.mp3"},
        .{"November 13th & AK47 - split/november 13th - ancient spirits.mp3"},
        .{"Strength_For_A_Reason-Blood_Faith_Loyalty-2005-RNS/02-strength_for_a_reason-dead_to_me.mp3"},
        .{"Swarrrm - Black Bong (2007) [256kbps]/02 Cherry Tree.mp3"},
        .{"Swarrrm - Black Bong (2007) [256kbps]/03 Fissure.mp3"},
        .{"Swarrrm - Black Bong (2007) [256kbps]/04 Sky.mp3"},
        .{"Swarrrm - Black Bong (2007) [256kbps]/05 Road.mp3"},
        .{"Swarrrm - Black Bong (2007) [256kbps]/06 Light.mp3"},
        .{"Swarrrm - Black Bong (2007) [256kbps]/07 Wind.mp3"},
        .{"Swarrrm - Black Bong (2007) [256kbps]/08 Black Bong.mp3"},
        .{"trash talk - self-titled/01 The Hand That Feeds.mp3"},
        .{"trash talk - self-titled/02 Well Of Souls.mp3"},
        .{"trash talk - self-titled/03 Birth Plague Die.mp3"},
        .{"trash talk - self-titled/04 Incarnate.mp3"},
        .{"trash talk - self-titled/05 I Block.mp3"},
        .{"trash talk - self-titled/06 Dig.mp3"},
        .{"trash talk - self-titled/07 Onward and Upward.mp3"},
        .{"trash talk - self-titled/08 Immaculate Infection.mp3"},
        .{"trash talk - self-titled/09 Shame.mp3"},
        .{"trash talk - self-titled/10 All The Kings Men.mp3"},
        .{"trash talk - self-titled/11 The Mistake.mp3"},
        .{"trash talk - self-titled/12 Revelation.mp3"},

        // TagLib gives no COMM frames for these files, but they have at least one AFAICT
        .{"Crow - 終焉の扉 (The Door Of The End) (V0)/01 - 終焉の扉.mp3"},
        .{"Crow - 終焉の扉 (The Door Of The End) (V0)/02 - My Last Dream.mp3"},
        .{"Crow - 終焉の扉 (The Door Of The End) (V0)/03 - Scapegoat.mp3"},
        .{"Embrace The End - It All Begins With One Broken Dream [2001] by_fightheday/01 Blue Skies.mp3"},
        .{"Embrace The End - It All Begins With One Broken Dream [2001] by_fightheday/02 Maybe Tomorrow.mp3"},
        .{"Embrace The End - It All Begins With One Broken Dream [2001] by_fightheday/03 Autumn Tears.mp3"},
        .{"Embrace The End - It All Begins With One Broken Dream [2001] by_fightheday/04 Deceived.mp3"},
        .{"Embrace The End - It All Begins With One Broken Dream [2001] by_fightheday/05 Unanswered Prayers.mp3"},
        .{"Embrace The End - It All Begins With One Broken Dream [2001] by_fightheday/06 Through Dark Days.mp3"},
        .{"Embrace The End - It All Begins With One Broken Dream [2001] by_fightheday/07 Embrace The End.mp3"},
        .{"Embrace The End - It All Begins With One Broken Dream [2001] by_fightheday/08 Last Goodbye.mp3"},
        .{"matt besser - (2001) may i help you dumbass (missing 9-13)/08. matt besser - automated operator.mp3"},

        // TagLib trims whitespace from TCOM in these files, audiometa does not
        .{"Mar De Grises - Streams Inwards/01 - Starmaker.mp3"},
        .{"Mar De Grises - Streams Inwards/02 - Shining Human Skin.mp3"},
        .{"Mar De Grises - Streams Inwards/03 - The Bell and the Solar Gust.mp3"},
        .{"Mar De Grises - Streams Inwards/04 - Spectral Ocean.mp3"},
        .{"Mar De Grises - Streams Inwards/05 - Sensing the New Orbit.mp3"},
        .{"Mar De Grises - Streams Inwards/06 - Catatonic North.mp3"},
        .{"Mar De Grises - Streams Inwards/07 - Knotted Delirium.mp3"},
        .{"Mar De Grises - Streams Inwards/08 - A Sea of Dead Comets.mp3"},
        .{"Mar De Grises - Streams Inwards/09 - Aphelion Aura [bonus track].mp3"},

        // TagLib doesn't handle EOF/padding edge cases for v2.4 non-synchsafe-encoded frame sizes
        .{"mr. meeble - never trust the chinese/05. it all came to pass.mp3"},
        .{"mr. meeble - never trust the chinese/07. a ton of bricks.mp3"},

        // These files have a totally invalid COMM frame that says it's
        // UTF-16 with BOM but then uses u8 chars with no BOM in its text fields.
        // TagLib reports this as a COMM frame with no description/value but
        // that doesn't seem great. Instead, we treat it as an invalid frame and skip it.
        .{"Sending All Processes The Kill Signal - Life Not Found -404- Error/02.mp3"},
        .{"Sending All Processes The Kill Signal - Life Not Found -404- Error/05.mp3"},

        // This is just weird, it's a v2.3 tag with a mix of v2.2 field IDs and v2.3
        // field IDs, and a TAL with one value and TALB with another. Just skip it
        // since I don't want to deal with all the conversions TagLib is doing
        .{"Sonic Cathedrals Vol. XLVI Curated by Age of Collapse/04 Prowler.mp3"},
        .{"Sonic Cathedrals Vol. XLVI Curated by Age of Collapse/18 With empty hands extended.mp3"},

        // TDRC / TYER conversion nonsense, just skip it for now
        .{"TH3 LOR3L3I COLL3CTION/It's Only Me.mp3"},
        .{"Una Bestia Incontrolable - 10.11.12/Una Bestia Incontrolable - 01 La Cova.mp3"},
        .{"Una Bestia Incontrolable - 10.11.12/Una Bestia Incontrolable - 02 El cant dels ocells.mp3"},
        .{"Una Bestia Incontrolable - 10.11.12/Una Bestia Incontrolable - 03 Les hores perdudes.mp3"},
        .{"Una Bestia Incontrolable - 10.11.12/Una Bestia Incontrolable - 04 Vulnerable.mp3"},
        .{"Una Bestia Incontrolable - 10.11.12/Una Bestia Incontrolable - 05 No hi ha esperanca.mp3"},
        .{"Una Bestia Incontrolable - 10.11.12/Una Bestia Incontrolable - 06 A les seves mans.mp3"},
        .{"Una Bestia Incontrolable - 10.11.12/Una Bestia Incontrolable - 07 De dia.mp3"},

        // There is an unreadable COMM frame in these files, with no room for the language string
        // For some reason TagLib still outputs this frame even though it seems to report it as an error
        .{"go it alone - vancouver gold/Go it Alone - Our Mistakes.mp3"},
        .{"go it alone - vancouver gold/Go it Alone - Silence.mp3"},
        .{"go it alone - vancouver gold/Go it Alone - Statement.mp3"},
        .{"go it alone - vancouver gold/Go it Alone - The Best of You.mp3"},
        .{"go it alone - vancouver gold/Go it Alone - Turn It Off.mp3"},
    });
};

test "music folder" {
    const allocator = std.testing.allocator;
    var dir = try std.fs.cwd().openDir("/media/drive4/music/", .{ .iterate = true });
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var testing_started = false;
    while (try walker.next()) |entry| {
        if (!testing_started) {
            if (std.mem.startsWith(u8, entry.path, start_testing_at_prefix)) {
                testing_started = true;
            } else {
                continue;
            }
        }
        if (entry.kind != .File) continue;

        if (buggy_files.has(entry.path)) continue;

        const extension = std.fs.path.extension(entry.basename);
        const is_mp3 = std.ascii.eqlIgnoreCase(extension, ".mp3");
        const is_flac = std.ascii.eqlIgnoreCase(extension, ".flac");
        const readable = is_mp3 or is_flac;
        if (!readable) continue;

        std.debug.print("\n{s}\n", .{fmtUtf8SliceEscapeUpper(entry.path)});

        var expected_metadata = try getTagLibMetadata(allocator, entry.dir, entry.basename);
        defer expected_metadata.deinit();

        var file = try entry.dir.openFile(entry.basename, .{});
        defer file.close();

        // skip zero sized files
        const size = (try file.stat()).size;
        if (size == 0) continue;

        var stream_source = std.io.StreamSource{ .file = file };
        var metadata = try meta.readAll(allocator, &stream_source);
        defer metadata.deinit();

        try compareMetadata(allocator, &expected_metadata, &metadata);
    }
}

fn convertID3v2Alloc(allocator: *Allocator, map: *MetadataMap, id3_major_version: u8) !MetadataMap {
    var converted = MetadataMap.init(allocator);
    errdefer converted.deinit();

    for (map.entries.items) |entry| {
        // Keep the unconverted names since I don't really understand fully
        // how taglib converts things. This will make things less precise but
        // more foolproof for the type of comparisons we're trying to make
        try converted.put(entry.name, entry.value);
        if (taglibConversions.get(entry.name)) |converted_name| {
            try converted.put(converted_name, entry.value);
        }
    }

    if (id3_major_version < 4) {
        try mergeDate(&converted);

        // TagLib seems to convert TDAT and TIME to a zero-length string
        if (converted.getFirst("TDAT") != null) {
            const indexes_entry = try converted.getOrPutEntry("TDAT");
            const entry_index = indexes_entry.value_ptr.items[0];
            var entry = &converted.entries.items[entry_index];

            converted.allocator.free(entry.value);
            entry.value = &[_]u8{};
        }
        if (converted.getFirst("TIME") != null) {
            const indexes_entry = try converted.getOrPutEntry("TIME");
            const entry_index = indexes_entry.value_ptr.items[0];
            var entry = &converted.entries.items[entry_index];

            converted.allocator.free(entry.value);
            entry.value = &[_]u8{};
        }
    }

    //var name_map_it = converted.name_to_indexes.iterator();
    //while (name_map_it.next()) |name_map_entry| {
    // if ((name_map_entry.key_ptr.*).len != 4 or (name_map_entry.key_ptr.*)[0] != 'T') {
    //     continue;
    // }
    for (frames_to_combine) |frame_id| {
        if (converted.name_to_indexes.contains(frame_id)) {
            const name_map_entry = converted.name_to_indexes.getEntry(frame_id).?;
            const count = name_map_entry.value_ptr.items.len;
            if (count > 1) {
                const joined = (try converted.getJoinedAlloc(allocator, name_map_entry.key_ptr.*, " ")).?;
                defer allocator.free(joined);
                // this is hacky but we can get away with only replacing the first
                // value with the joined value, since TagLib will only report one value
                // and therefore we will only compare the first value in compareMetadataMapID3v2
                try converted.putOrReplaceFirst(name_map_entry.key_ptr.*, joined);
            }
        }
    }

    return converted;
}

const frames_to_combine: []const []const u8 = &.{ "TCOM", "TPE2", "TDOR" };

const taglibConversions = std.ComptimeStringMap([]const u8, .{
    // 2.2 -> 2.4
    .{ "BUF", "RBUF" },  .{ "CNT", "PCNT" }, .{ "COM", "COMM" },  .{ "CRA", "AENC" },
    .{ "ETC", "ETCO" },  .{ "GEO", "GEOB" }, .{ "IPL", "TIPL" },  .{ "MCI", "MCDI" },
    .{ "MLL", "MLLT" },  .{ "POP", "POPM" }, .{ "REV", "RVRB" },  .{ "SLT", "SYLT" },
    .{ "STC", "SYTC" },  .{ "TAL", "TALB" }, .{ "TBP", "TBPM" },  .{ "TCM", "TCOM" },
    .{ "TCO", "TCON" },  .{ "TCP", "TCMP" }, .{ "TCR", "TCOP" },  .{ "TDY", "TDLY" },
    .{ "TEN", "TENC" },  .{ "TFT", "TFLT" }, .{ "TKE", "TKEY" },  .{ "TLA", "TLAN" },
    .{ "TLE", "TLEN" },  .{ "TMT", "TMED" }, .{ "TOA", "TOAL" },  .{ "TOF", "TOFN" },
    .{ "TOL", "TOLY" },  .{ "TOR", "TDOR" }, .{ "TOT", "TOAL" },  .{ "TP1", "TPE1" },
    .{ "TP2", "TPE2" },  .{ "TP3", "TPE3" }, .{ "TP4", "TPE4" },  .{ "TPA", "TPOS" },
    .{ "TPB", "TPUB" },  .{ "TRC", "TSRC" }, .{ "TRD", "TDRC" },  .{ "TRK", "TRCK" },
    .{ "TS2", "TSO2" },  .{ "TSA", "TSOA" }, .{ "TSC", "TSOC" },  .{ "TSP", "TSOP" },
    .{ "TSS", "TSSE" },  .{ "TST", "TSOT" }, .{ "TT1", "TIT1" },  .{ "TT2", "TIT2" },
    .{ "TT3", "TIT3" },  .{ "TXT", "TOLY" }, .{ "TXX", "TXXX" },  .{ "TYE", "TDRC" },
    .{ "UFI", "UFID" },  .{ "ULT", "USLT" }, .{ "WAF", "WOAF" },  .{ "WAR", "WOAR" },
    .{ "WAS", "WOAS" },  .{ "WCM", "WCOM" }, .{ "WCP", "WCOP" },  .{ "WPB", "WPUB" },
    .{ "WXX", "WXXX" },
    // 2.2 -> 2.4 Apple iTunes nonstandard frames
     .{ "PCS", "PCST" }, .{ "TCT", "TCAT" },  .{ "TDR", "TDRL" },
    .{ "TDS", "TDES" },  .{ "TID", "TGID" }, .{ "WFD", "WFED" },  .{ "MVN", "MVNM" },
    .{ "MVI", "MVIN" },  .{ "GP1", "GRP1" },
    // 2.3 -> 2.4
    .{ "TORY", "TDOR" }, .{ "TYER", "TDRC" },
    .{ "IPLS", "TIPL" },
});

const date_format = "YYYY-MM-DDThh:mm";

fn isValidDateComponent(maybe_date: ?[]const u8) bool {
    if (maybe_date == null) return false;
    const date = maybe_date.?;
    if (date.len != 4) return false;
    // only 0-9 allowed
    for (date) |byte| switch (byte) {
        '0'...'9' => {},
        else => return false,
    };
    return true;
}

fn mergeDate(metadata: *MetadataMap) !void {
    var date_buf: [date_format.len]u8 = undefined;
    var date: []u8 = date_buf[0..0];

    var year = metadata.getFirst("TDRC");
    if (!isValidDateComponent(year)) return;
    date = date_buf[0..4];
    std.mem.copy(u8, date, (year.?)[0..4]);

    var maybe_daymonth = metadata.getFirst("TDAT");
    if (isValidDateComponent(maybe_daymonth)) {
        const daymonth = maybe_daymonth.?;
        date = date_buf[0..10];
        // TDAT is DDMM, we want -MM-DD
        var day = daymonth[0..2];
        var month = daymonth[2..4];
        _ = try std.fmt.bufPrint(date[4..10], "-{s}-{s}", .{ month, day });

        var maybe_time = metadata.getFirst("TIME");
        if (isValidDateComponent(maybe_time)) {
            const time = maybe_time.?;
            date = date_buf[0..];
            // TIME is HHMM
            var hours = time[0..2];
            var mins = time[2..4];
            _ = try std.fmt.bufPrint(date[10..], "T{s}:{s}", .{ hours, mins });
        }
    }

    try metadata.putOrReplaceFirst("TDRC", date);
}

fn compareTDRC(expected: *MetadataMap, actual: *MetadataMap) !void {
    const expected_count = expected.valueCount("TDRC").?;
    if (expected_count == 1) {
        const expected_value = expected.getFirst("TDRC").?;
        if (actual.getFirst("TDRC")) |actual_tdrc| {
            try std.testing.expectEqualStrings(expected_value, actual_tdrc);
        } else if (actual.getFirst("TYER")) |actual_tyer| {
            try std.testing.expectEqualStrings(expected_value, actual_tyer);
        } else {
            return error.MissingTDRC;
        }
    } else {
        unreachable; // TODO multiple TDRC values
    }
}

fn compareMetadataMapID3v2(allocator: *Allocator, expected: *MetadataMap, actual: *MetadataMap, id3_major_version: u8) !void {
    var actual_converted = try convertID3v2Alloc(allocator, actual, id3_major_version);
    defer actual_converted.deinit();

    for (expected.entries.items) |field| {
        // genre is messy, just skip it for now
        // TODO: dont skip it
        if (std.mem.eql(u8, field.name, "TCON")) {
            continue;
        }
        // TIPL (Involved people list) is also messy, since taglib converts from IPLS to TIPL
        else if (std.mem.eql(u8, field.name, "TIPL")) {
            continue;
        }
        // TagLib seems to give TSIZ as an empty string, so skip it
        else if (std.mem.eql(u8, field.name, "TSIZ")) {
            continue;
        } else {
            if (actual_converted.contains(field.name)) {
                var expected_num_values = expected.valueCount(field.name).?;

                if (expected_num_values == 1) {
                    var actual_value = actual_converted.getFirst(field.name).?;

                    std.testing.expectEqualStrings(field.value, actual_value) catch |e| {
                        std.debug.print("\nfield: {s}\n", .{fmtUtf8SliceEscapeUpper(field.name)});
                        std.debug.print("\nexpected:\n", .{});
                        expected.dump();
                        std.debug.print("\nactual:\n", .{});
                        actual.dump();
                        std.debug.print("\nactual converted:\n", .{});
                        actual_converted.dump();
                        return e;
                    };
                } else {
                    const expected_values = (try expected.getAllAlloc(allocator, field.name)).?;
                    defer allocator.free(expected_values);
                    const actual_values = (try actual_converted.getAllAlloc(allocator, field.name)).?;
                    defer allocator.free(actual_values);

                    std.testing.expectEqual(expected_values.len, actual_values.len) catch |err| {
                        std.debug.print("Field: {s}\n", .{field.name});
                        return err;
                    };

                    for (expected_values) |expected_value| {
                        var found = false;
                        for (actual_values) |actual_value| {
                            if (std.mem.eql(u8, expected_value, actual_value)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            std.debug.print("Value not found for field {s}, expected value: '{}'\n", .{ fmtUtf8SliceEscapeUpper(field.name), fmtUtf8SliceEscapeUpper(expected_value) });

                            std.debug.print(" Actual values:\n", .{});
                            for (actual_values) |actual_value| {
                                std.debug.print("  '{s}'\n", .{fmtUtf8SliceEscapeUpper(actual_value)});
                            }
                            return error.ExpectedFieldValueNotFound;
                        }
                    }
                }
            } else {
                std.debug.print("\nmissing field {s}\n", .{field.name});
                std.debug.print("\nexpected:\n", .{});
                expected.dump();
                std.debug.print("\nactual:\n", .{});
                actual.dump();
                std.debug.print("\nactual converted:\n", .{});
                actual_converted.dump();
                return error.MissingField;
            }
        }
    }
}

fn compareMetadataMapFLAC(expected: *MetadataMap, actual: *MetadataMap) !void {
    expected_loop: for (expected.entries.items) |field| {
        var found_matching_key = false;
        for (actual.entries.items) |entry| {
            if (std.ascii.eqlIgnoreCase(field.name, entry.name)) {
                if (std.mem.eql(u8, field.value, entry.value)) {
                    continue :expected_loop;
                }
                found_matching_key = true;
            }
        }
        std.debug.print("field: {s}\n", .{fmtUtf8SliceEscapeUpper(field.name)});
        std.debug.print("\nexpected:\n", .{});
        expected.dump();
        std.debug.print("\nactual:\n", .{});
        actual.dump();
        if (found_matching_key) {
            return error.FieldValuesDontMatch;
        } else {
            return error.MissingField;
        }
    }
}

fn compareFullText(expected: FullTextEntry, actual: FullTextEntry) !void {
    try testing.expectEqualStrings(expected.language, actual.language);
    try testing.expectEqualStrings(expected.description, actual.description);
    try testing.expectEqualStrings(expected.value, actual.value);
}

fn compareMetadata(allocator: *Allocator, all_expected: *AllMetadata, all_actual: *AllMetadata) !void {
    // dumb way to do this but oh well
    errdefer {
        std.debug.print("\nexpected:\n", .{});
        all_expected.dump();

        std.debug.print("\nactual:\n", .{});
        all_actual.dump();
    }

    for (all_expected.tags) |expected_tag| {
        switch (expected_tag) {
            .id3v2 => {
                const maybe_actual_id3v2 = all_actual.getFirstMetadataOfType(.id3v2);
                if (maybe_actual_id3v2 == null) {
                    return error.MissingID3v2;
                }
                const actual_id3v2 = maybe_actual_id3v2.?;
                // Don't compare version, Taglib doesn't give the actual version in the file, but
                // instead the version it decided to convert the tag to
                //try testing.expectEqual(expected_tag.id3v2.header.major_version, actual_id3v2.header.major_version);
                try testing.expectEqual(expected_tag.id3v2.comments.entries.items.len, actual_id3v2.comments.entries.items.len);
                for (expected_tag.id3v2.comments.entries.items) |expected_comment, comment_i| {
                    // TagLib seems to give blank descriptions for blank values, if we see
                    // blank both then skip this one
                    if (expected_comment.description.len == 0 and expected_comment.value.len == 0) {
                        continue;
                    }
                    const actual_comment = actual_id3v2.comments.entries.items[comment_i];
                    try compareFullText(expected_comment, actual_comment);
                }
                for (expected_tag.id3v2.unsynchronized_lyrics.entries.items) |expected_lyrics, lyrics_i| {
                    const actual_lyrics = actual_id3v2.unsynchronized_lyrics.entries.items[lyrics_i];
                    try compareFullText(expected_lyrics, actual_lyrics);
                }
                try compareMetadataMapID3v2(allocator, &expected_tag.getMetadata().map, &actual_id3v2.metadata.map, expected_tag.id3v2.header.major_version);
            },
            .flac => {
                const maybe_actual_flac = all_actual.getFirstMetadataOfType(.flac);
                if (maybe_actual_flac == null) {
                    return error.MissingFLAC;
                }
                const actual_flac = maybe_actual_flac.?;
                try compareMetadataMapFLAC(&expected_tag.getMetadata().map, &actual_flac.map);
            },
            else => @panic("TODO: comparisons for more tag types supported by taglib"),
        }
    }
}

fn getTagLibMetadata(allocator: *std.mem.Allocator, cwd: ?std.fs.Dir, filepath: []const u8) !AllMetadata {
    const result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "framelist",
            filepath,
        },
        .cwd_dir = cwd,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var id3v2_metadata: ?ID3v2Metadata = null;
    errdefer if (id3v2_metadata != null) id3v2_metadata.?.deinit();

    const maybe_metadata_start = std.mem.indexOf(u8, result.stdout, "ID3v2");
    if (maybe_metadata_start) |metadata_start| {
        var metadata_line = result.stdout[metadata_start..];
        const metadata_line_end = std.mem.indexOfScalar(u8, metadata_line, '\n').?;
        metadata_line = metadata_line[0..metadata_line_end];

        std.debug.print("metadataline: {s}\n", .{std.fmt.fmtSliceEscapeLower(metadata_line)});

        var major_version = try std.fmt.parseInt(u8, metadata_line[6..7], 10);
        // taglib doesn't render v2.2 frames AFAICT, and instead upgrades them to v2.3.
        // So bump major_version up to 3 here since we need to read the upgraded version.
        if (major_version == 2) {
            major_version = 3;
        }
        var num_frames_str = metadata_line[11..];
        const num_frames_end = std.mem.indexOfScalar(u8, num_frames_str, ' ').?;
        num_frames_str = num_frames_str[0..num_frames_end];
        const num_frames = try std.fmt.parseInt(usize, num_frames_str, 10);

        id3v2_metadata = ID3v2Metadata.init(allocator, id3.ID3Header{
            .major_version = major_version,
            .revision_num = 0,
            .flags = 0,
            .size = 0,
        }, 0, 0);

        const start_value_string = "[====[";
        const end_value_string = "]====]";

        var frame_i: usize = 0;
        const absolute_metadata_line_end_after_newline = metadata_start + metadata_line_end + 1;
        var frames_data = result.stdout[absolute_metadata_line_end_after_newline..];
        while (frame_i < num_frames) : (frame_i += 1) {
            const frame_id = frames_data[0..4];
            frames_data = frames_data[4..];

            const is_comment = std.mem.eql(u8, frame_id, "COMM");
            const is_lyrics = std.mem.eql(u8, frame_id, "USLT");
            const is_usertext = std.mem.eql(u8, frame_id, "TXXX");

            var language: ?[]const u8 = null;
            var description: ?[]const u8 = null;
            if (is_comment or is_lyrics) {
                var start_quote_index = std.mem.indexOf(u8, frames_data, start_value_string).?;
                language = frames_data[0..start_quote_index];
                const description_start = start_quote_index + start_value_string.len;
                var end_quote_index = std.mem.indexOf(u8, frames_data[description_start..], end_value_string).?;
                const abs_end_quote_index = description_start + end_quote_index;
                description = frames_data[description_start..abs_end_quote_index];
                frames_data = frames_data[abs_end_quote_index + end_value_string.len ..];
            } else if (is_usertext) {
                const description_start = start_value_string.len;
                var end_quote_index = std.mem.indexOf(u8, frames_data[description_start..], end_value_string).?;
                const abs_end_quote_index = description_start + end_quote_index;
                description = frames_data[description_start..abs_end_quote_index];
                frames_data = frames_data[abs_end_quote_index + end_value_string.len ..];
            }

            assert(frames_data[0] == '=');

            const value_start_index = 1;
            var start_quote_index = std.mem.indexOf(u8, frames_data[value_start_index..], start_value_string).?;
            const abs_after_start_quote_index = value_start_index + start_quote_index + start_value_string.len;
            var end_quote_index = std.mem.indexOf(u8, frames_data[abs_after_start_quote_index..], end_value_string).?;
            const abs_end_quote_index = abs_after_start_quote_index + end_quote_index;
            var value = frames_data[abs_after_start_quote_index..abs_end_quote_index];

            if (is_comment) {
                try id3v2_metadata.?.comments.put(language.?, description.?, value);
            } else if (is_lyrics) {
                try id3v2_metadata.?.unsynchronized_lyrics.put(language.?, description.?, value);
            } else if (is_usertext) {
                try id3v2_metadata.?.metadata.map.put(description.?, value);
            } else {
                try id3v2_metadata.?.metadata.map.put(frame_id, value);
            }

            var after_linebreaks = abs_end_quote_index + end_value_string.len;
            while (after_linebreaks < frames_data.len and frames_data[after_linebreaks] == '\n') {
                after_linebreaks += 1;
            }

            frames_data = frames_data[after_linebreaks..];
        }
    }

    var flac_metadata: ?Metadata = null;
    errdefer if (flac_metadata != null) flac_metadata.?.deinit();

    const flac_start_string = "FLAC:::::::::\n";
    const maybe_flac_start = std.mem.indexOf(u8, result.stdout, flac_start_string);
    if (maybe_flac_start) |flac_start| {
        const flac_data_start = flac_start + flac_start_string.len;
        var flac_data = result.stdout[flac_data_start..];

        flac_metadata = Metadata.init(allocator);

        while (true) {
            var equals_index = std.mem.indexOfScalar(u8, flac_data, '=') orelse break;
            var name = flac_data[0..equals_index];
            const value_start_index = equals_index + 1;
            const start_value_string = "[====[";
            var start_quote_index = std.mem.indexOf(u8, flac_data[value_start_index..], start_value_string) orelse break;
            const abs_after_start_quote_index = value_start_index + start_quote_index + start_value_string.len;
            const end_value_string = "]====]";
            var end_quote_index = std.mem.indexOf(u8, flac_data[abs_after_start_quote_index..], end_value_string) orelse break;
            const abs_end_quote_index = abs_after_start_quote_index + end_quote_index;
            var value = flac_data[abs_after_start_quote_index..abs_end_quote_index];

            try flac_metadata.?.map.put(name, value);

            var after_linebreaks = abs_end_quote_index + end_value_string.len;
            while (after_linebreaks < flac_data.len and flac_data[after_linebreaks] == '\n') {
                after_linebreaks += 1;
            }

            flac_data = flac_data[after_linebreaks..];
        }
    }

    var count: usize = 0;
    if (id3v2_metadata != null) count += 1;
    if (flac_metadata != null) count += 1;

    var tags_slice = try allocator.alloc(TypedMetadata, count);
    errdefer allocator.free(tags_slice);

    var tag_index: usize = 0;
    if (id3v2_metadata) |val| {
        tags_slice[tag_index] = .{ .id3v2 = val };
        tag_index += 1;
    }
    if (flac_metadata) |val| {
        tags_slice[tag_index] = .{ .flac = val };
        tag_index += 1;
    }

    return AllMetadata{
        .tags = tags_slice,
        .allocator = allocator,
    };
}

test "taglib compare" {
    const allocator = std.testing.allocator;
    //const filepath = "/media/drive4/music/Wolfpack - Allday Hell [EAC-FLAC]/01 - No Neo Bastards.flac";
    const filepath = "/media/drive4/music/'selvə - セルヴァ/'selvə- - セルヴァ - 01 estens.mp3";
    var probed_metadata = try getTagLibMetadata(allocator, null, filepath);
    defer probed_metadata.deinit();

    var file = try std.fs.cwd().openFile(filepath, .{});
    defer file.close();

    var stream_source = std.io.StreamSource{ .file = file };
    var metadata = try meta.readAll(allocator, &stream_source);
    defer metadata.deinit();

    try compareMetadata(allocator, &probed_metadata, &metadata);
}
