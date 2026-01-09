const std = @import("std");

fn foo(a: i32, b: i32) i32 {
    return a + b;
}

fn bar() void {
    const x = foo(1, 2);
    const y = foo(10, 20);
    std.debug.print("x={}, y={}\n", .{ x, y });
}

pub fn main() void {
    bar();
}
