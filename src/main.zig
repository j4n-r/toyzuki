const std = @import("std");
const linux = std.os.linux;

const Context = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
};

const Config = struct {
    ociVersion: []const u8,
    process: struct {
        terminal: ?bool,
        args: []const [:0]const u8,
        env: []const [:0]const u8,
        cwd: [:0]const u8,
    },
    hostname: []const u8,
    root: struct {
        path: ?[]const u8,
        readonly: ?bool,
    },
    linux: struct {
        namespaces: ?[]struct {
            type: Namespaces,
        },
        cgroupsPath: ?[]const u8,
        resources: ?Resource,
    },
    mounts: ?[]struct {
        destination: [:0]const u8,
        type: [:0]const u8,
        source: [:0]const u8,
        options: [][:0]const u8 = &.{},
    },
};

const Resource = struct {
    pids: ?struct { limit: u64 },
    memory: ?struct { limit: u64 },
    cpu: ?struct {
        quota: u64,
        period: u64,
    },
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

pub const MountOption = struct {
    name: []const u8,
    clear: bool, // inverted option (e.g. "rw" clears MS_RDONLY)
    flag: u32,
};

// Mirror of runc's mountFlags map (spec_linux.go:73)
const mount_flags = [_]MountOption{
    .{ .name = "async", .clear = true, .flag = linux.MS.SYNCHRONOUS },
    .{ .name = "atime", .clear = true, .flag = linux.MS.NOATIME },
    .{ .name = "bind", .clear = false, .flag = linux.MS.BIND },
    .{ .name = "defaults", .clear = false, .flag = 0 },
    .{ .name = "dev", .clear = true, .flag = linux.MS.NODEV },
    .{ .name = "diratime", .clear = true, .flag = linux.MS.NODIRATIME },
    .{ .name = "dirsync", .clear = false, .flag = linux.MS.DIRSYNC },
    .{ .name = "exec", .clear = true, .flag = linux.MS.NOEXEC },
    .{ .name = "noatime", .clear = false, .flag = linux.MS.NOATIME },
    .{ .name = "nodev", .clear = false, .flag = linux.MS.NODEV },
    .{ .name = "nodiratime", .clear = false, .flag = linux.MS.NODIRATIME },
    .{ .name = "noexec", .clear = false, .flag = linux.MS.NOEXEC },
    .{ .name = "nosuid", .clear = false, .flag = linux.MS.NOSUID },
    .{ .name = "rbind", .clear = false, .flag = linux.MS.BIND | linux.MS.REC },
    .{ .name = "relatime", .clear = false, .flag = linux.MS.RELATIME },
    .{ .name = "remount", .clear = false, .flag = linux.MS.REMOUNT },
    .{ .name = "ro", .clear = false, .flag = linux.MS.RDONLY },
    .{ .name = "rw", .clear = true, .flag = linux.MS.RDONLY },
    .{ .name = "silent", .clear = false, .flag = linux.MS.SILENT },
    .{ .name = "strictatime", .clear = false, .flag = linux.MS.STRICTATIME },
    .{ .name = "suid", .clear = true, .flag = linux.MS.NOSUID },
    .{ .name = "sync", .clear = false, .flag = linux.MS.SYNCHRONOUS },
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

    var scanner = std.json.Scanner.initCompleteInput(allocator, file_contents);
    defer scanner.deinit();

    var diagnostics: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diagnostics);

    const parsed_config = std.json.parseFromTokenSource(
        Config,
        arena,
        &scanner,
        .{},
    ) catch |err| {
        std.debug.print(
            "JSON error: {s} at {d}:{d}, byte {d}\n",
            .{
                @errorName(err),
                diagnostics.getLine(),
                diagnostics.getColumn(),
                diagnostics.getByteOffset(),
            },
        );
        return err;
    };

    std.debug.print("{any}\n", .{parsed_config.value});

    try run(parsed_config.value, arena);
}

fn child(child_args: usize) callconv(.c) u8 {
    const context: *Context = @ptrFromInt(child_args);
    const config = context.config;

    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

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
    if (chdir_err != .SUCCESS) {
        std.debug.print("chdir failed: {t}", .{chdir_err});
        return 1;
    }

    if (config.mounts) |mounts| {
        for (mounts) |mount| {
            std.debug.print(
                "Trying to Mount {s} -> {s} with type: {s}\n",
                .{
                    mount.source,
                    mount.destination,
                    mount.type,
                },
            );

            const dir = std.Io.Dir.cwd();
            std.Io.Dir.createDirPath(dir, io, mount.destination) catch {
                return 1;
            };

            var flags: u32 = 0;
            for (mount.options) |option| {
                for (mount_flags) |candidate| {
                    if (std.mem.eql(u8, option, candidate.name)) {
                        if (candidate.clear) {
                            flags &= ~candidate.flag;
                        } else {
                            flags |= candidate.flag;
                        }
                        break;
                    }
                }
            }

            const mount_result = linux.mount(mount.source, mount.destination, mount.type, flags, 0);
            const mount_err = linux.errno(mount_result);
            if (mount_err != .SUCCESS) {
                std.debug.print(
                    "Mount {s} -> {s} failed: {s}\n",
                    .{
                        mount.source,
                        mount.destination,
                        @tagName(mount_err),
                    },
                );
                return 1;
            }
        }
    }

    const dir = std.Io.Dir.cwd();
    std.Io.Dir.createDirPath(dir, io, "/sys/fs/cgroup/container") catch |err| {
        std.debug.print("Create cgroup path failed: {s}", .{@errorName(err)});
        return 1;
    };

    const cgroup_dir = std.Io.Dir.openDirAbsolute(io, "/sys/fs/cgroup/container", .{}) catch |err| {
        std.debug.print("ERR: {s}", .{@errorName(err)});
        return 1;
    };

    if (config.linux.resources) |resources| {
        if (resources.cpu) |cpu| {
            const content = std.fmt.allocPrint(
                context.allocator,
                "{d} {d}\n",
                .{ cpu.quota, cpu.period },
            ) catch |err| {
                std.debug.print("ERR: {s}\n", .{@errorName(err)});
                return 1;
            };
            defer context.allocator.free(content);

            cgroup_dir.writeFile(io, .{
                .sub_path = "cpu.max",
                .data = content,
                .flags = .{},
            }) catch |err| {
                std.debug.print("ERR: {s}\n", .{@errorName(err)});
                return 1;
            };
        }
        if (resources.memory) |memory| {
            const content = std.fmt.allocPrint(
                context.allocator,
                "{d}\n",
                .{memory.limit},
            ) catch |err| {
                std.debug.print("ERR: {s}\n", .{@errorName(err)});
                return 1;
            };
            defer context.allocator.free(content);

            cgroup_dir.writeFile(io, .{
                .sub_path = "memory.max",
                .data = content,
                .flags = .{},
            }) catch |err| {
                std.debug.print("ERR: {s}\n", .{@errorName(err)});
                return 1;
            };
        }
        if (resources.pids) |pids| {
            const content = std.fmt.allocPrint(
                context.allocator,
                "{d}\n",
                .{pids.limit},
            ) catch |err| {
                std.debug.print("ERR: {s}\n", .{@errorName(err)});
                return 1;
            };
            defer context.allocator.free(content);

            cgroup_dir.writeFile(io, .{
                .sub_path = "pids.max",
                .data = content,
                .flags = .{},
            }) catch |err| {
                std.debug.print("ERR: {s}\n", .{@errorName(err)});
                return 1;
            };
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

    var flags: u32 = @backingInt(linux.SIG.CHLD);
    if (config.linux.namespaces) |namespaces| {
        for (namespaces) |namespace| {
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
