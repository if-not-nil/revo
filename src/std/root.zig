//!
//! the zig part of std, gets built as its own dylib into the std dir
//!

const revo = @import("revo");

const extension = revo.extension;

pub export const revo_std_uri = extension.bindingsFor(@import("uri.zig").Impl);

test {
    _ = @import("uri.zig");
}
