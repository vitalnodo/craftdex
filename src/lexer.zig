const std = @import("std");

pub const TokenKind = enum {
    CLASS_DIRECTIVE,
    SUPER_DIRECTIVE,
    METHOD_DIRECTIVE,
    END_METHOD_DIRECTIVE,
    LOCALS_DIRECTIVE,

    INSTRUCTION_FORMAT10x,
    INSTRUCTION_FORMAT21c,
    INSTRUCTION_FORMAT35c,

    STRING_LITERAL,
    NUMBER_LITERAL,

    TYPE_DESCRIPTOR,
    REGISTER,
    IDENTIFIER,
    ACCESS_MODIFIER,
    SHORTY_TYPE,
    METHOD_NAME,

    ARROW,
    COMMA,
    LBRACE,
    RBRACE,
    LPAREN,
    RPAREN,

    COMMENT,
    EOF,
    UNKNOWN,
};

const instructions = [_]struct { text: []const u8, kind: TokenKind }{
    .{ .text = "invoke-direct", .kind = .INSTRUCTION_FORMAT35c },
    .{ .text = "invoke-super", .kind = .INSTRUCTION_FORMAT35c },
    .{ .text = "invoke-virtual", .kind = .INSTRUCTION_FORMAT35c },
    .{ .text = "new-instance", .kind = .INSTRUCTION_FORMAT21c },
    .{ .text = "const-string", .kind = .INSTRUCTION_FORMAT21c },
    .{ .text = "return-void", .kind = .INSTRUCTION_FORMAT10x },
};

const directives = [_]struct { text: []const u8, kind: TokenKind }{
    .{ .text = ".class", .kind = .CLASS_DIRECTIVE },
    .{ .text = ".super", .kind = .SUPER_DIRECTIVE },
    .{ .text = ".method", .kind = .METHOD_DIRECTIVE },
    .{ .text = ".end method", .kind = .END_METHOD_DIRECTIVE },
    .{ .text = ".locals", .kind = .LOCALS_DIRECTIVE },
};

const symbols = [_]struct { sym: u8, kind: TokenKind }{
    .{ .sym = '(', .kind = .LPAREN },
    .{ .sym = ')', .kind = .RPAREN },
    .{ .sym = '{', .kind = .LBRACE },
    .{ .sym = '}', .kind = .RBRACE },
    .{ .sym = ',', .kind = .COMMA },
};

const access_mods = [_][]const u8{
    "public",
    "private",
    "protected",
    "static",
    "final",
    "synthetic",
    "constructor",
};

const shorty_types = "VIZJBCDFS";

pub const Token = struct {
    kind: TokenKind,
    start: usize,
    end: usize,
};

pub const Lexer = struct {
    input: []const u8,
    index: usize = 0,

    pub fn init(input: []const u8) Lexer {
        return Lexer{ .input = input };
    }

    pub fn next(self: *Lexer) Token {
        while (self.index < self.input.len) {
            const slice = self.input[self.index..];

            if (slice[0] == ' ' or slice[0] == '\n' or slice[0] == '\r' or slice[0] == '\t') {
                self.index += 1;
                continue;
            }

            if (slice[0] == '#') {
                const start = self.index;
                while (self.index < self.input.len and self.input[self.index] != '\n') {
                    self.index += 1;
                }
                return Token{
                    .kind = TokenKind.COMMENT,
                    .start = start,
                    .end = self.index,
                };
            }

            for (directives) |entry| {
                if (std.mem.startsWith(u8, slice, entry.text)) {
                    const tok = Token{
                        .kind = entry.kind,
                        .start = self.index,
                        .end = self.index + entry.text.len,
                    };
                    self.index += entry.text.len;
                    return tok;
                }
            }
            for (instructions) |entry| {
                if (std.mem.startsWith(u8, slice, entry.text)) {
                    const tok = Token{
                        .kind = entry.kind,
                        .start = self.index,
                        .end = self.index + entry.text.len,
                    };
                    self.index += entry.text.len;
                    return tok;
                }
            }

            for (access_mods) |word| {
                if (std.mem.startsWith(u8, slice, word)) {
                    const tok = Token{
                        .kind = TokenKind.ACCESS_MODIFIER,
                        .start = self.index,
                        .end = self.index + word.len,
                    };
                    self.index += word.len;
                    return tok;
                }
            }

            if ((slice[0] == 'p' or slice[0] == 'v') and slice.len > 1 and std.ascii.isDigit(slice[1])) {
                var i = self.index + 1;
                while (i < self.input.len and std.ascii.isDigit(self.input[i])) : (i += 1) {}
                const tok = Token{
                    .kind = TokenKind.REGISTER,
                    .start = self.index,
                    .end = i,
                };
                self.index = i;
                return tok;
            }

            if (slice[0] == 'L') {
                var i = self.index + 1;
                while (i < self.input.len and self.input[i] != ';') : (i += 1) {}
                if (i < self.input.len and self.input[i] == ';') {
                    i += 1;
                    const tok = Token{
                        .kind = TokenKind.TYPE_DESCRIPTOR,
                        .start = self.index,
                        .end = i,
                    };
                    self.index = i;
                    return tok;
                }
            }

            if (slice[0] == '<') {
                var i = self.index + 1;
                while (i < self.input.len and self.input[i] != '>') : (i += 1) {}
                if (i < self.input.len and self.input[i] == '>') {
                    i += 1;
                    const tok = Token{
                        .kind = TokenKind.METHOD_NAME,
                        .start = self.index,
                        .end = i,
                    };
                    self.index = i;
                    return tok;
                }
            }

            if (slice[0] == '"') {
                var i = self.index + 1;
                while (i < self.input.len and self.input[i] != '"') : (i += 1) {}
                if (i < self.input.len and self.input[i] == '"') {
                    i += 1;
                    const tok = Token{
                        .kind = TokenKind.STRING_LITERAL,
                        .start = self.index + 1,
                        .end = i - 1,
                    };
                    self.index = i;
                    return tok;
                }
            }

            if (std.ascii.isDigit(slice[0])) {
                var i = self.index;
                while (i < self.input.len and std.ascii.isDigit(self.input[i])) : (i += 1) {}
                const tok = Token{
                    .kind = TokenKind.NUMBER_LITERAL,
                    .start = self.index,
                    .end = i,
                };
                self.index = i;
                return tok;
            }

            if (std.ascii.isAlphabetic(slice[0])) {
                var i = self.index + 1;
                while (i < self.input.len and (std.ascii.isAlphabetic(
                    self.input[i],
                ) or std.ascii.isDigit(self.input[i]))) : (i += 1) {}
                const tok = Token{
                    .kind = TokenKind.IDENTIFIER,
                    .start = self.index,
                    .end = i,
                };
                self.index = i;
                return tok;
            }

            if (std.mem.indexOfScalar(
                u8,
                shorty_types,
                slice[0],
            )) |_| {
                const tok = Token{
                    .kind = TokenKind.SHORTY_TYPE,
                    .start = self.index,
                    .end = self.index + 1,
                };
                self.index += 1;
                return tok;
            }

            for (symbols) |entry| {
                if (slice[0] == entry.sym) {
                    const tok = Token{
                        .kind = entry.kind,
                        .start = self.index,
                        .end = self.index + 1,
                    };
                    self.index += 1;
                    return tok;
                }
            }

            if (std.mem.startsWith(u8, slice, "->")) {
                const tok = Token{
                    .kind = TokenKind.ARROW,
                    .start = self.index,
                    .end = self.index + 2,
                };
                self.index += 2;
                return tok;
            }

            const tok = Token{
                .kind = TokenKind.UNKNOWN,
                .start = self.index,
                .end = self.index + 1,
            };
            self.index += 1;
            return tok;
        }

        return Token{
            .kind = TokenKind.EOF,
            .start = self.index,
            .end = self.index,
        };
    }
};
