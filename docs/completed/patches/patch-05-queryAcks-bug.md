# Bug: queryAcks envelope rejected by iPhone-side guard (patch 05)

## Summary

The `queryAcks` protocol between Watch and iPhone is unreachable due to a guard mismatch in `AppleWatchManager.swift`. Pending payload retries (including complication drain files) can stall indefinitely.

## Affected files

- `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` (iPhone side)
- `Trio Watch App Extension/WatchLogger.swift` (Watch side)
- Patch: `patches/05-watch-error-reporting.patch`

## Root cause

The Watch sends a `queryAcks` envelope with `type` and `pendingIds` but no `payloadId`:

```swift
// WatchLogger.swift, flushPersistedLogs()
let queryEnvelope: [String: Any] = [
    "type": "queryAcks",
    "pendingIds": pendingIds
]
```

The iPhone receives it in the replyHandler variant of `didReceiveMessage`, which guards on both `type` AND `payloadId`:

```swift
// AppleWatchManager.swift, session(_:didReceiveMessage:replyHandler:)
guard let type = message["type"] as? String,
      let payloadId = message["payloadId"] as? String else {
    self.session(session, didReceiveMessage: message)
    replyHandler([:])
    return
}
```

Since `queryAcks` has no `payloadId`, the guard fails. The message falls through to the legacy handler with an empty reply. The actual `queryAcks` handler (which exists and is correct) is never reached.

## Impact

- Watch-side `resendPendingPayloads()` is only called from within the `batchAck` reply handler, which never fires.
- Pending payload files accumulate without retry until the watch app is relaunched and `flushPersistedLogs` tries again (same failure).
- The `errorHandler` path does call `resendPendingPayloads`, but only on network errors, not on the empty-reply case.

## High-level fix

Split the iPhone-side guard so `type` is checked first, `queryAcks` is handled before the `payloadId` requirement:

```swift
guard let type = message["type"] as? String else {
    self.session(session, didReceiveMessage: message)
    replyHandler([:])
    return
}

// Handle queryAcks (no payloadId needed)
if type == "queryAcks" {
    if let pendingIds = message["pendingIds"] as? [String] {
        let ackIds = getAcknowledgedIds(from: pendingIds)
        replyHandler(["type": "batchAck", "ackIds": ackIds])
    } else {
        replyHandler([:])
    }
    return
}

guard let payloadId = message["payloadId"] as? String else {
    self.session(session, didReceiveMessage: message)
    replyHandler([:])
    return
}

// ... rest of dedup + handling logic unchanged
```

## When to fix

This should be fixed in patch 05 (`watch-error-reporting`) and the patch regenerated. It is independent of the Step 3 complication logging work (patch 06).
