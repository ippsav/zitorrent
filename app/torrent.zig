const std = @import("std");
const bencoded = @import("bencoded.zig");

pub const TorrentInfo = struct {
    length: usize,
    name: []const u8,
    piece_length: usize,
    pieces: []const u8,

    pub fn getInfoHash(self: @This()) ![std.crypto.hash.Sha1.digest_length]u8 {
        var hasher = std.crypto.hash.Sha1.init(.{});
        try hasher.writer().writeByte('d');
        try bencoded.encodeValue(.{ .string = "length" }, hasher.writer());
        try bencoded.encodeValue(.{ .int = @intCast(self.length) }, hasher.writer());
        try bencoded.encodeValue(.{ .string = "name" }, hasher.writer());
        try bencoded.encodeValue(.{ .string = self.name }, hasher.writer());
        try bencoded.encodeValue(.{ .string = "piece_length" }, hasher.writer());
        try bencoded.encodeValue(.{ .int = @intCast(self.piece_length) }, hasher.writer());
        try bencoded.encodeValue(.{ .string = "pieces" }, hasher.writer());
        try bencoded.encodeValue(.{ .string = self.pieces }, hasher.writer());
        try hasher.writer().writeByte('e');
        return hasher.finalResult();
    }
};

pub const TorrentMetadata = struct {
    announce: []const u8,
    info: TorrentInfo,

    pub fn getTorrentMetadata(torrent_data: bencoded.Value) !TorrentMetadata {
        std.debug.assert(torrent_data == .dictionary);
        const info_map: bencoded.Value = torrent_data.dictionary.get("info") orelse {
            fatal("Error missing info in torrent metadata\n", .{});
        };
        std.debug.assert(info_map == .dictionary);

        const announce: []const u8 = torrent_data.dictionary.get("announce").?.string;

        const length: usize = @bitCast(info_map.dictionary.get("length").?.int);
        const name: []const u8 = info_map.dictionary.get("name").?.string;
        const piece_length: usize = @bitCast(info_map.dictionary.get("piece length").?.int);
        const pieces: []const u8 = info_map.dictionary.get("pieces").?.string;

        return TorrentMetadata{ .info = TorrentInfo{
            .pieces = pieces,
            .piece_length = piece_length,
            .length = length,
            .name = name,
        }, .announce = announce };
    }
};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}
