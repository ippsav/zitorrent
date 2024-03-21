const std = @import("std");
const stdout = std.io.getStdOut().writer();
// const Scanner = @import("./bencoded.zig").Scanner;
const bencoded = @import("./bencoded.zig");
const torrent = @import("torrent.zig");
const TorrentMetadata = @import("torrent.zig").TorrentMetadata;
const TorrentClient = @import("client.zig");
const peekStream = @import("peek_stream.zig").peekStream;
const assert = std.debug.assert;

const Command = enum { decode, info, peers, handshake };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 100 }){};
    defer {
        assert(gpa.deinit() == .ok);
    }
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 3) {
        fatalHelp();
    }

    const command = std.meta.stringToEnum(Command, args[1]) orelse {
        fatalHelp();
    };

    switch (command) {
        .decode => {
            var fixed_buffer_stream = std.io.fixedBufferStream(args[2]);
            var peek_stream = peekStream(1, fixed_buffer_stream.reader());
            var value = try bencoded.decodeFromStream(allocator, &peek_stream);
            try stdout.print("{}\n", .{value});
            value.deinit(allocator);
        },
        .info => {
            const path = args[2];
            var file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
            defer file.close();

            var peek_stream = peekStream(1, file.reader());

            var decoded_content = try bencoded.decodeFromStream(allocator, &peek_stream);
            defer decoded_content.deinit(allocator);

            const torrent_meta_data = try TorrentMetadata.getTorrentMetadata(decoded_content);
            const hash = try torrent_meta_data.info.getInfoHash();
            var piece_hashes_iterator = torrent_meta_data.info.getPiecesHashesIterator();
            // Tracker URL: http://bittorrent-test-tracker.codecrafters.io/announce
            // Length: 92063
            // Info Hash: d69f91e6b2ae4c542468d1073a71d4ea13879a7f
            // Piece Length: 32768
            // Piece Hashes:
            // e876f67a2a8886e8f36b136726c30fa29703022d
            // 6e2275e604a0766656736e81ff10b55204ad8d35
            // f00d937a0213df1982bc8d097227ad9e909acc17
            try stdout.print(
                \\Tracker URL: {s}
                \\Length: {d}
                \\Info Hash: {s}
                \\Piece Length: {d}
                \\Pieces Hashes:
                \\
            , .{ torrent_meta_data.announce, torrent_meta_data.info.length, std.fmt.fmtSliceHexLower(&hash), torrent_meta_data.info.@"piece length" });
            while (piece_hashes_iterator.next()) |h| {
                try stdout.print("{s}\n", .{std.fmt.fmtSliceHexLower(&h)});
            }
        },
        .peers => {
            const path = args[2];
            var file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
            defer file.close();

            var peek_stream = peekStream(1, file.reader());

            var decoded_content = try bencoded.decodeFromStream(allocator, &peek_stream);
            defer decoded_content.deinit(allocator);

            const torrent_meta_data = try TorrentMetadata.getTorrentMetadata(decoded_content);
            var torrent_client = TorrentClient.new(allocator, torrent_meta_data);
            defer torrent_client.deinit();
            const peers = try torrent_client.getPeers();
            defer allocator.free(peers);
            for (peers) |peer| {
                try stdout.print("{}\n", .{peer});
            }
        },
        .handshake => {
            const path = args[2];
            if (args.len < 4) {
                fatal("Missing peer ip (<peer_ip>:<peer_port>)", .{});
            }
            const ip_str = std.mem.trim(u8, args[3], " ");
            const delimiter_index = std.mem.indexOfScalar(u8, ip_str, ':') orelse {
                fatal("Invalid peer ip. (<peer_ip>:<peer_port>)", .{});
            };
            const port = std.fmt.parseInt(u16, ip_str[delimiter_index + 1 ..], 10) catch {
                fatal("Invalid peer port. (<peer_ip>:<peer_port>)", .{});
            };
            const ip = std.net.Address.resolveIp(ip_str[0..delimiter_index], port) catch {
                fatal("Invalid peer ip. (<peer_ip>:<peer_port>)", .{});
            };

            var file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
            defer file.close();

            var peek_stream = peekStream(1, file.reader());

            var decoded_content = try bencoded.decodeFromStream(allocator, &peek_stream);
            defer decoded_content.deinit(allocator);

            const torrent_meta_data = try TorrentMetadata.getTorrentMetadata(decoded_content);
            const hash = try torrent_meta_data.info.getInfoHash();

            const handshake_message = torrent.HandshakeMessage{
                .info_hash = hash,
            };
            std.debug.print("attemption handshake with: {}\n", .{ip});
            const reader = try torrent.handshakePeer(handshake_message, ip);
            const handshake = try reader.readStruct(torrent.HandshakeMessage);
            try stdout.print("Peer ID: {s}\n", .{std.fmt.fmtSliceHexLower(&handshake.peer_id)});
        },
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

fn fatalHelp() noreturn {
    fatal("Usage: your_bittorent.zig <command> <args>", .{});
}
