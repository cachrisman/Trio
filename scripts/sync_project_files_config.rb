# frozen_string_literal: true

# Central place for sync_project_files.rb target definitions.
# Keep this file free of build-time logic; only configuration belongs here.

module SyncProjectFilesConfig
  # Map target names to the globs that should feed them.
  TARGET_GLOBS = {
    "Trio" => [
      "Trio/Sources/**/*.{swift,m,mm}",
      "Trio Watch Shared/ComplicationLogBuffer.swift",
      "Trio Watch Shared/TrioComplicationDataStore.swift"
    ],
    "Trio Watch App" => [
      "Trio Watch App Extension/**/*.{swift,m,mm}",
      "Trio/Sources/Models/NotificationIdentifiers.swift",
      "Trio/Sources/Models/WatchMessageKeys.swift",
      "Trio Watch Shared/ComplicationLogBuffer.swift",
      "Trio Watch Shared/TrioComplicationDataStore.swift"
    ],
    "Trio Watch Complication Extension" => [
      "Trio Watch Complication/**/*.{swift,m,mm}",
      "Trio Watch Shared/ComplicationLogBuffer.swift",
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
    "Trio Watch App" => {
      # Ensure the watch targets always have a resolved App Group build setting available for
      # Info.plist and entitlement substitution. Some files use $(APP_GROUP_ID) and others
      # reference $(TRIO_APP_GROUP_ID); standardize the effective value here.
      "APP_GROUP_ID" => "$(TRIO_APP_GROUP_ID)",
      # Watch app uses a generated Info.plist; inject AppGroupID so runtime lookups succeed.
      "INFOPLIST_KEY_AppGroupID" => "$(TRIO_APP_GROUP_ID)",
      # Force Xcode to merge keys from a real Info.plist file as well. This is required because
      # the watch app’s generated Info.plist output has not been including custom keys like AppGroupID.
      "INFOPLIST_FILE" => "Trio Watch App/Info.plist",
      # Ensure the watch app has App Group entitlement so containerURL(...) is non-nil.
      #
      # Important: also set the sdk-qualified key to override any project-level
      # CODE_SIGN_ENTITLEMENTS[sdk=watchos*] defaults (which would otherwise win).
      "CODE_SIGN_ENTITLEMENTS" => "Trio Watch App/TrioWatchApp.entitlements",
      "CODE_SIGN_ENTITLEMENTS[sdk=watchos*]" => "Trio Watch App/TrioWatchApp.entitlements"
    },
    "Trio Watch Complication Extension" => {
      # Ensure the watch targets always have a resolved App Group build setting available for
      # Info.plist and entitlement substitution.
      "APP_GROUP_ID" => "$(TRIO_APP_GROUP_ID)",
      # Widget extension uses a generated Info.plist; inject AppGroupID so runtime lookups succeed.
      "INFOPLIST_KEY_AppGroupID" => "$(TRIO_APP_GROUP_ID)",
      # Ensure the complication extension has App Group entitlement so containerURL(...) is non-nil.
      #
      # Important: also set the sdk-qualified key to override any project-level
      # CODE_SIGN_ENTITLEMENTS[sdk=watchos*] defaults (which would otherwise win).
      "CODE_SIGN_ENTITLEMENTS" => "Trio Watch Complication/TrioWatchComplication.entitlements",
      "CODE_SIGN_ENTITLEMENTS[sdk=watchos*]" => "Trio Watch Complication/TrioWatchComplication.entitlements"
    }
  }.freeze
end
