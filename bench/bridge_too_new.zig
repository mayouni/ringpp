//! An engine built for a host LATER than this one: it declares an ABI version above what the runtime speaks, so
//! LoadLib refuses it by name (R46, "needs a newer host") instead of letting it read the vtable past its end.
//!
//!     zig build-lib -dynamic -OReleaseFast -lc bench/bridge_too_new.zig --name rppnew
const std = @import("std");

const HostApi = extern struct { register: *const anyopaque };

export fn rpp_init(h: *const HostApi) callconv(.c) c_int {
    _ = h;
    return 0;
}

export fn rpp_abi_version() callconv(.c) u32 {
    return 99;
}
