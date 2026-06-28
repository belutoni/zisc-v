const std = @import("std");

// All files are structs in Zig so we get the 'type' of the current file
// to be able to return an initialized object back
const Self = @This();

// <Struct fields>
io: std.Io,
// <Struct fields>
