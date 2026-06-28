const std = @import("std");
const Io = std.Io;

const lexer = @import("lexer.zig");

pub fn main(init: std.process.Init) !void {
    var l = try lexer.init(init.gpa, init.io, "usart_and_i2c.s");
    for (l.tokens.items) |token| {
        std.debug.print("[Line {d:>3}] {s:<9} | args: [", .{ token.line_number, @tagName(token.type) });

        for (token.args.items, 0..) |arg, i| {
            std.debug.print("{s}(\"{s}\")", .{ @tagName(arg.type), arg.value });

            if (i < token.args.items.len - 1) {
                std.debug.print(", ", .{});
            }
        }

        std.debug.print("]\n", .{});
    }
    l.deinit(init.gpa);
}
