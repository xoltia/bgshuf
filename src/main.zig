const std = @import("std");
const c = @cImport(@cInclude("gio/gio.h"));
const clap = @import("clap");

fn gsettingsSetGnomeBackground(background: []const u8) !void {
    var background_z_buff: ["file://".len + std.os.linux.PATH_MAX + 1]u8 = undefined;
    const background_z = try std.fmt.bufPrintZ(&background_z_buff, "file://{s}", .{background});

    const g_settings_background = c.g_settings_new("org.gnome.desktop.background");
    defer c.g_object_unref(g_settings_background);

    const g_settings_screensaver = c.g_settings_new("org.gnome.desktop.screensaver");
    defer c.g_object_unref(g_settings_screensaver);

    if (c.g_settings_set_string(g_settings_background, "picture-uri", background_z) != 1)
        return error.GSettingsKeyNotWritable;
    if (c.g_settings_set_string(g_settings_background, "picture-uri-dark", background_z) != 1)
        return error.GSettingsKeyNotWritable;
    if (c.g_settings_set_string(g_settings_screensaver, "picture-uri", background_z) != 1)
        return error.GSettingsKeyNotWritable;

    c.g_settings_sync();
}

fn getDefaultWallpaperPaths(allocator: std.mem.Allocator) ![2][]const u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    // $XDG_DATA_HOME or ~/.local/share
    const share_path = std.process.getEnvVarOwned(allocator, "XDG_DATA_HOME") catch |err| blk: {
        if (err == error.EnvironmentVariableNotFound)
            break :blk try std.fs.path.join(allocator, &[_][]const u8{ home, ".local/share/backgrounds" });
        return err;
    };
    // ~/Pictures/Wallpapers
    const pictures_path = try std.fs.path.join(allocator, &[_][]const u8{ home, "Pictures/Wallpapers" });
    return [2][]u8{ share_path, pictures_path };
}

const WallpaperDir = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    dir: std.fs.Dir,

    const Self = @This();

    fn deinit(self: *Self) void {
        self.allocator.free(self.path);
        self.dir.close();
    }

    fn iterate(self: Self) ImageFileIterator {
        return .{ .iterator = self.dir.iterate(), .base_path = self.path };
    }

    const ImageFileIterator = struct {
        iterator: std.fs.Dir.Iterator,
        base_path: ?[]const u8 = null,
        path_buffer: [std.os.linux.PATH_MAX]u8 = undefined,

        const IMAGE_EXTENSIONS = &[_][]const u8{ ".png", ".jpg", ".jpeg" };

        fn reset(self: *ImageFileIterator) void {
            self.iterator.reset();
        }

        // Returns the next name of an image file in the directory.
        fn next(self: *@This()) !?[]const u8 {
            while (try self.iterator.next()) |entry| {
                if (entry.kind != .file)
                    continue;

                const ext = std.fs.path.extension(entry.name);
                for (IMAGE_EXTENSIONS) |img_ext| {
                    if (!std.ascii.eqlIgnoreCase(ext, img_ext))
                        continue;

                    if (self.base_path) |base| {
                        return try std.fmt.bufPrint(
                            &self.path_buffer,
                            "{s}/{s}",
                            .{ base, entry.name },
                        );
                    }

                    return entry.name;
                }
            }

            return null;
        }

        fn collect(self: *@This(), allocator: std.mem.Allocator) !OwnedStringList {
            var images = OwnedStringList{ .allocator = allocator };

            self.reset();
            while (try self.next()) |entry| {
                try images.append(entry);
            }

            return images;
        }

        const OwnedStringList = struct {
            allocator: std.mem.Allocator,
            list: std.ArrayListUnmanaged([]const u8) = std.ArrayListUnmanaged([]const u8){},

            fn deinit(self: *@This()) void {
                for (self.list.items) |item|
                    self.allocator.free(item);
                self.list.deinit(self.allocator);
            }

            fn append(self: *@This(), path: []const u8) !void {
                try self.list.append(self.allocator, try self.allocator.dupe(u8, path));
            }

            fn items(self: @This()) []const []const u8 {
                return self.list.items;
            }
        };
    };
};

fn openWallpaperDir(allocator: std.mem.Allocator, path: ?[]const u8) !WallpaperDir {
    if (path) |dir_path| {
        const dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        return .{
            .allocator = allocator,
            .path = try allocator.dupe(u8, dir_path),
            .dir = dir,
        };
    }

    const default_dirs = try getDefaultWallpaperPaths(allocator);
    defer {
        for (default_dirs) |dir_path|
            allocator.free(dir_path);
    }

    for (default_dirs) |dir_path| {
        const dir = std.fs.cwd().openDir(
            dir_path,
            .{ .iterate = true },
        ) catch |err|
            switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        return .{ .allocator = allocator, .path = try allocator.dupe(u8, dir_path), .dir = dir };
    }

    return error.DirNotFound;
}

fn setRandomWallpaperFromDir(allocator: std.mem.Allocator, dir_name: ?[]const u8) ![]const u8 {
    var wallpaper_folder = try openWallpaperDir(allocator, dir_name);
    defer wallpaper_folder.deinit();

    var iterator = wallpaper_folder.iterate();
    var images_list = try iterator.collect(allocator);
    defer images_list.deinit();
    const images = images_list.items();

    if (images.len == 0)
        return error.NoWallpapersFound;

    var prng = std.rand.DefaultPrng.init(@as(u64, @bitCast(std.time.milliTimestamp())));
    const rand = prng.random();
    const random_index = rand.uintLessThan(usize, images.len);
    const random_file_name = images[random_index];

    try gsettingsSetGnomeBackground(random_file_name);
    return allocator.dupe(u8, random_file_name);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-d, --directory <str>  Directory to search for files. Default is $HOME/.local/share/backgrounds or $HOME/Pictures/Wallpapers.
        \\-i, --interval  <u64>  Run continuously, changing the background every <u64> seconds.
    );

    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(stderr, err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try stderr.print("Usage: {s} [options]\n", .{res.exe_arg orelse "bgshuf"});
        try stderr.print("Set a random image file as the desktop background.\n\n", .{});
        try stderr.print("Options:\n", .{});
        return clap.help(stderr, clap.Help, &params, .{});
    }

    if (res.args.interval) |interval| {
        while (true) {
            const file_name = try setRandomWallpaperFromDir(allocator, res.args.directory);
            try stdout.writeAll(file_name);
            try stdout.writeByte('\n');
            allocator.free(file_name);
            std.time.sleep(interval * 1_000_000_000);
        }
    } else {
        const file_name = try setRandomWallpaperFromDir(allocator, res.args.directory);
        try stdout.writeAll(file_name);
        try stdout.writeByte('\n');
        allocator.free(file_name);
    }
}
