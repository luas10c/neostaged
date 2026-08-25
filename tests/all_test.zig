//! Test root for `zig build test`. Each suite lives in its own file and
//! pulls the implementation modules in as named imports provided by the
//! build script (`ansi`, `glob`, `json5`, `spinner`, `summary`). The NAPI
//! entry point (addon.zig) stays excluded because its node symbols only
//! resolve inside Node itself.
comptime {
    _ = @import("ansi_test.zig");
    _ = @import("glob_test.zig");
    _ = @import("json5_test.zig");
    _ = @import("spinner_test.zig");
    _ = @import("summary_test.zig");
}
