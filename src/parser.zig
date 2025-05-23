const std = @import("std");
const lexer = @import("lexer.zig");
const Lexer = lexer.Lexer;
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;
const Instructions = @import("instructions.zig");
const ir = @import("ir.zig").ir;

pub const Parser = struct {
    source: []const u8,
    tokens: []const Token,
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    index: usize = 0,

    pub fn init(arena: *std.heap.ArenaAllocator, source: []const u8, tokens: []const Token) Parser {
        return Parser{
            .source = source,
            .tokens = tokens,
            .arena = arena,
            .allocator = arena.allocator(),
        };
    }

    pub fn parseDexIR(self: *Parser) !ir.DexIR {
        const class = try self.parseClass();
        const classes = try self.allocator.dupe(ir.ClassIR, &[_]ir.ClassIR{class});
        return ir.DexIR{ .classes = classes };
    }

    fn parseClass(self: *Parser) !ir.ClassIR {
        _ = try self.expect(.CLASS_DIRECTIVE);
        _ = try self.expect(.ACCESS_MODIFIER);
        const class_name = try self.allocator.dupe(u8, self.slice(try self.expect(.TYPE_DESCRIPTOR)));

        _ = try self.expect(.SUPER_DIRECTIVE);
        const super_name = try self.allocator.dupe(u8, self.slice(try self.expect(.TYPE_DESCRIPTOR)));

        var methods = std.ArrayList(ir.MethodIR).init(self.allocator);
        while (self.match(.METHOD_DIRECTIVE)) {
            try methods.append(try self.parseMethod(class_name));
        }

        const methods_owned = try methods.toOwnedSlice();
        return ir.ClassIR{
            .name = class_name,
            .superclass = super_name,
            .access_flags = ir.AccessFlags{ .public = true },
            .methods = methods_owned,
        };
    }

    fn parseMethod(self: *Parser, classname: []const u8) !ir.MethodIR {
        _ = try self.expect(.METHOD_DIRECTIVE);

        var access_flags = ir.AccessFlags{};

        while (self.match(.ACCESS_MODIFIER)) {
            const tok = try self.expect(.ACCESS_MODIFIER);
            const text = self.slice(tok);

            if (std.mem.eql(u8, text, "public")) {
                access_flags.public = true;
            } else if (std.mem.eql(u8, text, "private")) {
                access_flags.private = true;
            } else if (std.mem.eql(u8, text, "protected")) {
                access_flags.protected = true;
            } else if (std.mem.eql(u8, text, "static")) {
                access_flags.static = true;
            } else if (std.mem.eql(u8, text, "final")) {
                access_flags.final = true;
            } else if (std.mem.eql(u8, text, "abstract")) {
                access_flags.abstract = true;
            } else if (std.mem.eql(u8, text, "synthetic")) {
                access_flags.synthetic = true;
            } else if (std.mem.eql(u8, text, "constructor")) {
                access_flags.constructor = true;
            } else {
                return error.UnknownAccessFlag;
            }
        }

        const name_tok = try self.expectOne(&.{ .METHOD_NAME, .IDENTIFIER });

        _ = try self.expect(.LPAREN);

        var param_types = std.ArrayList([]const u8).init(self.allocator);
        defer param_types.deinit();

        while (!self.match(.RPAREN)) {
            const param_tok = try self.expectOne(&.{ .TYPE_DESCRIPTOR, .IDENTIFIER });
            const param_type = self.slice(param_tok);
            try param_types.append(param_type);
        }

        _ = try self.expect(.RPAREN);

        const return_tok = try self.expectOne(&.{ .TYPE_DESCRIPTOR, .IDENTIFIER });
        const return_type = self.slice(return_tok);

        _ = try self.expect(.LOCALS_DIRECTIVE);
        const locals_tok = self.slice(try self.expect(.NUMBER_LITERAL));
        const locals = try std.fmt.parseInt(u16, locals_tok, 10);

        var code = std.ArrayList(ir.Instruction).init(self.allocator);
        defer code.deinit();

        while (!self.match(.END_METHOD_DIRECTIVE) and self.index < self.tokens.len) {
            try self.parseInstruction(&code);
        }

        _ = try self.expect(.END_METHOD_DIRECTIVE);

        const code_owned = try self.allocator.dupe(ir.Instruction, code.items);

        return ir.MethodIR{
            .name = self.slice(name_tok),
            .class = classname,
            .proto = ir.ProtoIR{
                .return_type = return_type,
                .parameters = try param_types.toOwnedSlice(),
            },
            .code = code_owned,
            .locals = locals,
            .access_flags = access_flags,
        };
    }

    fn makeInstruction(
        self: *Parser,
        opcode: Instructions.Opcode,
        registers: *std.ArrayList([]const u8),
        operand: ?ir.Operand,
    ) !ir.Instruction {
        _ = self;
        return ir.Instruction{
            .opcode = opcode,
            .registers = try registers.toOwnedSlice(),
            .operand = operand,
        };
    }

    fn parseInstruction(self: *Parser, code: *std.ArrayList(ir.Instruction)) !void {
        const tok = self.advance();
        const opcode = try self.opcodeFromString(self.slice(tok)) orelse return;
        var registers = std.ArrayList([]const u8).init(self.allocator);

        switch (tok.kind) {
            .INSTRUCTION_FORMAT10x => {
                try code.append(try self.makeInstruction(
                    opcode,
                    &registers,
                    null,
                ));
            },
            .INSTRUCTION_FORMAT35c => {
                _ = try self.expect(.LBRACE);
                while (true) {
                    const reg_tok = try self.expect(.REGISTER);
                    try registers.append(self.slice(reg_tok));

                    if (self.match(.COMMA)) {
                        _ = try self.expect(.COMMA);
                    } else if (self.match(.RBRACE)) {
                        _ = try self.expect(.RBRACE);
                        break;
                    } else {
                        return error.UnexpectedToken;
                    }
                }
                _ = try self.expect(.COMMA);

                const class = try self.expect(.TYPE_DESCRIPTOR);
                _ = try self.expect(.ARROW);
                const method = try self.expectOne(&.{ .METHOD_NAME, .IDENTIFIER });
                _ = try self.expect(.LPAREN);
                var parameters = std.ArrayList([]const u8).init(self.allocator);
                while (!self.match(.RPAREN)) {
                    const parameter = try self.expect(.TYPE_DESCRIPTOR);
                    try parameters.append(self.slice(parameter));
                }
                _ = try self.expect(.RPAREN);
                const return_type = try self.expect(.IDENTIFIER);
                const operand: ir.Operand = .{ .reference = .{ .method = .{
                    .class = self.slice(class),
                    .name = self.slice(method),
                    .proto = .{
                        .parameters = try parameters.toOwnedSlice(),
                        .return_type = self.slice(return_type),
                    },
                } } };
                try code.append(
                    try self.makeInstruction(
                        opcode,
                        &registers,
                        operand,
                    ),
                );
            },
            .INSTRUCTION_FORMAT21c => {
                const register = try self.allocator.dupe(
                    u8,
                    self.slice(try self.expect(.REGISTER)),
                );
                try registers.append(register);
                _ = try self.expect(.COMMA);
                const next_tok = try self.expectOne(
                    &.{ .STRING_LITERAL, .TYPE_DESCRIPTOR },
                );

                const operand = switch (next_tok.kind) {
                    .STRING_LITERAL => ir.Operand{
                        .literal = .{
                            .string = try self.allocator.dupe(u8, self.slice(next_tok)),
                        },
                    },
                    .TYPE_DESCRIPTOR => ir.Operand{
                        .reference = .{
                            .type = try self.allocator.dupe(u8, self.slice(next_tok)),
                        },
                    },
                    else => return error.UnsupportedOperand,
                };

                try code.append(try self.makeInstruction(
                    opcode,
                    &registers,
                    operand,
                ));
            },
            else => return error.UnsupportedInstructionKind,
        }
    }

    fn opcodeFromString(self: *Parser, name: []const u8) !?Instructions.Opcode {
        _ = self;
        return Instructions.opcode_map.get(name) orelse {
            std.debug.print("error.UnknownOpcode: {s}\n", .{name});
            return error.UnknownOpcode;
        };
    }

    fn expect(self: *Parser, kind: TokenKind) !Token {
        if (self.index >= self.tokens.len) return error.UnexpectedEOF;
        const tok = self.tokens[self.index];
        if (tok.kind != kind) {
            std.debug.print("error.UnexpectedToken: {s}, expected={s}\n", .{
                @tagName(tok.kind),
                @tagName(kind),
            });
            return error.UnexpectedToken;
        }
        self.index += 1;
        return tok;
    }

    fn expectOne(self: *Parser, kinds: []const TokenKind) !Token {
        if (self.index >= self.tokens.len) return error.UnexpectedEOF;
        const tok = self.tokens[self.index];
        for (kinds) |k| {
            if (tok.kind == k) {
                self.index += 1;
                return tok;
            }
        }
        return error.UnexpectedToken;
    }

    fn match(self: *Parser, kind: TokenKind) bool {
        return self.index < self.tokens.len and self.tokens[self.index].kind == kind;
    }

    fn advance(self: *Parser) Token {
        const tok = self.tokens[self.index];
        self.index += 1;
        return tok;
    }

    fn slice(self: *Parser, tok: Token) []const u8 {
        return self.source[tok.start..tok.end];
    }
};
