const std = @import("std");
const Hasher = std.hash.Wyhash;
const Instructions = @import("instructions.zig");

pub const ir = struct {
    pub const DexIR = struct {
        classes: []ClassIR,

        pub fn format(
            self: DexIR,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

            for (self.classes) |cls| {
                try writer.print("Class: {s}\n", .{cls.name});
                for (cls.methods) |m| {
                    try writer.print("\tMethod: {s}\n", .{m.name});
                    try writer.print("\t\tLocals: {d}\n", .{m.locals});
                    for (m.code) |instr| {
                        try writer.print("\t\tInstr: {s}\n", .{@tagName(instr.opcode)});

                        if (instr.registers.len > 0) {
                            try writer.print("\t\t\tRegisters: ", .{});
                            for (instr.registers, 0..) |reg, i| {
                                if (i != 0) try writer.print(", ", .{});
                                try writer.print("{s}", .{reg});
                            }
                            try writer.print("\n", .{});
                        }

                        if (instr.operand) |operand| {
                            switch (operand) {
                                .literal => |lit| switch (lit) {
                                    .string => |value| try writer.print(
                                        "\t\t\tLiteral string: \"{s}\"\n",
                                        .{value},
                                    ),
                                    else => {},
                                },
                                .reference => |ref| switch (ref) {
                                    .type => |value| try writer.print(
                                        "\t\t\tType: {s}\n",
                                        .{value},
                                    ),
                                    .string => |value| try writer.print(
                                        "\t\t\tRef string: {s}\n",
                                        .{value},
                                    ),
                                    .method => |value| {
                                        try writer.print("\t\t\tMethod:\n", .{});
                                        try writer.print("\t\t\t\tClass: {s}\n", .{value.class});
                                        try writer.print("\t\t\t\tName: {s}\n", .{value.name});

                                        try writer.print("\t\t\t\tParameters:", .{});
                                        if (value.proto.parameters.len == 0) {
                                            try writer.print(" (none)", .{});
                                        } else {
                                            for (value.proto.parameters) |param| {
                                                try writer.print(" {s}", .{param});
                                            }
                                        }
                                        try writer.print("\n", .{});

                                        try writer.print("\t\t\t\tReturn: {s}\n", .{value.proto.return_type});
                                    },
                                },
                            }
                        }
                    }
                }
            }
        }
    };

    pub const ClassIR = struct {
        name: []const u8,
        superclass: []const u8,
        access_flags: AccessFlags,
        methods: []MethodIR,
    };

    pub const ProtoIR = struct {
        shorty: []const u8 = &.{},
        return_type: []const u8,
        parameters: []const []const u8,

        pub fn eql(a: *const ProtoIR, b: ProtoIR) bool {
            return std.mem.eql(u8, a.shorty, b.shorty) and
                std.mem.eql(u8, a.return_type, b.return_type) and
                a.parameters.len == b.parameters.len and
                for (a.parameters, 0..) |p, i| {
                    if (!std.mem.eql(u8, p, b.parameters[i])) break false;
                } else true;
        }
    };

    pub const MethodIR = struct {
        name: []const u8,
        class: []const u8,
        proto: ProtoIR,
        code: []Instruction,
        locals: u16,
        access_flags: AccessFlags,
        code_offset: ?u32 = null,

        pub fn isDirect(self: *@This()) bool {
            return std.mem.eql(
                u8,
                self.name,
                "<init>",
            ) or self.access_flags.private or self.access_flags.private;
        }

        pub fn computeCodeHeader(self: *const MethodIR) ir.CodeItemHeader {
            var max_v: u16 = 0;
            var max_p: u16 = 0;
            var max_outs: u16 = 0;

            for (self.code) |instr| {
                for (instr.registers) |reg| {
                    if (reg.len < 2) continue;

                    const prefix = reg[0];
                    const idx = std.fmt.parseInt(u16, reg[1..], 10) catch continue;

                    if (prefix == 'v' or prefix == 'p') {
                        if (idx + 1 > max_v) max_v = idx + 1;
                        if (prefix == 'p' and idx + 1 > max_p) max_p = idx + 1;
                    }
                }

                switch (instr.opcode) {
                    .invoke_direct, .invoke_virtual, .invoke_super => {
                        const arg_count: u16 = @intCast(instr.registers.len);
                        if (arg_count > max_outs) max_outs = arg_count;
                    },
                    else => {},
                }
            }

            var total_words: u32 = 0;
            for (self.code) |instr| {
                total_words += instr.wordSize();
            }

            return ir.CodeItemHeader{
                .registers_size = self.locals + max_p,
                .ins_size = max_p,
                .outs_size = max_outs,
                .tries_size = 0,
                .debug_info_off = 0,
                .insns_size = total_words,
            };
        }

        pub fn buildRegisterMap(
            self: *const MethodIR,
            header: ir.CodeItemHeader,
            alloc: std.mem.Allocator,
        ) !std.StringHashMap(u8) {
            var map = std.StringHashMap(u8).init(alloc);

            const total = header.registers_size;
            const ins = header.ins_size;
            const locals = self.locals;

            for (0..locals) |i| {
                const name = try std.fmt.allocPrint(alloc, "v{}", .{i});
                try map.put(name, @intCast(i));
            }

            for (0..ins) |i| {
                const name = try std.fmt.allocPrint(alloc, "p{}", .{i});
                const id = total - ins + i;
                try map.put(name, @intCast(id));
            }

            return map;
        }
        pub fn codeItemSize(self: *const MethodIR) u32 {
            var total: u32 = 0;
            var body_size: u32 = 0;
            for (self.code) |instr| {
                body_size += instr.wordSize() * 2;
            }
            total += 16 + body_size;
            return total;
        }
    };

    pub const Instruction = struct {
        opcode: Instructions.Opcode,
        registers: []const []const u8,
        operand: ?Operand,

        pub fn wordSize(self: Instruction) u32 {
            return switch (self.opcode) {
                .return_void => 1,
                .invoke_direct, .invoke_virtual, .invoke_super => 3,
                .const_string => 2,
                .new_instance => 2,
            };
        }

        pub fn lower(
            self: Instruction,
            reg_map: *const std.StringHashMap(u8),
        ) !Instructions.Instruction {
            switch (self.opcode) {
                .return_void => return Instructions.Instruction{
                    .return_void = .{},
                },

                .const_string, .new_instance => {
                    const idx = 0;
                    const reg_name = self.registers[0];
                    const reg = reg_map.get(reg_name) orelse return error.UnknownRegister;

                    return switch (self.opcode) {
                        .const_string => Instructions.Instruction{
                            .const_string = .{ .reg = reg, .idx = idx },
                        },
                        .new_instance => Instructions.Instruction{
                            .new_instance = .{ .reg = reg, .idx = idx },
                        },
                        else => unreachable,
                    };
                },

                .invoke_direct, .invoke_virtual, .invoke_super => {
                    const method_idx = 0;
                    const count: u8 = @intCast(self.registers.len);
                    if (count > 5) return error.TooManyRegisters;

                    var regs: [5]u8 = .{0} ** 5;
                    for (self.registers, 0..) |reg_name, i| {
                        regs[i] = reg_map.get(reg_name) orelse return error.UnknownRegister;
                    }

                    const f35c = Instructions.Format35c{
                        .method_idx = method_idx,
                        .reg_count = count,
                        .reg_c = regs[0],
                        .reg_d = regs[1],
                        .reg_e = regs[2],
                        .reg_f = regs[3],
                        .reg_g = regs[4],
                    };

                    return switch (self.opcode) {
                        .invoke_direct => Instructions.Instruction{ .invoke_direct = f35c },
                        .invoke_virtual => Instructions.Instruction{ .invoke_virtual = f35c },
                        .invoke_super => Instructions.Instruction{ .invoke_super = f35c },
                        else => unreachable,
                    };
                },
            }
        }
    };

    pub const Operand = union(enum) {
        reference: Reference,
        literal: Literal,
    };

    pub const Literal = union(enum) {
        string: []const u8,
        int: i32,
    };

    pub const MethodReference = struct {
        class: []const u8,
        name: []const u8,
        proto: ProtoIR,
    };

    pub const Reference = union(enum) {
        method: MethodReference,
        // field: FieldReference,
        string: []const u8,
        type: []const u8,
        // proto: ProtoReference,
    };

    pub const NO_INDEX: u32 = 0xffffffff;

    pub const AccessFlags = packed struct(u32) {
        public: bool = false,
        private: bool = false,
        protected: bool = false,
        static: bool = false,
        final: bool = false,
        _pad0: u6 = 0,
        interface: bool = false,
        abstract: bool = false,
        _pad1: u1 = 0,
        synthetic: bool = false,
        annotation: bool = false,
        constructor: bool = false,
        @"enum": bool = false,
        _pad2: u14 = 0,

        pub fn toInt(self: @This()) u32 {
            return @bitCast(self);
        }
    };

    pub const CodeItemHeader = packed struct {
        registers_size: u16,
        ins_size: u16,
        outs_size: u16,
        tries_size: u16 = 0,
        debug_info_off: u32 = 0,
        insns_size: u32,
    };

    pub const MapItemType = enum(u16) {
        TYPE_HEADER_ITEM = 0x0000,
        TYPE_STRING_ID_ITEM = 0x0001,
        TYPE_TYPE_ID_ITEM = 0x0002,
        TYPE_PROTO_ID_ITEM = 0x0003,
        TYPE_FIELD_ID_ITEM = 0x0004,
        TYPE_METHOD_ID_ITEM = 0x0005,
        TYPE_CLASS_DEF_ITEM = 0x0006,
        TYPE_CALL_SITE_ID_ITEM = 0x0007,
        TYPE_METHOD_HANDLE_ITEM = 0x0008,
        TYPE_MAP_LIST = 0x1000,
        TYPE_TYPE_LIST = 0x1001,
        TYPE_ANNOTATION_SET_REF_LIST = 0x1002,
        TYPE_ANNOTATION_SET_ITEM = 0x1003,
        TYPE_CLASS_DATA_ITEM = 0x2000,
        TYPE_CODE_ITEM = 0x2001,
        TYPE_STRING_DATA_ITEM = 0x2002,
        TYPE_DEBUG_INFO_ITEM = 0x2003,
        TYPE_ANNOTATION_ITEM = 0x2004,
        TYPE_ENCODED_ARRAY_ITEM = 0x2005,
        TYPE_ANNOTATIONS_DIRECTORY_ITEM = 0x2006,
        TYPE_HIDDENAPI_CLASS_DATA_ITEM = 0xF000,
    };
};
