# Log Version Management

This document explains how the log version management system works in Trio.

## Overview

The `LogVersionManager` automatically rotates log folders when a new app version is installed. This ensures that logs from previous app versions are preserved while keeping the current logs folder clean.

## How It Works

### Version Detection

The system tracks app versions using:
- **AppDevVersion**: The development version (e.g., `0.6.0.4`)
- **Build Number**: The build number (e.g., `55`)

These are stored in UserDefaults and compared on each app launch.

### Log Rotation Process

When a version change is detected:

1. **Current logs folder** (`logs/`) is renamed to `logs.v{previousVersion}({previousBuild})`
   - Example: `logs.v0.6.0.4(55)`

2. **New logs folder** (`logs/`) is created for the current version

3. **Version info** is updated in UserDefaults

### Folder Structure

After rotation, the documents directory will contain:
```
Documents/
├── logs/                    # Current version logs
├── logs.v0.6.0.4(55)/      # Previous version logs
├── logs.v0.6.0.3(54)/      # Older version logs
└── ...
```

### Automatic Cleanup

The system automatically cleans up old rotated logs:
- **Frequency**: Once per week
- **Retention**: Keeps the 3 most recent rotated folders
- **Tracking**: Uses `PropertyPersistentFlags.shared.lastLogCleanupDate`

## Integration

The system is integrated into the app lifecycle via `AppDelegate.didFinishLaunchingWithOptions`:

```swift
LogVersionManager.shared.checkAndRotateLogsIfNeeded()
```

This ensures log rotation happens early in the app startup process, before any logging occurs.

## Manual Operations

### List Rotated Folders
```swift
let rotatedFolders = LogVersionManager.shared.getRotatedLogsFolders()
```

### Manual Cleanup
```swift
LogVersionManager.shared.cleanupOldRotatedLogs(keepCount: 5)
```

## Benefits

1. **Version Isolation**: Logs from different app versions are kept separate
2. **Debugging**: Easy to identify which logs belong to which version
3. **Storage Management**: Automatic cleanup prevents disk space issues
4. **Preservation**: Previous version logs are preserved for debugging
5. **Clean Current Logs**: Each version starts with a fresh log folder

## Example Scenarios

### First App Install
- No previous logs exist
- Current version info is stored
- No rotation occurs

### App Update (0.6.0.4 → 0.6.0.5)
- `logs/` → `logs.v0.6.0.4(55)/`
- New `logs/` created
- Version info updated

### Major Version Update (0.6.0.5 → 0.7.0.1)
- `logs/` → `logs.v0.6.0.5(56)/`
- New `logs/` created
- Version info updated

### Cleanup After Multiple Updates
- Keeps: `logs.v0.7.0.1(57)/`, `logs.v0.7.0.2(58)/`, `logs.v0.7.0.3(59)/`
- Removes: `logs.v0.6.0.4(55)/`, `logs.v0.6.0.5(56)/`


