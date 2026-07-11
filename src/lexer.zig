/// The lexer is responsible for transforming the given source file
/// into meaningful tokens.
///
/// The source file is loaded into memory and must be alive for the entire
/// life of the assembler.
const std = @import("std");
const Self = @This();

pub const TokenArg = struct {
    /// The type of the argument, which can be one of the following:
    /// - Numerical: A numeric value, which can be in decimal, hexadecimal, or binary
    /// - Register
    /// - Label
    /// - StringLiteral
    pub const TokenArgType = enum {
        Numerical,
        Register,
        Label,
        StringLiteral,
    };

    /// The type of the argument.
    type: TokenArgType,
    /// String representation of the argument.
    value: []const u8,

    /// Creates a new TokenArg with the given TokenArgType and string representation
    /// of the value.
    ///
    /// Also performs a trim on the given value
    pub fn init(arg_type: TokenArgType, value: []const u8) TokenArg {
        const clean_value = std.mem.trim(u8, value, " \t");
        return TokenArg{ .type = arg_type, .value = clean_value };
    }
};

const TokenError = error{
    MaxArgumentsExceeded,
};

pub const Token = struct {
    /// The type of the token, which can be one of the following:
    /// - Directive: A directive, which starts with a dot (.)
    /// - Mnemonic: An instruction mnemonic, which is a valid assembly instruction
    /// - Label: A label, which ends with a colon (:)
    pub const TokenType = enum {
        Directive,
        Mnemonic,
        Label,
    };

    /// The type of the token.
    type: TokenType,
    /// 'Name' of the token (e.g., the directive name, mnemonic name, or label name).
    name: []const u8,
    /// The arguments of the token, which can be zero or more.
    args: std.ArrayList(TokenArg),
    /// The line number of the token in the source file.
    line_number: usize,

    /// Initializes a new Token with the given type and line number.
    ///
    /// Also performs a trim on the given value
    pub fn init(allocator: std.mem.Allocator, name: []const u8, token_type: TokenType, line_number: usize) !Token {
        const args = std.ArrayList(TokenArg).initCapacity(allocator, 0);
        const clean_name = std.mem.trim(u8, name, " \t");

        return Token{ .type = token_type, .name = clean_name, .args = args, .line_number = line_number };
    }

    /// Adds an argument to the token.
    pub fn addArgument(self: *Token, allocator: std.mem.Allocator, token: TokenArg) !void {
        try self.args.append(allocator, token);
    }

    /// Deinitializes the Token, freeing its arguments.
    pub fn deinit(self: *Token, allocator: std.mem.Allocator) void {
        self.args.deinit(allocator);
    }
};

const LexerError = error{
    LineTooShort,
};

const State = enum { START, SYM_READ, DIR_READ, NUM_DEC, NUM_HEX, NUM_BIN, NUM_OCT, NEG_SIGN, OFFSET_READ, PARANTHESIS_READ, REG_READ, PARANTHESIS_CLOSE, STRING, ERROR };

// <Struct fields>
source_file_buffer: []const u8,
tokens: std.ArrayList(Token),

/// Initializes the Lexer by reading the input file and tokenizing its contents.
pub fn init(allocator: std.mem.Allocator, io: std.Io, filename: []const u8) !Self {
    const contents = std.Io.Dir.cwd().readFileAlloc(io, filename, allocator, .unlimited) catch |err| {
        std.debug.print("[Lexer.init() -> std.Io.Dir.cwd().readFileAlloc()] Error: {any}", .{err});
        return err;
    };

    var tokens = std.ArrayList(Token).initCapacity(allocator, 0) catch |err| {
        std.debug.print("[Lexer.init() -> std.ArrayList(Token).initCapacity()] Error: {any}", .{err});
        return err;
    };

    var line_number: usize = 1;
    var line_iterator = std.mem.splitScalar(u8, contents, '\n');
    while (line_iterator.next()) |line| : (line_number += 1) {
        // Clean carriage return in case file comes from Windows
        const carriage_stripped_line = std.mem.trimEnd(u8, line, "\r");
        const trimmed_line = std.mem.trim(u8, carriage_stripped_line, " \t");

        if (trimmed_line.len == 0)
            continue;

        if (std.mem.startsWith(u8, trimmed_line, "#"))
            continue;

        // Remove commentary from the end of the line
        const comment_start = std.mem.findPos(u8, trimmed_line, 0, "#");
        var clean_line = trimmed_line;
        if (comment_start) |line_end| {
            clean_line = std.mem.trimEnd(u8, trimmed_line[0..line_end], " \t");
        }

        if (clean_line.len < 2) {
            std.debug.print("[Error] Line: {d} Length of line is too short ({s}) for it to mean anything.", .{ line_number, line });
            return LexerError.LineTooShort;
        }

        // Deterministic Finite Automaton
        var cursor: usize = 0;
        var token_start: usize = 0;
        var state: State = State.START;
        var current_token: ?Token = null;
        while (cursor < clean_line.len) : (cursor += 1) {
            switch (state) {
                .START => {
                    const c = clean_line[cursor];
                    if (c == ' ' or c == '\t' or c == ',') {
                        continue;
                    }

                    if (c == '.') {
                        token_start = cursor;
                        state = .DIR_READ;
                    } else if (std.ascii.isAlphabetic(c) or c == '_') {
                        token_start = cursor;
                        state = .SYM_READ;
                    } else if (c == '-') {
                        token_start = cursor;
                        state = .NEG_SIGN;
                    } else if (c == '0') {
                        token_start = cursor;
                        state = .NUM_DEC;
                    } else if (std.ascii.isDigit(c)) {
                        token_start = cursor;
                        state = .NUM_DEC;
                    } else if (c == '"') {
                        token_start = cursor;
                        state = .STRING;
                    } else {
                        state = .ERROR;
                    }
                },

                .SYM_READ => {
                    const c = clean_line[cursor];
                    if (std.ascii.isAlphanumeric(c) or c == '_') {
                        if (cursor + 1 == clean_line.len) {
                            const sym_slice = clean_line[token_start..(cursor + 1)];
                            try handleFinishedSymbol(allocator, sym_slice, line_number, &current_token);
                            state = .START;
                        }
                    } else if (c == ':') {
                        const label_slice = clean_line[token_start..cursor];
                        const label_token = try Token.init(allocator, label_slice, .Label, line_number);
                        try tokens.append(allocator, label_token);
                        state = .START;
                    } else {
                        const sym_slice = clean_line[token_start..cursor];
                        try handleFinishedSymbol(allocator, sym_slice, line_number, &current_token);
                        cursor -= 1;
                        state = .START;
                    }
                },

                .DIR_READ => {
                    const c = clean_line[cursor];
                    if (std.ascii.isAlphanumeric(c) or c == '_') {
                        if (cursor + 1 == clean_line.len) {
                            const dir_slice = clean_line[token_start..(cursor + 1)];
                            current_token = try Token.init(allocator, dir_slice, .Directive, line_number);
                            state = .START;
                        }
                    } else {
                        const dir_slice = clean_line[token_start..cursor];
                        current_token = try Token.init(allocator, dir_slice, .Directive, line_number);
                        cursor -= 1;
                        state = .START;
                    }
                },

                .NEG_SIGN => {
                    const c = clean_line[cursor];
                    if (std.ascii.isDigit(c)) {
                        state = .NUM_DEC;
                    } else {
                        state = .ERROR;
                    }
                },

                .NUM_DEC => {
                    const c = clean_line[cursor];
                    if (cursor == token_start + 1 and clean_line[token_start] == '0') {
                        if (c == 'x' or c == 'X') { state = .NUM_HEX; continue; }
                        if (c == 'b' or c == 'B') { state = .NUM_BIN; continue; }
                        if (c == 'o' or c == 'O') { state = .NUM_OCT; continue; }
                    }

                    if (std.ascii.isDigit(c)) {
                        if (cursor + 1 == clean_line.len) {
                            const num_slice = clean_line[token_start..(cursor + 1)];
                            try handleFinishedNumerical(allocator, num_slice, &current_token);
                            state = .START;
                        }
                    } else {
                        const num_slice = clean_line[token_start..cursor];
                        try handleFinishedNumerical(allocator, num_slice, &current_token);
                        cursor -= 1;
                        state = .START;
                    }
                },

                .NUM_BIN => {
                    const c = clean_line[cursor];
                    if (c == '0' or c == '1') {
                        if (cursor + 1 == clean_line.len) {
                            const num_slice = clean_line[token_start..(cursor + 1)];
                            try handleFinishedNumerical(allocator, num_slice, &current_token);
                            state = .START;
                        }
                    } else {
                        const num_slice = clean_line[token_start..cursor];
                        try handleFinishedNumerical(allocator, num_slice, &current_token);
                        cursor -= 1;
                        state = .START;
                    }    
                },

                .NUM_HEX => {
                    const c = clean_line[cursor];
                    if (std.ascii.isHex(c)) {
                        if (cursor + 1 == clean_line.len) {
                            const num_slice = clean_line[token_start..(cursor + 1)];
                            try handleFinishedNumerical(allocator, num_slice, &current_token);
                            state = .START;
                        }
                    } else {
                        const num_slice = clean_line[cursor];
                        try handleFinishedNumerical(allocator, num_slice, &current_token);
                        cursor -= 1;
                        state = .START;
                    }
                },

                .NUM_OCT => {
                    const c = clean_line[cursor];
                    if (c >= '0' and c <= '7') {
                        if (cursor + 1 == clean_line.len) {
                            const num_slice = clean_line[token_start..(cursor + 1)];
                            try handleFinishedNumerical(allocator, num_slice, &current_token);
                            state = .START;
                        }
                    } else {
                        const num_slice = clean_line[cursor];
                        try handleFinishedNumerical(allocator, num_slice, &current_token);
                        cursor -= 1;
                        state = .START;
                    }
                },

                .STRING => {
                    const c = clean_line[cursor];
                    // todo()
                    if (c == '"' and clean_line[cursor-1] != '\\') {
                        if (current_token == null) {
                            state = .ERROR;
                            continue;
                        }

                        const string_slice = clean_line[token_start..cursor];
                        const arg = TokenArg.init(.StringLiteral, string_slice);
                        try current_token.?.addArgument(allocator, arg);
                        state = .START;
                    }
                },
            }
        }
    }

    return Self{ .tokens = tokens };
}

fn handleFinishedSymbol(allocator: std.mem.Allocator, slice: []const u8, line_number: usize, current_token: *?Token) !void {
    if (current_token.* == null) {
        current_token.* = try Token.init(allocator, slice, .Mnemonic, line_number);
        return;
    }

    const arg = TokenArg.init(.Register, slice);
    try current_token.*.?.addArgument(allocator, arg);
}

fn handleFinishedNumerical(allocator: std.mem.Allocator, slice: []const u8, line_number: usize, current_token: *?Token) !void {
    if (current_token.* == null) {
        return LexerError.LineTooShort; // todo
    }

    const arg = TokenArg.init(.Numerical, slice);
    try current_token.*.?.addArgument(allocator, arg); 
}

/// Deinitializes the Lexer, freeing its tokens.
pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    for (self.tokens.items) |*token| {
        token.deinit(allocator);
    }

    self.tokens.deinit(allocator);
}
// <Struct fields>
