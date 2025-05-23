const std = @import("std");
const DexIR = @import("../ir.zig").ir.DexIR;
const StringPool = @import("StringPool.zig").StringPool;

pub const TypePool = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(u32),
    list: std.ArrayList([]const u8),
    unsorted: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) !TypePool {
        return TypePool{
            .allocator = allocator,
            .map = std.StringHashMap(u32).init(allocator),
            .list = std.ArrayList([]const u8).init(allocator),
            .unsorted = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn add(self: *TypePool, string_pool: *StringPool, s: []const u8) !void {
        if (!self.map.contains(s)) {
            const index = string_pool.indexOf(
                s,
            ) orelse return error.StringPoolNotFound;
            _ = try self.map.put(s, index);
            _ = try self.list.append(s);
            _ = try self.unsorted.append(s);
        }
    }

    pub fn fromDexIR(self: *TypePool, string_pool: *StringPool, dex_ir: *const DexIR) !void {
        for (dex_ir.classes) |cls| {
            _ = try self.add(string_pool, cls.name);

            for (cls.methods) |m| {
                _ = try self.add(string_pool, m.proto.return_type);
                for (m.proto.parameters) |p| {
                    try self.add(string_pool, p);
                }
                for (m.code) |instr| {
                    if (instr.operand) |operand| {
                        switch (operand) {
                            .reference => |val| {
                                switch (val) {
                                    .type => |val_| {
                                        try self.add(string_pool, val_);
                                    },
                                    .method => |method_reference| {
                                        try self.add(string_pool, method_reference.class);
                                        try self.add(
                                            string_pool,
                                            method_reference.proto.return_type,
                                        );
                                        for (method_reference.proto.parameters) |p| {
                                            try self.add(string_pool, p);
                                        }
                                    },
                                    else => {},
                                }
                            },
                            else => {},
                        }
                    }
                }
            }
        }
    }

    pub fn emitTypeIds(self: *TypePool, writer: anytype) !void {
        const Entry = struct {
            key: []const u8,
            value: u32,
        };

        var entries = try self.allocator.alloc(Entry, self.map.count());
        defer self.allocator.free(entries);

        var i: usize = 0;
        var it = self.map.iterator();
        while (it.next()) |entry| {
            entries[i] = Entry{
                .key = entry.key_ptr.*,
                .value = entry.value_ptr.*,
            };
            i += 1;
        }

        std.mem.sort(Entry, entries, {}, struct {
            pub fn lessThan(_: void, a: Entry, b: Entry) bool {
                return a.value < b.value;
            }
        }.lessThan);

        for (entries) |e| {
            try writer.writeInt(u32, e.value, .little);
        }
    }

    pub fn sort(self: *TypePool) !void {
        std.mem.sort([]const u8, self.list.items, self.map, struct {
            pub fn lessThan(map: std.StringHashMap(u32), a: []const u8, b: []const u8) bool {
                const a_idx = map.get(a) orelse unreachable;
                const b_idx = map.get(b) orelse unreachable;
                return a_idx < b_idx;
            }
        }.lessThan);
    }

    pub fn indexOf(self: *const TypePool, name: []const u8) ?u16 {
        for (self.list.items, 0..) |s, i| {
            if (std.mem.eql(u8, s, name)) return @intCast(i);
        }
        return null;
    }
};
