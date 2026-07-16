# Review TODO

## High Priority

- [ ] Fix relative mount destinations escaping the chroot (`src/main.zig:165-177`). `chroot()` does not change the working directory, and mounts occur before `chdir()`. Change to `/` immediately after `chroot`, or reject and normalize relative destinations against the container root.
- [ ] Apply resource limits to the container process (`src/main.zig:224-290`). The new cgroup is configured, but the container PID is never added to `cgroup.procs`, so the limits have no effect. Also use `linux.cgroupsPath` instead of the hardcoded `/container` path.
- [ ] Configure cgroups through the host cgroup hierarchy (`src/main.zig:218-227`). The bundled configuration mounts `/sys` read-only and then attempts to create `/sys/fs/cgroup/container`, causing `ReadOnlyFileSystem`; sysfs is not itself a cgroup2 filesystem. Perform cgroup setup before `chroot` and only when resources are requested.
- [ ] Add defaults to nullable JSON fields (`src/main.zig:12-43`). Nullable fields without `= null` are still required and produce `MissingField` when omitted. This breaks `bundle/micro_config.json`. Add appropriate null or semantic defaults, such as `terminal: bool = false`.
- [ ] Restore unknown-field tolerance when parsing OCI configurations (`src/main.zig:119-123`). Normal OCI configurations containing unmodeled fields currently fail with `UnknownField`. Restore `.ignore_unknown_fields = true` unless the complete schema is modeled.

## Medium Priority

- [ ] Forward filesystem-specific mount options as mount data (`src/main.zig:181-195`). Options not represented by mount flags are silently ignored while mount data is always null. Preserve options such as `mode=755`, `size=65536k`, `newinstance`, and `ptmxmode=0666`.
- [ ] Support OCI unlimited resource values (`src/main.zig:37-43`). PID and memory limits and CPU quota can use the signed value `-1` for unlimited, but the current `u64` fields reject it. Use signed optional values and translate `-1` to cgroup v2's `max`.
- [ ] Handle file bind-mount destinations (`src/main.zig:176-179`). `createDirPath` requires a directory and rejects common file targets such as `/etc/resolv.conf`. Create or validate file and directory mount points separately.

## Low Priority

- [ ] Correct the case-sensitive mount option in `bundle/mini_config.json:71`. Change `Nodev` to `nodev` so `MS_NODEV` is applied.

## Verification Notes

- `zig build` passes.
- `zig build test` passes.
- Running `bundle/micro_config.json` reproduces the `MissingField` parser regression.
- Privileged child execution was not tested because the current user lacks the required privileges.


# Other
Found it. This is mount propagation leaking everything into the host namespace — the missing MS_SLAVE step that runc does right after clone:
What happened
1. On systemd/NixOS every mount is shared. Your CLONE_NEWNS child copies those shared groups, so every mount() the container makes at rootfs/* propagates back into the host namespace. The host now has 11 leaked proc mounts, 5 devpts, and rootfs/sys — all stacked (e.g. rootfs/proc chained 677→729→763→..., each with its own superblock).
2. EBUSY: the first run mounted sysfs fine and it leaked to the host as rootfs/sys (superblock 0:23, same one as the host's /sys). Every later container's fresh namespace is a copy of the host, so it already contains a sysfs at rootfs/sys → remounting sysfs there → EBUSY. (proc/devpts/shm keep working because they allow stacking.)
3. The hang: run 1's child (PID 127657, orphaned after you Ctrl+C'd the parent) is still alive, spinning at ~97% CPU in kernel space, stuck during/after the sysfs mount — all 5 "Trying to Mount" lines printed, then nothing; it never reached the cgroup code or execve.
Cleanup now (needs sudo — the process is still burning CPU):
sudo kill 127657
# unmount the leaks (they're stacked, so repeat until "not mounted"):
for m in proc dev/pts dev/shm dev sys; do
  while sudo umount -l "bundle/rootfs/$m" 2>/dev/null; do :; done
done
The fix — runc's mount("", "/", "", MS_REC|MS_SLAVE, NULL) in the child before any mounts (src/main.zig, right after chroot/chdir):
const r = linux.mount("", "/", "", linux.MS.REC | linux.MS.SLAVE, 0);
_ = linux.errno(r);
That turns the inherited mounts into slaves so container mounts never propagate back to the host. With that, the sysfs EBUSY and the hang should both disappear.
