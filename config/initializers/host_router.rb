# Dispatch a running preview's own hostname straight to its container,
# before host authorization (only actually in the stack when config.hosts
# is non-empty - e.g. not in test), Warden, or any of this app's own
# routing/auth. Inserted at position 0 rather than anchored to any one of
# those, so this doesn't depend on any of them being present in every
# environment - learned the hard way: an earlier version of this inserted
# after Warden::Manager instead, which also (incidentally, not
# intentionally) put it after ActionDispatch::HostAuthorization, since
# that runs before Warden in Rails' own default stack.
#
# HostRouter's own auth gate (see its call method) doesn't actually need
# Warden for this - env["warden"] would simply be absent here, which its
# own check already treats as "not authenticated" safely. The cookie it
# checks instead is read straight off the raw Cookie header (Rack::Request
# parses that itself), so it works regardless of where in the stack this
# runs.
#
# Explicit require (rather than relying on autoloading): this app's
# initializer load order runs before the main Zeitwerk autoloader is set up,
# so a bare `HostRouter` constant reference here raises NameError.
require Rails.root.join("app/middleware/host_router")

Rails.application.config.middleware.insert_before 0, HostRouter
