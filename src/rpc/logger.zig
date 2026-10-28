// Zig JR
// A Zig based JSON-RPC 2.0 library.
// Copyright (C) 2025 William W. Wong. All rights reserved.
// (williamw520@gmail.com)
//
// MIT License.  See the LICENSE file.
//

const std = @import("std");
const Allocator = std.mem.Allocator;


inline fn TPtr(T: type, opaque_ptr: *anyopaque) T {
    return @as(T, @ptrCast(@alignCast(opaque_ptr)));
}

/// Logger interface
pub const Logger = struct {
    impl:       *anyopaque,
    i_start:    *const fn(impl: *anyopaque, message: []const u8) void,
    i_log:      *const fn(impl: *anyopaque, source: [] const u8, operation: []const u8, message: []const u8) void,
    i_stop:     *const fn(impl: *anyopaque, message: []const u8) void,

    // The implementation must have these methods.
    pub fn start(self: @This(), message: []const u8) void {
        self.i_start(self.impl, message);
    }

    pub fn log(self: @This(), source: [] const u8, operation: []const u8, message: []const u8) void {
        self.i_log(self.impl, source, operation, message);
    }

    pub fn stop(self: @This(), message: []const u8) void {
        self.i_stop(self.impl, message);
    }

    // Interface is implemented by the 'impl_obj' object.
    pub fn implBy(impl_obj: anytype) Logger {
        const IT = @TypeOf(impl_obj);

        const Delegate = struct {
            fn start(impl: *anyopaque, message: []const u8) void {
                TPtr(IT, impl).start(message);
            }

            fn log(impl: *anyopaque, source: [] const u8, operation: []const u8, message: []const u8) void {
                TPtr(IT, impl).log(source, operation, message);
            }

            fn stop(impl: *anyopaque, message: []const u8) void {
                TPtr(IT, impl).stop(message);
            }
        };

        return .{
            .impl = impl_obj,
            .i_start = Delegate.start,
            .i_log = Delegate.log,
            .i_stop = Delegate.stop,
        };
    }

};


/// A nop logger that implements the Logger interface; can be passed to the stream options.logger.
pub const NopLogger = struct {
    pub fn start(_: @This(), _: []const u8) void {}
    pub fn log(_: @This(), _: []const u8, _: []const u8, _: []const u8) void {}
    pub fn stop(_: @This(), _: []const u8) void {}

    /// Return a Logger interface for this DbgLogger.
    pub fn asLogger(self: *NopLogger) Logger {
        return Logger.implBy(self);
    }
};

var nopLogger = NopLogger{};


/// A logger that prints to std.dbg, implemented the Logger interface.
pub const DbgLogger = struct {
    pub fn start(_: *DbgLogger, message: []const u8) void {
        std.debug.print("{s}\n", .{message});
    }

    pub fn log(_: *DbgLogger, source: []const u8, operation: []const u8, message: []const u8) void {
        std.debug.print("[{s}] {s} - {s}\n", .{source, operation, message});
    }

    pub fn stop(_: *DbgLogger, message: []const u8) void {
        std.debug.print("{s}\n", .{message});
    }

    /// Return a Logger interface for this DbgLogger.
    pub fn asLogger(self: *DbgLogger) Logger {
        return Logger.implBy(self);
    }
    
};


/// A logger that logs to file, implemented the Logger interface.
///
/// The logger owns the opened file and appends each formatted line at the
/// current end of the file. It uses a single-threaded `std.Io.Threaded`
/// instance internally so callers do not have to supply a `std.Io`.
pub const FileLogger = struct {
    alloc: Allocator,
    io_impl: std.Io.Threaded = .init_single_threaded,
    count: usize = 0,
    file: std.Io.File,
    position: u64,

    /// Create a FileLogger to log to the file at 'file_path'.
    /// An existing file is opened without truncation and appended to.
    pub fn init(alloc: Allocator, file_path: []const u8) !FileLogger {
        var self: FileLogger = .{
            .alloc = alloc,
            .file = undefined,
            .position = 0,
        };
        const io = self.io_impl.io();
        self.file = try std.Io.Dir.cwd().createFile(io, file_path, .{ .truncate = false });
        errdefer self.file.close(io);
        self.position = try self.file.length(io);
        return self;
    }

    pub fn deinit(self: *FileLogger) void {
        self.file.close(self.io_impl.io());
    }

    pub fn start(self: *FileLogger, message: []const u8) void {
        const ts_sec = std.time.timestamp();
        self.writeFormatted("Timestamp {d} - {s}\n", .{ts_sec, message});
    }

    pub fn log(self: *FileLogger, source: []const u8, operation: []const u8, message: []const u8) void {
        self.count += 1;
        self.writeFormatted("{}: [{s}] {s} - {s}\n", .{self.count, source, operation, message});
    }
    
    pub fn stop(self: *FileLogger, message: []const u8) void {
        const ts_sec = std.time.timestamp();
        self.writeFormatted("Timestamp {d} - {s}\n\n", .{ts_sec, message});
    }

    /// Formats one line and appends it at `position`. Formatting and write
    /// failures are reported to stderr because the Logger interface is void.
    fn writeFormatted(self: *FileLogger, comptime fmt: []const u8, args: anytype) void {
        const line = std.fmt.allocPrint(self.alloc, fmt, args) catch |err| {
            std.debug.print("Error while formatting a log line. {any}\n", .{err});
            return;
        };
        defer self.alloc.free(line);
        self.writeAll(line);
    }

    /// Writes all of `data` at the current position, advancing it only by
    /// the bytes actually written. A zero-progress write is treated as an
    /// error rather than retried forever.
    fn writeAll(self: *FileLogger, data: []const u8) void {
        const io = self.io_impl.io();
        var sent: usize = 0;
        while (sent < data.len) {
            const offset = self.position + @as(u64, @intCast(sent));
            const written = self.file.writePositional(io, &.{data[sent..]}, offset) catch |err| {
                std.debug.print("Error while writing a log line. {any}\n", .{err});
                return;
            };
            if (written == 0) {
                std.debug.print("Error while writing a log line: no progress.\n", .{});
                return;
            }
            sent += written;
        }
        self.position += @as(u64, @intCast(sent));
    }

    /// Return a Logger interface for this FileLogger.
    pub fn asLogger(self: *FileLogger) Logger {
        return Logger.implBy(self);
    }

};


