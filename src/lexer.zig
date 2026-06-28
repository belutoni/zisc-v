const std = @import("std");

// All files are structs in Zig so we get the 'type' of the current file
// to be able to return an initialized object back
const Self = @This();

pub const directives = [_][]const u8{
    ".option",
    ".insn",
    ".attribute",
    ".dtprelword",
    ".dtpreldword",
    ".sleb128",
    ".uleb128",

    // Data and Memory Allocation
    ".byte",
    ".half",
    ".short",
    ".word",
    ".int",
    ".dword",
    ".quad",
    ".float",
    ".double",
    ".ascii",
    ".asciz",
    ".string",
    ".zero",
    ".space",

    // Sections and Alignment
    ".text",
    ".data",
    ".rodata",
    ".bss",
    ".section",
    ".align",
    ".balign",
    ".p2align",

    // Symbol Visibility and Typing
    ".global",
    ".globl",
    ".local",
    ".extern",
    ".type",
    ".size",
    ".equ",
    ".set",

    // Macros and Conditionals
    ".macro",
    ".endm",
    ".if",
    ".else",
    ".elif",
    ".endif",
    ".include",
};

pub const TokenArg = struct {
    pub const TokenArgType = enum {
        Numerical,
        Register,
        Label,
        StringLiteral,
        DirectiveName,
    };

    type: TokenArgType,
    value: []const u8,

    pub fn init(allocator: std.mem.Allocator, arg_type: TokenArgType, value: []const u8) !TokenArg {
        const clean_value = std.mem.trim(u8, value, " \t");
        const duped_value = try allocator.dupe(u8, clean_value);
        return TokenArg{ .type = arg_type, .value = duped_value };
    }

    pub fn deinit(self: TokenArg, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
    }
};

const TokenError = error{
    MaxArgumentsExceeded,
};

pub const Token = struct {
    const MaxArgsLen = 3;
    pub const TokenType = enum {
        Directive, // => .data / .text / tba
        Mnemonic, // => nop / add x2, x3, x1 / etc
        Label, //  => label_name:
    };

    type: TokenType,
    args: std.ArrayList(TokenArg),
    line_number: usize,

    pub fn init(allocator: std.mem.Allocator, token_type: TokenType, line_number: usize) Token {
        const args = std.ArrayList(TokenArg).initCapacity(allocator, 4) catch |err| {
            std.debug.print("[Token.init() -> std.ArrayList(TokenArg).initCapacity()] Error: {any}", .{err});
            std.process.exit(1);
        };

        return Token{ .type = token_type, .args = args, .line_number = line_number };
    }

    pub fn addArgument(self: *Token, allocator: std.mem.Allocator, token: TokenArg) !void {
        try self.args.append(allocator, token);
    }

    pub fn validate(self: Token) bool {
        if (self.type == Token.TokenType.Mnemonic) {
            return self.args.len <= 3;
        }

        // Can have an infinite amount of arguments (with ArgType != Register)
        if (self.type == Token.TokenType.Directive) {
            for (self.args) |arg| {
                if (arg.type == TokenArg.TokenArgType.Register) {
                    return false;
                }
            }

            return true;
        }

        return self.args.len == 0;
    }

    pub fn deinit(self: *Token, allocator: std.mem.Allocator) void {
        self.args.deinit(allocator);
    }
};

// <Struct fields>
tokens: std.ArrayList(Token),
pub fn init(allocator: std.mem.Allocator, io: std.Io, filename: []const u8) !Self {
    // Read file
    const contents = std.Io.Dir.cwd().readFileAlloc(io, filename, allocator, .unlimited) catch |err| {
        std.debug.print("[Lexer.init() -> std.Io.Dir.cwd().readFileAlloc()] Error: {any}", .{err});
        std.process.exit(1);
    };
    defer allocator.free(contents);

    var tokens = std.ArrayList(Token).initCapacity(allocator, 64) catch |err| {
        std.debug.print("[Lexer.init() -> std.ArrayList(Token).initCapacity()] Error: {any}", .{err});
        std.process.exit(1);
    };

    var line_number: usize = 1;
    var line_iterator = std.mem.splitScalar(u8, contents, '\n');
    while (line_iterator.next()) |line| : (line_number += 1) {
        // Clean carriage return in case file comes from Windows
        const carriage_stripped_line = std.mem.trimEnd(u8, line, "\r");
        const trimmed_line = std.mem.trim(u8, carriage_stripped_line, " \t");

        // Empty line
        if (trimmed_line.len == 0)
            continue;

        // Commentary
        if (std.mem.startsWith(u8, trimmed_line, "#"))
            continue;

        // Remove commentary from the end of the line
        const commentary_start = std.mem.findPos(u8, trimmed_line, 0, "#");
        var commentary_clean_line = trimmed_line;
        if (commentary_start) |line_end| {
            commentary_clean_line = std.mem.trimEnd(u8, trimmed_line[0..line_end], " \t");
        }

        if (commentary_clean_line.len < 2) {
            std.debug.print("[Lexer Error] Length of line is too short ({s}) for it to mean anything.", .{line});
            std.process.exit(1);
        }

        const clean_line = std.ascii.allocLowerString(allocator, commentary_clean_line) catch |err| {
            std.debug.print("[Lexer.init() -> std.ascii.allocLowerString()] Error: {any}", .{err});
            std.process.exit(1);
        };
        defer allocator.free(clean_line);

        // Directive
        if (std.mem.startsWith(u8, clean_line, ".")) {
            if (!isDirective(clean_line)) {
                std.debug.print("[Lexer Error] Line starts with '.', making it a directive, but has an illegal format: {s}", .{line});
                std.process.exit(1);
            }

            const first_space = std.mem.findPos(u8, clean_line, 0, " ");
            var token = Token.init(allocator, Token.TokenType.Directive, line_number);
            if (first_space) |start_index| {
                var directive_iterator = std.mem.splitScalar(u8, clean_line[start_index..], ',');
                while (directive_iterator.next()) |directive_arg| {
                    const clean_directive_arg = std.mem.trim(u8, directive_arg, " \t");
                    const arg_type = if (isLabel(clean_directive_arg)) TokenArg.TokenArgType.Label else TokenArg.TokenArgType.Numerical;
                    const token_arg = TokenArg.init(allocator, arg_type, clean_directive_arg) catch |err| {
                        std.debug.print("[Lexer.init() -> token_arg.init()] Error: {any}", .{err});
                        std.process.exit(1);
                    };
                    token.addArgument(allocator, token_arg) catch |err| {
                        std.debug.print("[Lexer.init() -> token.addArgument()] Error: {any}", .{err});
                        std.process.exit(1);
                    };
                }
            }

            tokens.append(allocator, token) catch |err| {
                std.debug.print("[Token.init() -> tokens.append()] Error: {any}", .{err});
                std.process.exit(1);
            };
            continue;
        }

        // Label
        if (std.mem.endsWith(u8, clean_line, ":")) {
            if (!isLabel(clean_line[0..(clean_line.len - 1)])) {
                std.debug.print("[Lexer Error] Line ends with ':', making it a label, but has an illegal format: {s}", .{line});
                std.process.exit(1);
            }

            const token_arg = TokenArg.init(allocator, TokenArg.TokenArgType.Label, clean_line[0..(clean_line.len - 1)]) catch |err| {
                std.debug.print("[Lexer.init() -> token_arg.init()] Error: {any}", .{err});
                std.process.exit(1);
            };
            var token = Token.init(allocator, Token.TokenType.Label, line_number);
            token.addArgument(allocator, token_arg) catch |err| {
                std.debug.print("[Lexer.init() -> token.addArgument()] Error: {any}", .{err});
                std.process.exit(1);
            };
            tokens.append(allocator, token) catch |err| {
                std.debug.print("[Lexer.init() -> tokens.append()] Error: {any}", .{err});
                std.process.exit(1);
            };
            continue;
        }

        // Operation
    }

    return Self{ .tokens = tokens };
}

pub fn isDirective(line: []const u8) bool {
    for (directives) |directive| {
        if (std.mem.startsWith(u8, line, directive)) {
            return true;
        }
    }

    return false;
}

pub fn isLabel(line: []const u8) bool {
    // Can only start with alphabetic characters, must NOT contain spaces
    // and must have only digits, underscore and alphabetic characters inside
    if (line.len == 0) {
        return false;
    }

    if (!std.ascii.isAlphabetic(line[0]) and line[0] != '_') {
        return false;
    }

    // We can run the loop since line.len >= 3
    for (line[1..]) |char| {
        if (char == ' ') {
            return false;
        }

        if (!std.ascii.isAlphanumeric(char) and char != '_') {
            return false;
        }
    }

    return true;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    for (self.tokens.items) |*token| {
        for (token.args.items) |*arg| {
            arg.deinit(allocator);
        }
        token.deinit(allocator);
    }

    self.tokens.deinit(allocator);
}
// <Struct fields>
