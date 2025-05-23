const std = @import("std");
const ProtoIR = @import("../ir.zig").ir.ProtoIR;
const DexIR = @import("../ir.zig").ir.DexIR;
const StringPool = @import("StringPool.zig").StringPool;
const TypePool = @import("TypePool.zig").TypePool;

const ProtoContext = struct {
    pub fn hash(_: ProtoContext, key: ProtoIR) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.return_type);
        for (key.parameters) |param| {
            hasher.update(param);
        }
        return hasher.final();
    }

    pub fn eql(_: ProtoContext, a: ProtoIR, b: ProtoIR) bool {
        if (!std.mem.eql(u8, a.return_type, b.return_type)) return false;
        if (a.parameters.len != b.parameters.len) return false;
        for (a.parameters, b.parameters) |pa, pb| {
            if (!std.mem.eql(u8, pa, pb)) return false;
        }
        return true;
    }
};

pub const ProtoPool = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(ProtoIR),
    unsorted: std.ArrayList(ProtoIR),
    map: std.HashMap(ProtoIR, u32, ProtoContext, 80),

    pub fn init(allocator: std.mem.Allocator) !ProtoPool {
        return ProtoPool{
            .allocator = allocator,
            .list = std.ArrayList(ProtoIR).init(allocator),
            .unsorted = std.ArrayList(ProtoIR).init(allocator),
            .map = std.HashMap(ProtoIR, u32, ProtoContext, 80).init(allocator),
        };
    }

    pub fn add(
        self: *ProtoPool,
        strings: *StringPool,
        parameters: []const []const u8,
        return_type: []const u8,
    ) !u32 {
        const shorty = try strings.addShortyFromSignature(parameters, return_type);

        const proto = ProtoIR{
            .shorty = shorty,
            .return_type = return_type,
            .parameters = parameters,
        };

        if (self.map.get(proto)) |index| {
            return index;
        }

        const idx: u32 = @intCast(self.list.items.len);
        try self.list.append(proto);
        try self.unsorted.append(proto);
        try self.map.put(proto, idx);
        return idx;
    }

    pub fn fromDexIR(
        self: *ProtoPool,
        strings: *StringPool,
        ir: *const DexIR,
    ) !void {
        for (ir.classes) |class_ir| {
            for (class_ir.methods) |method_ir| {
                _ = try self.add(
                    strings,
                    method_ir.proto.parameters,
                    method_ir.proto.return_type,
                );
                for (method_ir.code) |instr| {
                    if (instr.operand) |operand| {
                        switch (operand) {
                            .reference => |val| {
                                switch (val) {
                                    .method => |val_| {
                                        _ = try self.add(
                                            strings,
                                            val_.proto.parameters,
                                            val_.proto.return_type,
                                        );
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

    pub fn emitProtoIds(
        self: *ProtoPool,
        strings: *StringPool,
        types: *TypePool,
        offsets: []const u32,
        stream: anytype,
    ) !void {
        const writer = stream.writer();
        for (self.list.items, 0..) |proto, i| {
            const shorty_idx = strings.indexOf(proto.shorty);
            const return_idx = types.indexOf(proto.return_type);
            const params_off: u32 = offsets[i];

            const item = ProtoIdItem{
                .shorty_idx = shorty_idx orelse 0,
                .return_type_idx = return_idx orelse 0,
                .parameters_off = params_off,
            };
            try writer.writeStructEndian(item, .little);
        }
    }

    pub fn writeTypeList(
        self: *ProtoPool,
        type_pool: *const TypePool,
        writer: anytype,
    ) ![]u32 {
        const unsorted = self.unsorted.items;
        const sorted = self.list.items;

        const count = sorted.len;
        const offsets = try self.allocator.alloc(u32, count);

        var offset: u32 = @intCast(try writer.context.getPos());

        for (unsorted) |proto| {
            const param_types = proto.parameters;
            const param_count = param_types.len;

            var this_offset: u32 = 0;
            if (param_count == 0) {
                this_offset = 0;
            } else {
                this_offset = offset;

                try writer.writeInt(u32, @intCast(param_count), .little);
                offset += 4;

                for (param_types) |type_str| {
                    const type_idx = type_pool.indexOf(type_str).?;
                    try writer.writeInt(u16, @intCast(type_idx), .little);
                    offset += 2;
                }

                const aligned_offset = alignTo(offset, 4);
                const pad = aligned_offset - offset;
                if (pad > 0) {
                    try writer.writeByteNTimes(0x00, pad);
                }
                offset = aligned_offset;
            }

            const idx_in_sorted = for (sorted, 0..) |p, i| {
                if (p.eql(proto)) break i;
            } else return error.ProtoNotInSorted;

            offsets[idx_in_sorted] = this_offset;
        }

        return offsets;
    }

    fn alignTo(value: u32, alignment: u32) u32 {
        return (value + alignment - 1) & ~(alignment - 1);
    }

    pub fn sort(self: *ProtoPool) !void {
        const items = self.list.items;
        std.mem.sort(ProtoIR, items, {}, struct {
            pub fn lessThan(_: void, a: ProtoIR, b: ProtoIR) bool {
                if (!std.mem.eql(u8, a.return_type, b.return_type)) {
                    return std.mem.lessThan(u8, a.return_type, b.return_type);
                }
                if (a.parameters.len != b.parameters.len) {
                    return a.parameters.len < b.parameters.len;
                }
                for (a.parameters, b.parameters) |pa, pb| {
                    if (!std.mem.eql(u8, pa, pb)) {
                        return std.mem.lessThan(u8, pa, pb);
                    }
                }
                return false;
            }
        }.lessThan);
    }

    pub fn indexOf(self: *ProtoPool, parameters: []const []const u8, return_type: []const u8) ?u32 {
        for (self.list.items, 0..) |proto, i| {
            if (std.mem.eql(u8, proto.return_type, return_type) and
                proto.parameters.len == parameters.len)
            {
                var all_equal = true;
                for (parameters, proto.parameters) |p, q| {
                    if (!std.mem.eql(u8, p, q)) {
                        all_equal = false;
                        break;
                    }
                }
                if (all_equal) return @intCast(i);
            }
        }
        return null;
    }

    pub fn size(self: *const ProtoPool) u32 {
        var total: u32 = 0;
        for (self.unsorted.items) |proto| {
            if (proto.parameters.len == 0) continue;
            total += 4 + @as(u32, @intCast(proto.parameters.len * 4));
        }
        return total;
    }
};

pub const ProtoIdItem = extern struct {
    shorty_idx: u32,
    return_type_idx: u32,
    parameters_off: u32,
};
