//!
//! the zig part of std, gets built as its own dylib into the std dir
//!

const revo = @import("revo");

const extension = revo.extension;

pub export const revo_std_base64 = extension.bindingsFor(@import("base64.zig").Impl);
pub export const revo_std_compress = extension.bindingsFor(@import("compress.zig").Impl);
pub export const revo_std_re = extension.bindingsFor(@import("re.zig").Impl);
pub export const revo_std_csv = extension.bindingsFor(@import("csv.zig").Impl);
pub export const revo_std_uri = extension.bindingsFor(@import("uri.zig").Impl);

test {
    _ = @import("base64.zig");
    _ = @import("compress.zig");
    _ = @import("csv.zig");
    _ = @import("re.zig");
    _ = @import("uri.zig");
}
