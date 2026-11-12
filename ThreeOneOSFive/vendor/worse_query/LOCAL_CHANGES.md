# Local changes

Upstream: forcequitOS/worse_query, commit in UPSTREAM_COMMIT.

- Replace the unavailable public-SDK xpc/xpc.h import with runtime lookup of
  xpc_string_create and xpc_release; explicitly release the XPC identifier.
- Free the container query and clean up after symlink creation fails.

The primitive's query classes, part, flags, token handling and supported target
behavior are otherwise unchanged. App Group cache preservation, serialization,
version gating, grant lifetime, and target validation live in FFWorseQuery.m
and the surrounding application.
