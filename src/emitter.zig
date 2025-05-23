const std = @import("std");
const DexIR = @import("ir.zig").ir.DexIR;
const ir = @import("ir.zig").ir;
const AccessFlags = @import("ir.zig").ir.AccessFlags;
const StringPool = @import("pools/StringPool.zig").StringPool;
const TypePool = @import("pools/TypePool.zig").TypePool;
const ProtoPool = @import("pools/ProtoPool.zig").ProtoPool;
const MethodPool = @import("pools/MethodPool.zig").MethodPool;
const ClassDefEmitter = @import("pools/ClassDefItemEmitter.zig").ClassDefEmitter;
const Instruction = @import("instructions.zig").Instruction;
const MapList = @import("pools/MapList.zig").MapList;

pub const EndianConstant = enum(u32) {
    endian_constant = 0x12345678,
    reverse_endian_constant = 0x78563412,
};
pub const HeaderItem = packed struct {
    magic: @Vector(4, u8) = .{ 'd', 'e', 'x', '\n' },
    version: @Vector(4, u8) = .{ '0', '3', '5', '\x00' },
    checksum: u32 = 0,
    signature: @Vector(20, u8) = .{
        0, 0, 0, 0, 0,
        0, 0, 0, 0, 0,
        0, 0, 0, 0, 0,
        0, 0, 0, 0, 0,
    },
    file_size: u32 = 0,
    header_size: u32 = 0x70,
    endian_tag: EndianConstant = .endian_constant,
    link_size: u32 = 0,
    link_off: u32 = 0,
    map_off: u32 = 0,
    string_ids_size: u32 = 0,
    string_ids_off: u32 = 0,
    type_ids_size: u32 = 0,
    type_ids_off: u32 = 0,
    proto_ids_size: u32 = 0,
    proto_ids_off: u32 = 0,
    field_ids_size: u32 = 0x0,
    field_ids_off: u32 = 0x0,
    method_ids_size: u32 = 0,
    method_ids_off: u32 = 0,
    class_defs_size: u32 = 0,
    class_defs_off: u32 = 0,
    data_size: u32 = 0,
    data_off: u32 = 0,
};

pub const SectionEnum = enum {
    Header,
    StringIds,
    TypeIds,
    ProtoIds,
    MethodIds,
    ClassDefs,
    StringData,
    TypeList,
    AnnotationSet,
    CodeItem,
    ClassDataItem,
    MapList,
};

pub const Section = struct {
    name: SectionEnum,
    offset: u32,
    size: u32,
};

const SectionLayout = struct {
    items: []Section,

    pub fn init(
        allocator: std.mem.Allocator,
        string_pool: StringPool,
        type_pool: TypePool,
        proto_pool: ProtoPool,
        method_pool: MethodPool,
        class_def_emitter: ClassDefEmitter,
        direct_methods: *std.ArrayList(*ir.MethodIR),
        virtual_methods: *std.ArrayList(*ir.MethodIR),
    ) !SectionLayout {
        var items = try allocator.alloc(Section, 11);

        var offset: u32 = 0x70;

        const string_ids_size = string_pool.list.items.len * 4;
        items[0] = .{
            .name = .StringIds,
            .offset = offset,
            .size = @intCast(string_ids_size),
        };
        offset += items[0].size;

        offset = alignTo(offset, 4);
        const type_ids_size = type_pool.list.items.len * 4;
        items[1] = .{
            .name = .TypeIds,
            .offset = offset,
            .size = @intCast(type_ids_size),
        };
        offset += items[1].size;

        offset = alignTo(offset, 4);
        const proto_ids_size = proto_pool.list.items.len * 12;
        items[2] = .{
            .name = .ProtoIds,
            .offset = offset,
            .size = @intCast(proto_ids_size),
        };
        offset += items[2].size;

        offset = alignTo(offset, 4);
        const method_ids_size = method_pool.sorted.items.len * 8;
        items[3] = .{
            .name = .MethodIds,
            .offset = offset,
            .size = @intCast(method_ids_size),
        };
        offset += items[3].size;

        offset = alignTo(offset, 4);
        const class_defs_size = class_def_emitter.list.items.len * 32;
        items[4] = .{
            .name = .ClassDefs,
            .offset = offset,
            .size = @intCast(class_defs_size),
        };
        offset += items[4].size;

        offset = alignTo(offset, 1);
        const string_data_size = string_pool.size();
        items[5] = .{
            .name = .StringData,
            .offset = offset,
            .size = string_data_size,
        };
        offset += items[5].size;

        offset = alignTo(offset, 4);
        const type_list_size = proto_pool.size();
        items[6] = .{
            .name = .TypeList,
            .offset = offset,
            .size = type_list_size,
        };
        offset += items[6].size;

        offset = alignTo(offset, 4);
        items[7] = .{
            .name = .AnnotationSet,
            .offset = offset,
            .size = 8,
        };
        offset += items[7].size;

        offset = alignTo(offset, 4);
        var code_item_size: u32 = 0;
        for (direct_methods.items) |method| {
            code_item_size += method.codeItemSize();
        }
        for (virtual_methods.items) |method| {
            code_item_size += method.codeItemSize();
        }
        items[8] = .{
            .name = .CodeItem,
            .offset = offset,
            .size = code_item_size,
        };
        offset += items[8].size;

        offset = alignTo(offset, 1);
        const class_data_item_size = try sizeClassDataItem(
            direct_methods,
            virtual_methods,
            method_pool,
        );
        items[9] = .{
            .name = .ClassDataItem,
            .offset = offset,
            .size = class_data_item_size,
        };
        offset += items[9].size;

        offset = alignTo(offset, 4);
        const map_list_size: u32 = @intCast(4 + items.len * 12);
        items[10] = .{
            .name = .MapList,
            .offset = offset,
            .size = map_list_size,
        };
        return .{
            .items = items,
        };
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

    fn sizeClassDataItem(
        direct_methods: *std.ArrayList(*ir.MethodIR),
        virtual_methods: *std.ArrayList(*ir.MethodIR),
        method_pool: MethodPool,
    ) !u32 {
        var size: u32 = 0;

        size += uleb128Size(0); // static_fields_size
        size += uleb128Size(0); // instance_fields_size
        size += uleb128Size(@intCast(direct_methods.items.len));
        size += uleb128Size(@intCast(virtual_methods.items.len));

        var last_idx: u32 = 0;
        for (direct_methods.items) |method| {
            const method_idx = method_pool.indexOf(.{
                .class = method.class,
                .name = method.name,
                .proto = method.proto,
            }) orelse return error.MethodNotFound;

            const diff = method_idx - last_idx;
            last_idx = method_idx;

            size += uleb128Size(diff);
            size += uleb128Size(method.access_flags.toInt());
            size += uleb128Size(method.code_offset.?);
        }

        last_idx = 0;
        for (virtual_methods.items) |method| {
            const method_idx = method_pool.indexOf(.{
                .class = method.class,
                .name = method.name,
                .proto = method.proto,
            }) orelse return error.MethodNotFound;

            const diff = method_idx - last_idx;
            last_idx = method_idx;

            size += uleb128Size(diff);
            size += uleb128Size(method.access_flags.toInt());
            size += uleb128Size(method.code_offset.?);
        }

        return size;
    }

    pub fn off(self: *const SectionLayout, name: SectionEnum) u32 {
        for (self.items) |section| {
            if (section.name == name) {
                return section.offset;
            }
        }
        @panic("Unknown section.");
    }
};

pub const DexEmitter = struct {
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    header: HeaderItem,
    string_pool: StringPool,
    type_pool: TypePool,
    proto_pool: ProtoPool,
    method_pool: MethodPool,
    class_def_emitter: ClassDefEmitter,
    direct_methods: std.ArrayList(*ir.MethodIR),
    virtual_methods: std.ArrayList(*ir.MethodIR),
    section_layout: ?SectionLayout,

    pub fn init(arena: *std.heap.ArenaAllocator) !DexEmitter {
        const allocator = arena.allocator();
        return DexEmitter{
            .arena = arena,
            .allocator = allocator,
            .string_pool = try StringPool.init(allocator),
            .type_pool = try TypePool.init(allocator),
            .proto_pool = try ProtoPool.init(allocator),
            .method_pool = try MethodPool.init(allocator),
            .class_def_emitter = try ClassDefEmitter.init(allocator),
            .direct_methods = std.ArrayList(*ir.MethodIR).init(allocator),
            .virtual_methods = std.ArrayList(*ir.MethodIR).init(allocator),
            .section_layout = null,
            .header = .{},
        };
    }

    pub fn prepare(self: *DexEmitter, dex_ir: *const DexIR) !void {
        try self.string_pool.fromDexIR(dex_ir);
        try self.string_pool.sort();
        try self.proto_pool.fromDexIR(&self.string_pool, dex_ir);
        try self.proto_pool.sort();
        try self.type_pool.fromDexIR(&self.string_pool, dex_ir);
        try self.type_pool.sort();
        try self.method_pool.fromDexIR(&self.string_pool, &self.type_pool, &self.proto_pool, dex_ir);
        try self.method_pool.sort();
        try self.class_def_emitter.fromDexIR(
            &self.string_pool,
            &self.type_pool,
            dex_ir,
        );

        for (dex_ir.classes) |*class| {
            for (class.methods) |*method| {
                if (method.isDirect()) {
                    try self.direct_methods.append(method);
                } else {
                    try self.virtual_methods.append(method);
                }
            }
        }
        try self.assignCodeOffsets(0);
    }

    fn writeAnnotationSet(self: *DexEmitter, writer: anytype) !void {
        _ = self;
        try writer.writeByteNTimes(0x00, 8);
    }

    fn writeClassDataItem(self: *DexEmitter, writer: anytype) !u32 {
        try std.leb.writeUleb128(writer, 0); // static_fields_size
        try std.leb.writeUleb128(writer, 0); // instance_fields_size

        try std.leb.writeUleb128(writer, self.direct_methods.items.len);
        try std.leb.writeUleb128(writer, self.virtual_methods.items.len);

        var last_method_idx: u32 = 0;
        for (self.direct_methods.items) |method| {
            const method_idx = self.method_pool.indexOf(.{
                .class = method.class,
                .name = method.name,
                .proto = method.proto,
            }) orelse return error.MethodNotFound;
            const diff = method_idx - last_method_idx;
            last_method_idx = method_idx;

            try std.leb.writeUleb128(writer, diff);
            try std.leb.writeUleb128(writer, @as(u32, @bitCast(method.access_flags)));
            try std.leb.writeUleb128(writer, method.code_offset.?);
        }

        last_method_idx = 0;
        for (self.virtual_methods.items) |method| {
            const method_idx = self.method_pool.indexOf(.{
                .class = method.class,
                .name = method.name,
                .proto = method.proto,
            }) orelse return error.MethodNotFound;
            const diff = method_idx - last_method_idx;
            last_method_idx = method_idx;

            try std.leb.writeUleb128(writer, diff);
            try std.leb.writeUleb128(writer, @as(u32, @bitCast(method.access_flags)));
            try std.leb.writeUleb128(writer, method.code_offset.?);
        }

        return 1;
    }

    fn assignCodeOffsets(self: *DexEmitter, start_offset: u32) !void {
        var offset = alignTo(start_offset, 4);

        const all_methods = [_][]const *ir.MethodIR{
            self.direct_methods.items,
            self.virtual_methods.items,
        };

        for (all_methods) |method_list| {
            for (method_list) |method| {
                method.code_offset = offset;

                var body_size: u32 = 0;
                for (method.code) |instr| {
                    body_size += instr.wordSize() * 2;
                }

                offset += @sizeOf(ir.CodeItemHeader) + body_size;
            }
        }
    }

    fn writeCodeItems(self: *DexEmitter, writer: anytype) !void {
        const all_methods = [_][]const *ir.MethodIR{
            self.direct_methods.items,
            self.virtual_methods.items,
        };

        for (all_methods) |method_list| {
            for (method_list) |method| {
                const header = method.computeCodeHeader();
                try writer.writeStructEndian(header, .little);

                const reg_map = try method.buildRegisterMap(header, self.allocator);

                for (method.code) |*instr| {
                    var lowered = try instr.lower(&reg_map);

                    switch (instr.opcode) {
                        .invoke_direct, .invoke_super, .invoke_virtual => {
                            const ref = instr.operand.?.reference.method;
                            const method_idx = self.method_pool.indexOf(.{
                                .class = ref.class,
                                .name = ref.name,
                                .proto = ref.proto,
                            }) orelse return error.MethodNotFound;

                            switch (lowered) {
                                .invoke_direct => |*v| v.method_idx = method_idx,
                                .invoke_super => |*v| v.method_idx = method_idx,
                                .invoke_virtual => |*v| v.method_idx = method_idx,
                                else => return error.InvalidLoweredForm,
                            }
                        },

                        .const_string => {
                            const s = instr.operand.?.literal.string;
                            const string_idx = self.string_pool.indexOf(s) orelse return error.StringNotFound;
                            switch (lowered) {
                                .const_string => |*v| v.idx = string_idx,
                                else => return error.InvalidLoweredForm,
                            }
                        },

                        .new_instance => {
                            const t = instr.operand.?.reference.type;
                            const type_idx = self.type_pool.indexOf(t) orelse return error.TypeNotFound;
                            switch (lowered) {
                                .new_instance => |*v| v.idx = type_idx,
                                else => return error.InvalidLoweredForm,
                            }
                        },

                        else => {},
                    }

                    try lowered.emit(writer);
                }
            }
        }
    }

    fn pos(stream: anytype) !u32 {
        return @intCast(try stream.getPos());
    }

    pub fn write(self: *DexEmitter, stream: anytype) !usize {
        const writer = stream.writer();
        const section_layout = try SectionLayout.init(
            self.allocator,
            self.string_pool,
            self.type_pool,
            self.proto_pool,
            self.method_pool,
            self.class_def_emitter,
            &self.direct_methods,
            &self.virtual_methods,
        );
        self.section_layout = section_layout;

        self.header = .{};
        try writer.writeStructEndian(self.header, .little);

        try stream.seekTo(section_layout.off(.StringData));
        self.header.data_off = try pos(stream);
        const string_data_offsets = try self.string_pool.emitStringData(stream);

        try stream.seekTo(section_layout.off(.StringIds));
        self.header.string_ids_off = try pos(stream);
        try self.string_pool.emitStringId(
            writer,
            string_data_offsets,
            section_layout.off(.StringData),
        );
        self.header.string_ids_size = @intCast(self.string_pool.list.items.len);

        try stream.seekTo(section_layout.off(.TypeIds));
        self.header.type_ids_off = try pos(stream);
        try self.type_pool.emitTypeIds(writer);
        self.header.type_ids_size = @intCast(self.type_pool.list.items.len);

        try stream.seekTo(section_layout.off(.TypeList));
        const proto_offsets = try self.proto_pool.writeTypeList(
            &self.type_pool,
            writer,
        );

        try stream.seekTo(section_layout.off(.ProtoIds));
        self.header.proto_ids_off = try pos(stream);
        try self.proto_pool.emitProtoIds(
            &self.string_pool,
            &self.type_pool,
            proto_offsets,
            stream,
        );
        self.header.proto_ids_size = @intCast(self.proto_pool.unsorted.items.len);

        try stream.seekTo(section_layout.off(.AnnotationSet));
        try self.writeAnnotationSet(writer);

        try stream.seekTo(section_layout.off(.MethodIds));
        self.header.method_ids_off = try pos(stream);
        try self.method_pool.emitMethodIds(
            &self.string_pool,
            &self.type_pool,
            &self.proto_pool,
            stream,
        );
        self.header.method_ids_size = @intCast(self.method_pool.sorted.items.len);

        try stream.seekTo(section_layout.off(.ClassDefs));
        self.header.class_defs_off = try pos(stream);
        var class_defs_off: u32 = 0;
        self.class_def_emitter.setClassDataOff(section_layout.off(.ClassDataItem));
        try self.class_def_emitter.emit(&class_defs_off, writer);
        self.header.class_defs_size = 1;

        try stream.seekTo(section_layout.off(.ClassDataItem));
        try self.assignCodeOffsets(section_layout.off(.CodeItem));
        _ = try self.writeClassDataItem(writer);

        try stream.seekTo(section_layout.off(.CodeItem));
        try self.writeCodeItems(writer);

        try stream.seekTo(section_layout.off(.MapList));
        try MapList.emit(
            writer,
            section_layout.items,
            &self.string_pool,
            @intCast(self.direct_methods.items.len + self.virtual_methods.items.len),
        );
        self.header.file_size = @intCast(try stream.getPos());
        self.header.data_size = self.header.file_size - self.header.data_off;
        {
            self.header.map_off = section_layout.off(.MapList);
        }
        try stream.seekTo(0);
        try writer.writeStructEndian(self.header, .little);
        {
            const sigSlice = stream.buffer[0x20..self.header.file_size];
            var sigHash: [20]u8 = undefined;
            std.crypto.hash.Sha1.hash(sigSlice, &sigHash, .{});
            self.header.signature = sigHash;
        }
        try stream.seekTo(0);
        try writer.writeStructEndian(self.header, .little);
        {
            const chkSlice = stream.buffer[0x0C..self.header.file_size];
            self.header.checksum = std.hash.Adler32.hash(chkSlice);
        }
        try stream.seekTo(0);
        try writer.writeStructEndian(self.header, .little);
        return try stream.getPos();
    }
};

const Token = @import("lexer.zig").Token;
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;

fn alignTo(value: u32, alignment: u32) u32 {
    return (value + alignment - 1) & ~(alignment - 1);
}

fn lexAndParse(arena: *std.heap.ArenaAllocator, src: []const u8) !DexIR {
    const allocator = arena.allocator();

    var lexer = Lexer.init(src);
    var tokens = std.ArrayList(Token).init(allocator);
    defer tokens.deinit();

    while (true) {
        const tok = lexer.next();
        if (tok.kind == .EOF) break;
        try tokens.append(tok);
    }

    var parser = Parser.init(arena, src, tokens.items);
    return try parser.parseDexIR();
}

fn createEmitter(arena: *std.heap.ArenaAllocator, dex_ir: *const DexIR) !DexEmitter {
    var emitter = try DexEmitter.init(arena);
    try emitter.prepare(dex_ir);
    return emitter;
}

fn writeDex(emitter: *DexEmitter, stream: anytype) !usize {
    return try emitter.write(stream);
}

fn runDexTest(
    arena: *std.heap.ArenaAllocator,
    dex_ir: *const DexIR,
    expected: []const u8,
    expected_sections: []const Section,
) !void {
    const allocator = arena.allocator();
    const buf = try allocator.alloc(u8, 8192);
    @memset(buf, 0xAA);

    var fbs = std.io.fixedBufferStream(buf);
    var emitter = try createEmitter(arena, dex_ir);
    _ = try writeDex(&emitter, &fbs);

    for (expected_sections) |s| {
        try std.testing.expectEqualSlices(
            u8,
            expected[s.offset .. s.offset + s.size],
            buf[s.offset .. s.offset + s.size],
        );
    }

    for (expected_sections, 0..) |exp, i| {
        const actual = emitter.section_layout.?.items[i];
        try std.testing.expectEqual(exp.name, actual.name);
        try std.testing.expectEqual(exp.offset, actual.offset);
    }

    try std.testing.expectEqualSlices(u8, expected, buf[0..expected.len]);
}

test "compile HelloActivity.smali into .dex bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = @embedFile("tests/HelloActivity.smali");
    const expected = @embedFile("tests/classes.dex");

    const dex_ir = try lexAndParse(&arena, src);

    const expected_sections = [_]Section{
        .{ .name = .StringIds, .offset = 0x070, .size = 0xA6 - 0x70 },
        .{ .name = .TypeIds, .offset = 0x0A8, .size = 0xC7 - 0xA8 },
        .{ .name = .ProtoIds, .offset = 0x0C8, .size = 0x104 - 0xC8 },
        .{ .name = .MethodIds, .offset = 0x104, .size = 0x13B - 0x104 },
        .{ .name = .ClassDefs, .offset = 0x13C, .size = 0x15B - 0x13C },
        .{ .name = .StringData, .offset = 0x15C, .size = 0x256 - 0x15C },
        .{ .name = .TypeList, .offset = 0x258, .size = 0x278 - 0x258 },
        .{ .name = .AnnotationSet, .offset = 0x278, .size = 0x280 - 0x278 },
        .{ .name = .CodeItem, .offset = 0x280, .size = 0x2CA - 0x280 },
        .{ .name = .ClassDataItem, .offset = 0x2CA, .size = 0x2D8 - 0x2CA },
        .{ .name = .MapList, .offset = 0x2D8, .size = 0x36B - 0x2D8 },
    };

    try runDexTest(&arena, &dex_ir, expected, &expected_sections);
}
