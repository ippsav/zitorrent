const std = @import("std");
const bencoded = @import("bencoded.zig");

const block_size = 16 * 1024;

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
};

pub const MessageType = enum(u8) {
    choke = 0,
    unchoke = 1,
    interested = 2,
    @"not interested" = 3,
    have = 4,
    bitfield = 5,
    request = 6,
    piece = 7,
    cancel = 8,

    pub fn fromByte(byte: u8) MessageType {
        return @enumFromInt(byte);
    }
};

// Request:
//  index: the zero-based piece index
//  begin: the zero-based byte offset within the piece
//  length: the length of the block in bytes

pub const RequestPayload = struct {
    index: u32,
    begin: u32,
    length: u32,
};

pub const PiecePayload = struct {
    index: u32,
    begin: u32,
    block: []u8,
};

pub const Payload = union(MessageType) {
    choke: void,
    unchoke: void,
    interested: void,
    @"not interested": void,
    have: u32,
    bitfield: void,
    request: RequestPayload,
    piece: PiecePayload,
    cancel: RequestPayload,
};

pub const Message = struct {
    type: MessageType,
    payload: Payload,

    pub fn init(m_type: MessageType, payload: Payload) Message {
        return .{ .type = m_type, .payload = payload };
    }
};

pub const BittorrentClient = struct {
    peers: []std.net.Address,
    torrent_metadata: TorrentMetadata,
    connection_stream: std.net.Stream,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, peers: []std.net.Address, torrent_metadata: TorrentMetadata) !BittorrentClient {
        for (peers) |peer| {
            const connection_stream = std.net.tcpConnectToAddress(peer) catch {
                continue;
            };
            return .{
                .allocator = allocator,
                .peers = peers,
                .torrent_metadata = torrent_metadata,
                .connection_stream = connection_stream,
            };
        }
        return error.ErrorConnectingToPeers;
    }

    pub fn handshake(self: BittorrentClient, hash: [20]u8) !HandshakeMessage {
        const hm = HandshakeMessage{
            .info_hash = hash,
        };
        const w = self.connection_stream.writer();
        const r = self.connection_stream.reader();
        try w.writeStruct(hm);
        return try r.readStruct(HandshakeMessage);
    }

    pub fn download_piece(
        self: BittorrentClient,
        piece_index: usize,
    ) !void {
        if (piece_index >= self.torrent_metadata.info.pieces.len / 20) return error.InvalidPieceIndex;

        const piece_length = blk: {
            if (piece_index == (self.torrent_metadata.info.pieces.len / 20) - 1) {
                const remainder = self.torrent_metadata.info.length % self.torrent_metadata.info.@"piece length";
                if (remainder != 0) break :blk remainder;
            }
            break :blk self.torrent_metadata.info.@"piece length";
        };

        const bm = try self.readMessage();

        std.debug.assert(bm.type == .bitfield);
        std.debug.print("{any}\n", .{bm});

        const im = Message.init(.interested, .{ .interested = {} });
        try self.sendMessage(im);

        _ = try self.readMessage();

        const num_of_blocks = piece_length / block_size;
        const last_block_size = piece_length % block_size;
        std.debug.print("num of blocks: {d}\n", .{num_of_blocks});

        for (0..num_of_blocks) |i| {
            const rm = Message{
                .type = .request,
                .payload = .{ .request = .{
                    .length = @intCast(block_size),
                    .index = @intCast(piece_index),
                    .begin = @intCast(block_size * i),
                } },
            };

            try self.sendMessage(rm);

            const pm = try self.readMessage();
            std.debug.print("piece message {any}\n", .{pm});
        }
        if (last_block_size != 0) {}

        return error.Test;
    }

    // The message id for request is 6.
    // The payload for this message consists of:
    // index: the zero-based piece index
    // begin: the zero-based byte offset within the piece
    // This'll be 0 for the first block, 2^14 for the second block, 2*2^14 for the third block etc.
    // length: the length of the block in bytes
    // This'll be 2^14 (16 * 1024) for all blocks except the last one.
    // The last block will contain 2^14 bytes or less, you'll need calculate this value using the piece length.

    pub fn readMessage(self: BittorrentClient) !Message {
        const r = self.connection_stream.reader();
        var ml: u32 = 0;
        while (ml == 0) ml = try r.readInt(u32, .big);

        const b = try r.readByte();
        std.debug.print("message type byte: {d}\n", .{b});
        const mt = MessageType.fromByte(b);

        return switch (mt) {
            .bitfield => Message.init(mt, .{ .bitfield = {} }),
            .choke => Message.init(mt, .{ .choke = {} }),
            .unchoke => Message.init(mt, .{ .unchoke = {} }),
            .interested => Message.init(mt, .{ .interested = {} }),
            .@"not interested" => Message.init(mt, .{ .@"not interested" = {} }),
            .have => {
                const index = try r.readInt(u32, .big);
                return Message.init(mt, .{ .have = index });
            },
            .request, .cancel => {
                const index = try r.readInt(u32, .big);
                const begin = try r.readInt(u32, .big);
                const length = try r.readInt(u32, .big);
                return Message.init(mt, .{
                    .request = .{ .index = index, .begin = begin, .length = length },
                });
            },
            .piece => {
                const index = try r.readInt(u32, .big);
                const begin = try r.readInt(u32, .big);
                const block = try self.allocator.alloc(u8, ml - 9);
                _ = try r.readAll(block);
                return Message.init(mt, .{
                    .piece = .{ .index = index, .begin = begin, .block = block },
                });
            },
        };
    }

    pub inline fn sendMessage(self: BittorrentClient, message: Message) !void {
        const w = self.connection_stream.writer();

        //'choke', 'unchoke', 'interested', and 'not interested' have no payload.

        switch (message.type) {
            .choke, .unchoke, .interested, .@"not interested" => {
                try w.writeInt(u32, 1, .big);
                try w.writeInt(u8, @intFromEnum(message.type), .big);
            },
            .request => {
                const length: u32 = @sizeOf(RequestPayload) + 1;

                // Logging
                std.debug.print(
                    \\message length: {d}
                    \\message.type: {d}
                    \\index: {d}
                    \\begin: {d}
                    \\payload length: {d}
                    \\
                , .{ length, @intFromEnum(message.type), message.payload.request.index, message.payload.request.begin, message.payload.request.length });
                const payload = message.payload.request;
                try w.writeInt(u32, length, .big);
                try w.writeByte(@intFromEnum(message.type));
                try w.writeInt(u32, payload.index, .big);
                try w.writeInt(u32, payload.begin, .big);
                try w.writeInt(u32, payload.length, .big);
            },
            else => return,
        }
    }
};

pub fn handshakePeerAndGetStream(handshake: HandshakeMessage, address: std.net.Address) !std.net.Stream {
    const connection_stream = try std.net.tcpConnectToAddress(address);
    const writer = connection_stream.writer();
    try writer.writeStruct(handshake);
    return connection_stream;
}

pub fn tryHandshakePeersAndGetStream(handshake: HandshakeMessage, peers: []std.net.Address) !std.net.Stream {
    for (peers) |peer| {
        return handshakePeerAndGetStream(handshake, peer) catch {
            continue;
        };
    }
    return error.ErrorConnectingToPeers;
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

test "MessageType" {
    const byte = '1';

    const e = MessageType.fromByte(byte);
    try std.testing.expectEqual(.unchoke, e);
}
