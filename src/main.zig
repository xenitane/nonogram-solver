const std = @import("std");
const nonogram = @import("nonogram.zig");

pub fn main() !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    const args = std.os.argv;
    for (args, 0..) |arg, i| {
        try stdout.print("{d:0>2}: {s}\n", .{ i, arg });
    }
    try bw.flush();
}
