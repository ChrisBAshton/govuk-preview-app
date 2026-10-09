# Dispatch a running preview's own hostname straight to its container,
# before this app's own routing (but see below on why not before Warden).
#
# Explicit require (rather than relying on autoloading): this app's
# initializer load order runs before the main Zeitwerk autoloader is set up,
# so a bare `HostRouter` constant reference here raises NameError.
require Rails.root.join("app/middleware/host_router")

# After Warden::Manager, not at position 0: HostRouter itself now requires a
# real Preview App Signon session before proxying to a preview (see its own
# call method) - every previewed app gets this gate, including ones with no
# login of their own (e.g. Frontend), which is the whole reason it lives
# here rather than relying on each app's own gds-sso. That means it needs
# env["warden"] already populated by the time it runs, which only happens
# for middleware positioned after Warden::Manager.
Rails.application.config.middleware.insert_after Warden::Manager, HostRouter
