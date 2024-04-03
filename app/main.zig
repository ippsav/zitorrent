const std = @import("std");
const stdout = std.io.getStdOut().writer();
// const Scanner = @import("./bencoded.zig").Scanner;
const bencoded = @import("./bencoded.zig");
const torrent = @import("torrent.zig");
const TorrentMetadata = @import("torrent.zig").TorrentMetadata;
const TorrentClient = @import("client.zig");
const peekStream = @import("peek_stream.zig").peekStream;
const assert = std.debug.assert;

const Command = enum { decode, info, peers, handshake, download_piece };

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

            const connection_stream = try torrent.handshakePeerAndGetStream(handshake_message, ip);
            const reader = connection_stream.reader();
            const handshake = try reader.readStruct(torrent.HandshakeMessage);
            try stdout.print("Peer ID: {s}\n", .{std.fmt.fmtSliceHexLower(&handshake.peer_id)});
        },
        .download_piece => {
            if (args.len < 6) {
                fatal("Missing arguments expected 6 args got {d}. (your_bittorent download_piece -o <output-path> <torrent-path> <piece-number>)", .{args.len});
            }

            if (!std.mem.eql(u8, args[2], "-o"))
                fatal("Invalid flag. (your_bittorent download_piece -o <output-path> <torrent-path> <piece-number>)", .{});

            // const temp_path = args[3];
            const torrent_path = args[4];
            const piece_number = std.fmt.parseInt(u32, args[5], 10) catch {
                fatal("Invalid piece number got {s}. (your_bittorent download_piece -o <output-path> <torrent-path> <piece-number>)", .{args[5]});
            };

            var file = try std.fs.cwd().openFile(torrent_path, .{ .mode = .read_only });
            defer file.close();

            var peek_stream = peekStream(1, file.reader());

            // Decoding torrent file
            var decoded_content = try bencoded.decodeFromStream(allocator, &peek_stream);
            defer decoded_content.deinit(allocator);
            const torrent_metadata = try TorrentMetadata.getTorrentMetadata(decoded_content);

            // Getting peers
            var torrent_client = TorrentClient.new(allocator, torrent_metadata);
            defer torrent_client.deinit();

            const peers = try torrent_client.getPeers();
            defer allocator.free(peers);

            const bt_client = try torrent.BittorrentClient.init(allocator, peers, torrent_metadata);
            const hash = try torrent_metadata.info.getInfoHash();

            // handshake with peer
            const hm = try bt_client.handshake(hash);
            try stdout.print("Peer ID: {s}\n", .{std.fmt.fmtSliceHexLower(&hm.peer_id)});

            // get peer messages
            const p = try bt_client.download_piece(piece_number);
            _ = p;
        },
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

fn fatalHelp() noreturn {
    fatal("Usage: your_bittorent <command> <args>", .{});
}
