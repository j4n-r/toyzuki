const std = @import("std");
const linux = std.os.linux;

const Config = struct { ociVersion: []const u8, process: Process, hostname: []const u8, linux: OCILinux };

const Process = struct {
    args: []const []const u8,
    env: []const []const u8,
    cwd: []const u8,
};

const OCILinux = struct { namespaces: []NamespaceType };

const NamespaceType = struct { type: Namespaces };
const Namespaces = enum { pid, mount, network, uts, user, cgroup, ipc, time };

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    std.debug.print("command={s}, path={s}\n", .{
        args[1],
        args[2],
    });
    if (args.len < 2) {
        std.debug.panic("please provide args", .{});
    }
    if (!std.mem.eql(u8, args[1], "run")) {
        std.debug.panic("Only 'run' is implemented atm", .{});
    }

    const file_path = args[2];

    const file_contents = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(1024 * 1024));

    defer allocator.free(file_contents);

    const parsed_config = try std.json.parseFromSlice(
        Config,
        arena,
        file_contents,
        .{
            .ignore_unknown_fields = true,
        },
    );
    std.debug.print("{any}\n", .{parsed_config.value});

    try run(parsed_config.value, arena);
}

fn child(arg: usize) callconv(.c) u8 {
    const config: *Config = @ptrFromInt(arg);
    const chroot_result = linux.chroot("bundle/rootfs");
    const err = linux.errno(chroot_result);
    if (err != .SUCCESS) {
        std.debug.print("Chroot failed: {t}", .{err});
        return 1;
    }
    std.debug.print("Ran child \nconfig: {any}", .{config});
    return 0;
}

fn run(config: Config, allocator: std.mem.Allocator) !void {
    const stack = try allocator.alignedAlloc(u8, std.mem.Alignment.@"16", 1024 * 1024);
    defer allocator.free(stack);

    var flags: u32 = @intFromEnum(linux.SIG.CHLD);

    for (config.linux.namespaces) |namespace| {
        switch (namespace.type) {
            .pid => flags |= linux.CLONE.NEWPID,
            .mount => flags |= linux.CLONE.NEWNS,
            .network => flags |= linux.CLONE.NEWNET,
            .uts => flags |= linux.CLONE.NEWUTS,
            .user => flags |= linux.CLONE.NEWUSER,
            .cgroup => flags |= linux.CLONE.NEWCGROUP,
            .ipc => flags |= linux.CLONE.NEWIPC,
            .time => flags |= linux.CLONE.NEWTIME,
        }
    }
    const stack_top = @intFromPtr(stack.ptr) + stack.len;

    const result = linux.clone(child, stack_top, flags, @intFromPtr(&config), null, 0, null);
    const clone_errno = linux.errno(result);
    switch (clone_errno) {
        .SUCCESS => {},
        else => |err| {
            std.debug.print("clone failed: {t}\n", .{err});
            return error.CloneFailed;
        },
    }

    const child_pid: linux.pid_t = @intCast(result);

    var status: i32 = 0;

    while (true) {
        const wait_result = linux.waitpid(child_pid, &status, 0);
        switch (linux.errno(wait_result)) {
            .SUCCESS => break,
            .INTR => continue, // Interrupted by a signal; try again.
            else => |err| {
                std.debug.print("waitpid failed: {t}\n", .{err});
                return;
            },
        }
    }
}
