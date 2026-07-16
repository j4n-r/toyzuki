const std = @import("std");
const linux = std.os.linux;

const Config = struct {
    ociVersion: []const u8,
    process: Process,
    hostname: []const u8,
    linux: OCILinux,
    mounts: []const OCIMounts,
};

const Context = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
};

const Process = struct {
    args: []const [:0]const u8,
    env: []const [:0]const u8,
    cwd: [:0]const u8,
};

const OCILinux = struct {
    namespaces: []NamespaceType,
};

const NamespaceType = struct {
    type: Namespaces,
};
const Namespaces = enum {
    pid,
    mount,
    network,
    uts,
    user,
    cgroup,
    ipc,
    time,
};

const OCIMounts = struct {
    destination: [:0]const u8,
    type: [:0]const u8,
    source: [:0]const u8,
};

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

fn child(child_args: usize) callconv(.c) u8 {
    const context: *Context = @ptrFromInt(child_args);
    const config = context.config;

    const hostname = "container";
    const sethostname_result = linux.syscall2(.sethostname, @intFromPtr(hostname), hostname.len);
    const hostname_err = linux.errno(sethostname_result);
    if (hostname_err != .SUCCESS) {
        std.log.info("sethostname failed: {t}", .{hostname_err});
        return 1;
    }

    const chroot_result = linux.chroot("bundle/rootfs");
    const chroot_err = linux.errno(chroot_result);
    if (chroot_err != .SUCCESS) {
        std.debug.print("Chroot failed: {t}", .{chroot_err});
        return 1;
    }

    const chdir_result = linux.chdir(config.process.cwd);
    const chdir_err = linux.errno(chdir_result);
    if (chroot_err != .SUCCESS) {
        std.debug.print("chdir failed: {t}", .{chdir_err});
        return 1;
    }

    for (config.mounts) |mount| {
        std.debug.print(
            "Mount {s} -> {s} with type: {s}\n",
            .{
                mount.source,
                mount.destination,
                mount.type,
            },
        );

        const mount_result = linux.mount(mount.source, mount.destination, mount.type, 0, 0);
        const mount_err = linux.errno(mount_result);
        if (mount_err != .SUCCESS) {
            std.debug.print(
                "Mount {s} -> {s} failed: {s}\n",
                .{
                    mount.source,
                    mount.destination,
                    @tagName(chroot_err),
                },
            );
            return 1;
        }
    }

    const argv = makeCStringVector(config.process.args, context.allocator) catch |err| {
        std.log.err("makeCStringVector(argv) failed: {}", .{err});
        return 1;
    };

    const envp = makeCStringVector(config.process.env, context.allocator) catch |err| {
        std.log.err("makeCStringVector(envp) failed: {}", .{err});
        return 1;
    };

    std.log.debug("cwd: {s}", .{config.process.cwd});

    for (argv, 0..) |arg, i| {
        std.log.debug("argv[{d}]: {s}", .{ i, arg.? });
    }

    for (envp, 0..) |env, i| {
        std.log.debug("envp[{d}]: {s}", .{ i, env.? });
    }

    std.log.debug("executing: {s}", .{argv[0].?});

    const execve_result = linux.execve(argv[0].?, argv.ptr, envp.ptr);
    const execve_err = linux.errno(execve_result);
    if (execve_err != .SUCCESS) {
        std.debug.print("execve failed: {t}", .{execve_err});
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

    const context = Context{
        .allocator = allocator,
        .config = &config,
    };

    std.log.debug("Flags: 0x{x}", .{flags});
    const result = linux.clone(child, stack_top, flags, @intFromPtr(&context), null, 0, null);
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

fn makeCStringVector(strings: []const [:0]const u8, allocator: std.mem.Allocator) ![:null]?[*:0]const u8 {
    const buffer = try allocator.allocSentinel(?[*:0]const u8, strings.len, null);

    for (strings, 0..) |str, i| {
        buffer[i] = str.ptr;
    }

    return buffer;
}
