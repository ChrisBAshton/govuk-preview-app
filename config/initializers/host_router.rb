# Dispatch a running preview's own hostname straight to its container,
# before host authorization (only actually in the stack when config.hosts
# is non-empty - e.g. not in test) or any of this app's own routing/auth.
# Inserted at position 0 rather than anchored to ActionDispatch::HostAuthorization
# so this doesn't depend on that middleware being present in every environment.
#
# Explicit require (rather than relying on autoloading): this app's
# initializer load order runs before the main Zeitwerk autoloader is set up,
# so a bare `HostRouter` constant reference here raises NameError.
require Rails.root.join("app/middleware/host_router")

Rails.application.config.middleware.insert_before 0, HostRouter
