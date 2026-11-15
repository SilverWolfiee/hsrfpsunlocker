const std = @import("std");

const allocator = std.heap.page_allocator;
const fs = std.fs;

const registry_key=  "\"GraphicsSettings_Model_h2986158309\"=hex:";
const fps_header = "7b,22,46,50,53,22,3a,";


const Registry = struct{
    fps:u16,
    starting:usize,
    len:usize,
};


pub fn fpsHex(fps:u16)![]const u8{
    return switch(fps){
        30 => "33,30,",
        60 => "36,30,",
        120 => "31,32,30,",
        else => error.InvalidFPS,
    };
}
pub fn readFile(path: []const u8) ![]u8{
    return fs.cwd().readFileAlloc(
        allocator,
        path,
        4*1024*1024,
    );
}

pub fn findRegistry(data: []const u8)?Registry{
    if(std.mem.indexOf(u8,data,"Cognosphere")==null){
        return null;
    }
    const keypos = std.mem.indexOf(
        u8,data,registry_key,
    ) orelse return null;
    const start = keypos + registry_key.len;
    if(!std.mem.startsWith(u8,data[start..],fps_header,)){
        return null;
    }
    const starting = start+fps_header.len;
    const values = [_]u16{30,60,120};
    for (values)|fps|{
        const hex = fpsHex(fps) catch unreachable;
        if(std.mem.startsWith(u8,data[starting..], hex)){
            return .{
                .fps=fps,
                .starting=starting,
                .len=hex.len,
            };
        }
    }
    return null;
}

fn scanPrefix(root: []const u8) !?[]u8 {
    const compatdata = try fs.path.join(
        allocator,
        &.{ root, "steamapps", "compatdata" },
    );
    defer allocator.free(compatdata);

    var dir = fs.cwd().openDir(
        compatdata,
        .{ .iterate = true },
    ) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();

    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;

        const path = try fs.path.join(
            allocator,
            &.{
                compatdata,
                entry.name,
                "pfx",
                "user.reg",
            },
        );

        const data = readFile(path) catch {
            allocator.free(path);
            continue;
        };
        defer allocator.free(data);

        if (findRegistry(data) != null) {
            return path;
        }

        allocator.free(path);
    }

    return null;
}
fn discover() !?[]u8 {
    const home = try std.process.getEnvVarOwned(
        allocator,
        "HOME",
    );
    defer allocator.free(home);

    const roots = [_][]const u8{
        ".local/share/Steam",
        ".steam/steam",
        ".var/app/com.valvesoftware.Steam/.local/share/Steam",
    };

    for (roots) |root| {
        const path = try fs.path.join(
            allocator,
            &.{ home, root },
        );
        defer allocator.free(path);

        if (try scanPrefix(path)) |found| {
            return found;
        }
    }

    return null;
}

fn ask(
    reader: *std.Io.Reader,
    prompt: []const u8,
) ![]const u8 {
    std.debug.print("{s}", .{prompt});

    const line = try reader.takeDelimiterExclusive('\n');

    return std.mem.trim(u8, line, " \t\r");
}

fn writeExclusive(
    path: []const u8,
    data: []const u8,
    mode: fs.File.Mode,
) !void {
    const file = try fs.cwd().createFile(path, .{
        .exclusive = true,
        .mode = mode,
    });

    defer file.close();

    try file.writeAll(data);
    try file.sync();
}

fn updateRegistry(
    path: []const u8,
    data: []const u8,
    reg: Registry,
    target: u16,
    backup: bool,
) !void {
    const hex = try fpsHex(target);

    const patched = try std.fmt.allocPrint(
        allocator,
        "{s}{s}{s}",
        .{
            data[0..reg.starting],
            hex,
            data[reg.starting + reg.len ..],
        },
    );
    defer allocator.free(patched);

  
    const verified = findRegistry(patched) orelse
        return error.VerificationFailed;

    if (verified.fps != target)
        return error.VerificationFailed;

    const original = try fs.cwd().openFile(path, .{});
    defer original.close();

    const stat = try original.stat();

    if (backup) {
        const bak = try std.fmt.allocPrint(
            allocator,
            "{s}.bak",
            .{path},
        );
        defer allocator.free(bak);

        try writeExclusive(bak, data, stat.mode);

        std.debug.print(
            "[+] Backup created: {s}\n",
            .{bak},
        );
    }

    const temp = try std.fmt.allocPrint(
        allocator,
        "{s}.fps-tmp",
        .{path},
    );
    defer allocator.free(temp);

    try writeExclusive(temp, patched, stat.mode);

    errdefer fs.cwd().deleteFile(temp) catch {};

    
    try fs.cwd().rename(temp, path);

    
    const result = try readFile(path);
    defer allocator.free(result);

    const final = findRegistry(result) orelse
        return error.VerificationFailed;

    if (final.fps != target)
        return error.VerificationFailed;
}


pub fn main()!void{
    std.debug.print("HSR FPS Unlocker\n", .{});
    var stdin_buffer:[1024]u8 = undefined;
    var stdin_reader = fs.File.stdin().reader(&stdin_buffer);
    const reader = &stdin_reader.interface;
    std.debug.print("Searching prefix\n", .{});
    const path = try discover() orelse {
        std.debug.print("Registry not found\n", .{});
        return ;
    };
    defer allocator.free(path);
    const data =try readFile(path);
    defer allocator.free(data);
    const reg = findRegistry(data) orelse {
        std.debug.print("Cannot find FPS settings\n", .{});
        return;
    };
    std.debug.print("Current FPS : {d}\n", .{reg.fps});
    std.debug.print(
        "\nSelect target FPS:\n" ++
            "  1. 30 FPS\n" ++
            "  2. 60 FPS\n" ++
            "  3. 120 FPS\n" ++
            "  0. Cancel\n",
        .{},
    );

    const choice = try ask(reader, "\n> ");

    const target: u16 = if (std.mem.eql(u8, choice, "1"))
        30
    else if (std.mem.eql(u8, choice, "2"))
        60
    else if (std.mem.eql(u8, choice, "3"))
        120
    else if (std.mem.eql(u8, choice, "0"))
        return
    else {
        std.debug.print("[-] Invalid option.\n", .{});
        return;
    };
    if(target==reg.fps){
        std.debug.print("Fps already {d}\n", .{reg.fps});
        return;
    }
    const rsp = try ask(
        reader,
        "Create Registry backup? [Y/n]"
    );
    const backup = rsp.len == 0 or 
        std.ascii.eqlIgnoreCase(rsp, "y") or
        std.ascii.eqlIgnoreCase(rsp, "yes");
    
    std.debug.print("Updating registry...\n", .{});
    updateRegistry(
        path,
        data,
        reg,
        target,
        backup,
    ) catch |err| {
        std.debug.print(
            "[-] Update failed: {s}\n",
            .{@errorName(err)},
        );
        return;
    };

    std.debug.print(
        "[+] FPS changed: {d} -> {d}\n" ++
            "[+] You can freely launch HSR.\n",
        .{ reg.fps, target },
    );

}