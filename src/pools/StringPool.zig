const std = @import("std");
const DexIR = @import("../ir.zig").ir.DexIR;

pub const StringPool = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(u32),
    list: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) !StringPool {
        return StringPool{
            .allocator = allocator,
            .map = std.StringHashMap(u32).init(allocator),
            .list = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn add(self: *StringPool, s: []const u8) !void {
        if (!self.map.contains(s)) {
            const utf16len: u32 = @intCast(try std.unicode.calcUtf16LeLen(s));
            _ = try self.map.put(s, utf16len);
            _ = try self.list.append(s);
        }
    }

    pub fn len(self: *StringPool) u32 {
        return @intCast(self.map.count());
    }

    pub fn fromDexIR(self: *StringPool, ir: *const DexIR) !void {
        for (ir.classes) |cls| {
            _ = try self.add(cls.name);

            for (cls.methods) |m| {
                _ = try self.add(m.name);
                for (m.code) |instr| {
                    if (instr.operand) |operand| {
                        switch (operand) {
                            .literal => |value| {
                                _ = try self.add(
                                    value.string,
                                );
                            },
                            .reference => |value| {
                                switch (value) {
                                    .string => try self.add(
                                        value.string,
                                    ),
                                    .type => try self.add(
                                        value.type,
                                    ),
                                    .method => {
                                        try self.add(
                                            value.method.class,
                                        );
                                        try self.add(
                                            value.method.name,
                                        );
                                        try self.add(
                                            value.method.proto.return_type,
                                        );
                                        for (
                                            value.method.proto.parameters,
                                        ) |parameter| {
                                            try self.add(
                                                parameter,
                                            );
                                        }
                                        const shorty = try self.addShortyFromSignature(
                                            value.method.proto.parameters,
                                            value.method.proto.return_type,
                                        );
                                        try self.add(shorty);
                                    },
                                }
                            },
                        }
                    }
                }
            }
        }
    }

    pub fn addShortyFromSignature(
        self: *StringPool,
        parameters: []const []const u8,
        return_type: []const u8,
    ) ![]const u8 {
        var buf = std.ArrayList(u8).init(self.map.allocator);
        defer buf.deinit();

        try buf.append(try mapTypeToShorty(return_type));
        for (parameters) |param| {
            try buf.append(try mapTypeToShorty(param));
        }

        const shorty = try buf.toOwnedSlice();
        try self.add(shorty);
        return shorty;
    }

    fn mapTypeToShorty(type_: []const u8) !u8 {
        if (std.mem.eql(u8, type_, "V")) return 'V';
        if (std.mem.eql(u8, type_, "Z")) return 'Z';
        if (std.mem.eql(u8, type_, "B")) return 'B';
        if (std.mem.eql(u8, type_, "S")) return 'S';
        if (std.mem.eql(u8, type_, "C")) return 'C';
        if (std.mem.eql(u8, type_, "I")) return 'I';
        if (std.mem.eql(u8, type_, "J")) return 'J';
        if (std.mem.eql(u8, type_, "F")) return 'F';
        if (std.mem.eql(u8, type_, "D")) return 'D';
        if (type_.len > 0 and type_[0] == 'L') return 'L';
        if (type_.len > 0 and type_[0] == '[') return 'L';
        return error.UnknownShortyType;
    }

    pub fn sort(self: *StringPool) !void {
        const sorted = try self.list.toOwnedSlice();
        std.mem.sort([]const u8, sorted, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                const va = std.unicode.Utf8View.init(a) catch unreachable;
                const vb = std.unicode.Utf8View.init(b) catch unreachable;
                var ita = va.iterator();
                var itb = vb.iterator();
                while (true) {
                    const ca = ita.nextCodepoint();
                    const cb = itb.nextCodepoint();
                    if (ca == null and cb == null) return false;
                    if (ca == null) return true;
                    if (cb == null) return false;
                    if (ca.? != cb.?) return ca.? < cb.?;
                }
            }
        }.less);

        self.list.deinit();
        self.list = std.ArrayList([]const u8).init(self.allocator);
        for (sorted) |s| {
            const dup = try self.allocator.dupe(u8, s);
            try self.list.append(dup);
        }
    }

    pub fn emitStringData(self: *StringPool, stream: anytype) ![]u32 {
        const writer = stream.writer();
        var offsets = std.ArrayList(u32).init(self.allocator);
        var pos: u32 = 0;
        for (self.list.items) |s| {
            try offsets.append(pos);
            const start: u32 = @intCast(try stream.getPos());
            try std.leb.writeUleb128(writer, self.map.get(s).?);
            _ = try writer.write(s);
            _ = try writer.write("\x00");
            const end: u32 = @intCast(try stream.getPos());
            pos += end - start;
        }
        try writer.writeByte(0x00);
        return offsets.toOwnedSlice();
    }

    pub fn emitStringId(
        self: *StringPool,
        writer: anytype,
        offsets: []u32,
        absolute: u32,
    ) !void {
        _ = self;
        for (offsets) |offset| {
            _ = try writer.writeInt(u32, absolute + offset, .little);
        }
    }

    fn uleb128Size(n: u32) u32 {
        var size_: u32 = 0;
        var value = n;
        while (true) {
            size_ += 1;
            if (value < 0x80) break;
            value >>= 7;
        }
        return size_;
    }

    pub fn indexOf(self: *StringPool, string: []const u8) ?u16 {
        for (self.list.items, 0..) |item, i| {
            if (std.mem.eql(u8, string, item)) {
                return @intCast(i);
            }
        }
        return null;
    }

    pub fn size(self: *const StringPool) u32 {
        var size_: u32 = 0;
        for (self.list.items) |s| {
            size_ += uleb128Size(@intCast(s.len));
            size_ += @intCast(s.len);
            size_ += "\x00".len;
        }
        return size_;
    }
};
