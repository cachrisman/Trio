# frozen_string_literal: true

# Central place for sync_project_files.rb target definitions.
# Keep this file free of build-time logic; only configuration belongs here.

module SyncProjectFilesConfig
  # Map target names to the globs that should feed them.
  TARGET_GLOBS = {
    "Trio" => [
      "Trio/Sources/**/*.{swift,m,mm}",
      "Trio Watch Shared/TrioComplicationDataStore.swift"
    ],
    "Trio Watch App" => [
      "Trio Watch App Extension/**/*.{swift,m,mm}",
      "Trio/Sources/Models/NotificationIdentifiers.swift",
      "Trio/Sources/Models/WatchMessageKeys.swift",
      "Trio Watch Shared/TrioComplicationDataStore.swift"
    ],
    "Trio Watch Complication Extension" => [
      "Trio Watch Complication/**/*.{swift,m,mm}",
      "Trio Watch Shared/TrioComplicationDataStore.swift"
    ],
    "LiveActivityExtension" => ["LiveActivity/**/*.{swift,m,mm}"]
  }.freeze

  # Map target names to file globs that should be excluded from the target.
  TARGET_EXCLUDE_GLOBS = {}.freeze

  # Map target names to basename preferences for collisions.
  # Example:
  # "Trio" => { "Color+Extensions.swift" => "Trio/Sources/Helpers/Color+Extensions.swift" }
  TARGET_BASENAME_PREFERENCES = {}.freeze

  # Map target names to resource file globs
  TARGET_RESOURCE_GLOBS = {}.freeze

  # Map target names to package dependencies (package name => product name)
  TARGET_PACKAGE_DEPS = {
  }.freeze

  # Map target names to required build settings (setting_key => setting_value)
  TARGET_BUILD_SETTINGS = {
    "Trio Watch Complication Extension" => {
      "INFOPLIST_KEY_AppGroupID" => "$(TRIO_APP_GROUP_ID)"
    }
  }.freeze
end
