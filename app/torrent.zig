const std = @import("std");
const bencoded = @import("bencoded.zig");

pub const HashPiecesIterator = struct {
    cursor: usize,
    buffer: []const u8,

    pub fn next(self: *HashPiecesIterator) ?[20]u8 {
        if (self.cursor >= self.buffer.len) return null;
        const start = self.cursor;
        self.cursor = start + 20;
        const end = if (start + 20 < self.buffer.len) blk: {
            break :blk start + 20;
        } else blk: {
            break :blk self.buffer.len;
        };

        return self.buffer[start..end][0..20].*;
    }
};

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

    pub fn getPiecesHashesIterator(self: @This()) HashPiecesIterator {
        std.debug.assert(self.pieces.len % 20 == 0);
        return .{
            .buffer = self.pieces,
            .cursor = 0,
        };
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

pub const HandshakeMessage = extern struct {
    protocol_length: u8 align(1) = 19,
    protocol: [19]u8 align(1) = "BitTorrent protocol".*,
    reserved: [8]u8 align(1) = std.mem.zeroes([8]u8),
    info_hash: [20]u8 align(1),
    peer_id: [20]u8 align(1) = "00112233445566778899".*,
    // length of the protocol string (BitTorrent protocol) which is 19 (1 byte)
    // the string BitTorrent protocol (19 bytes)
    // eight reserved bytes, which are all set to zero (8 bytes)
    // sha1 infohash (20 bytes) (NOT the hexadecimal representation, which is 40 bytes long)
    // peer id (20 bytes) (you can use 00112233445566778899 for this challenge)

};

pub fn handshakePeer(handshake: HandshakeMessage, address: std.net.Address) !std.net.Stream.Reader {
    const connection_stream = try std.net.tcpConnectToAddress(address);
    const writer = connection_stream.writer();
    try writer.writeStruct(handshake);
    return connection_stream.reader();
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}
