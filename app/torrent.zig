const std = @import("std");
const bencoded = @import("bencoded.zig");

pub const TorrentInfo = struct {
    length: usize,
    name: []const u8,
    @"piece length": usize,
    pieces: []const u8,

    pub fn getInfoHash(self: @This()) ![std.crypto.hash.Sha1.digest_length]u8 {
        var sha1_hash = std.crypto.hash.Sha1.init(.{});
        try bencoded.encodeValue(self, sha1_hash.writer());
        return sha1_hash.finalResult();
    }

    pub fn getPiecesHashes(self: @This(), gpa: std.mem.Allocator) ![][std.crypto.hash.Sha1.digest_length]u8 {
        var iterator = std.mem.window(u8, self.pieces, 20, 20);
        var hash_pieces = try gpa.alloc([std.crypto.hash.Sha1.digest_length]u8, @divTrunc(self.pieces.len + 19, 20));

        var index: usize = 0;
        while (iterator.next()) |v| {
            hash_pieces[index] = v[0..20].*;
            index += 1;
        }
        return hash_pieces;
    }
};

pub const TorrentMetadata = struct {
    announce: []const u8,
    info: TorrentInfo,

    pub fn getTorrentMetadata(torrent_data: bencoded.Value) !TorrentMetadata {
        std.debug.assert(std.meta.activeTag(torrent_data) == .dictionary);
        const info_map: bencoded.Value = torrent_data.dictionary.get("info") orelse {
            fatal("Error missing info in torrent metadata\n", .{});
        };
        std.debug.assert(std.meta.activeTag(info_map) == .dictionary);

        const announce: []const u8 = torrent_data.dictionary.get("announce").?.string;

        const length: usize = @bitCast(info_map.dictionary.get("length").?.int);
        const name: []const u8 = info_map.dictionary.get("name").?.string;
        const piece_length: usize = @bitCast(info_map.dictionary.get("piece length").?.int);
        const pieces: []const u8 = info_map.dictionary.get("pieces").?.string;

        return TorrentMetadata{ .info = TorrentInfo{
            .pieces = pieces,
            .@"piece length" = piece_length,
            .length = length,
            .name = name,
        }, .announce = announce };
    }
};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}
