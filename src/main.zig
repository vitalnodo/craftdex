const std = @import("std");
const lexer_module = @import("lexer.zig");
const Lexer = lexer_module.Lexer;
const Token = lexer_module.Token;
const Parser = @import("parser.zig").Parser;
const DexIR = @import("ir.zig").ir.DexIR;
const DexEmitter = @import("emitter.zig").DexEmitter;

const MAX_SMALI_SIZE = 4096;
const MAX_DEX_SIZE = 8192;

fn usage() void {
    std.debug.print(
        "Usage: craftdex dex HelloActivity.smali [-o classes.dex]\n",
        .{},
    );
}

fn lexAndParse(arena: *std.heap.ArenaAllocator, src: []const u8) !DexIR {
    const allocator = arena.allocator();
    var lexer = Lexer.init(src);
    var tokens = std.ArrayList(Token).init(allocator);
    while (true) {
        const tok = lexer.next();
        if (tok.kind == .EOF) break;
        try tokens.append(tok);
    }
    var parser = Parser.init(
        arena,
        src,
        tokens.items,
    );
    return try parser.parseDexIR();
}

fn compileDex(
    arena: *std.heap.ArenaAllocator,
    dex_ir: *const DexIR,
) ![]const u8 {
    const allocator = arena.allocator();
    const buf = try allocator.alloc(u8, MAX_DEX_SIZE);
    @memset(buf, 0);
    var fbs = std.io.fixedBufferStream(buf);
    var emitter = try DexEmitter.init(arena);
    try emitter.prepare(dex_ir);
    _ = try emitter.write(&fbs);
    return buf[0..emitter.header.file_size];
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const raw_args = try std.process.argsAlloc(allocator);
    if (raw_args.len < 3 or !std.mem.eql(u8, raw_args[1], "dex")) {
        usage();
        return;
    }

    const input_path = raw_args[2];
    var output_path: []const u8 = "classes.dex";

    if (raw_args.len >= 5 and std.mem.eql(u8, raw_args[3], "-o")) {
        output_path = raw_args[4];
    } else if (raw_args.len > 3) {
        usage();
        return;
    }

    const smali_code = try std.fs.cwd().readFileAlloc(
        allocator,
        input_path,
        MAX_SMALI_SIZE,
    );
    const dex_ir = try lexAndParse(&arena, smali_code);
    const dex_bytes = try compileDex(&arena, &dex_ir);

    const out_file = try std.fs.cwd().createFile(
        output_path,
        .{ .truncate = true },
    );
    defer out_file.close();
    try out_file.writeAll(dex_bytes);

    std.debug.print(
        "✅ Wrote {s} ({d} bytes)\n",
        .{ output_path, dex_bytes.len },
    );
}
