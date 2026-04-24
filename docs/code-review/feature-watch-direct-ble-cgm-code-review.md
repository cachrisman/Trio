# Watch direct BLE G7 observer alignment — Code review (working tree vs `HEAD`)

**Trio worktree · branch:** `feature/watch-direct-ble-cgm` · **HEAD:** `98b014275`  
**Generated:** 2026-04-14 08:46 CEST  
**Commands:** `git diff --stat HEAD -- 'Trio Watch App Extension/G7DirectBLEManager.swift' 'Trio Watch App Extension/WatchState.swift'` · `git diff HEAD -- 'Trio Watch App Extension/G7DirectBLEManager.swift' 'Trio Watch App Extension/WatchState.swift'`  
**Note:** Transient scratch for reviewers; regenerate after local commits or edits. Initiative traceability remains the design / implementation plan / instrumentation docs under `Trio-dev/docs/in-progress/watch-direct-ble-cgm/`.

## Patch: `feature/watch-direct-ble-cgm` — launch-filter persistence + connect isolation delta

**2 files changed, +42 / -7** (working tree vs `HEAD` `98b014275`)

### `G7DirectBLEManager.swift`
- Adds `g7_ble_retrieve_result count=<n> filter_armed=<bool>` so Better Stack can distinguish “retrieval ran and returned zero” from “retrieval path never produced an attach”.
- Temporarily disables `WKExtendedRuntimeSession` start at connect time and foreground renewal for the current isolation build, replacing those starts with `g7_ble_ext_session_skipped reason=isolation_test`.
- Keeps the rest of the direct-BLE observer path intact so the next hardware run isolates the connect-time/runtime-session variable rather than changing auth or GATT sequencing again.

### `WatchState.swift`
- Persists the phone-provided active G7 peripheral name into the existing App Group `UserDefaults` using the resolved project App Group ID instead of introducing a new suite constant.
- Loads that cached peripheral name during `WatchState` init so the watch can arm the active-sensor filter before the first post-launch WC payload arrives.
- Leaves the existing WC update path as the source of truth so a new sensor name or a cleared name overwrites the cache naturally.

## Unified diff (verbatim: `git diff HEAD -- 'Trio Watch App Extension/G7DirectBLEManager.swift' 'Trio Watch App Extension/WatchState.swift'`)

```diff
diff --git a/Trio Watch App Extension/G7DirectBLEManager.swift b/Trio Watch App Extension/G7DirectBLEManager.swift
index 70a55f749..fc40a20af 100644
--- a/Trio Watch App Extension/G7DirectBLEManager.swift	
+++ b/Trio Watch App Extension/G7DirectBLEManager.swift	
@@ -252,10 +252,16 @@ final class G7DirectBLEManager: NSObject {
         resetSessionState()
         central.stopScan()
 
-        _ = emitAttachBlockedIfNeeded(source: "scan_start")
+        let retrievedPeripherals = central.retrieveConnectedPeripherals(withServices: [G7BLEUUID.advertisement])
+        Task {
+            await logG7Ble(
+                "event=g7_ble_retrieve_result count=\(retrievedPeripherals.count) filter_armed=\(hasActivePeripheralNameFilter)"
+            )
+        }
 
         // Attach to a G7 already connected at the watchOS level (e.g. Dexcom Watch app) without waiting for an advertisement.
-        if let retrieved = central.retrieveConnectedPeripherals(withServices: [G7BLEUUID.advertisement]).first {
+        _ = emitAttachBlockedIfNeeded(source: "scan_start")
+        if let retrieved = retrievedPeripherals.first {
             let name = retrieved.name ?? "unknown"
             updateLastSeenPeripheral(name: name, rssi: nil)
             if hasActivePeripheralNameFilter {
@@ -359,10 +365,8 @@ final class G7DirectBLEManager: NSObject {
         default:
             return
         }
-        beginExtendedRuntimeSession()
-        Task {
-            await logG7Ble("event=g7_ble_ext_session_renewal reason=\(reason) away_s=\(awaySeconds)")
-        }
+        // TODO: WKExtendedRuntimeSession disabled for didConnect isolation test — re-enable after validating.
+        logExtendedRuntimeSessionSkipped(source: reason, awaySeconds: awaySeconds)
     }
 
     // MARK: - Session reset
@@ -795,7 +799,8 @@ final class G7DirectBLEManager: NSObject {
         lastSeenPeripheralRSSI = rssi
         lastSeenPeripheralAt = now
         emitStageIfChanged("connecting")
-        beginExtendedRuntimeSession()
+        // TODO: WKExtendedRuntimeSession disabled for didConnect isolation test — re-enable after validating.
+        logExtendedRuntimeSessionSkipped(source: "connect")
         Task {
             if let source {
                 await logG7Ble("event=g7_ble_peripheral_discovered peripheral=\(name) rssi=\(rssi) source=\(source)")
@@ -1170,6 +1175,16 @@ private extension Data {
 }
 
 private extension G7DirectBLEManager {
+    func logExtendedRuntimeSessionSkipped(source: String, awaySeconds: Int? = nil) {
+        Task {
+            var message = "event=g7_ble_ext_session_skipped reason=isolation_test source=\(source)"
+            if let awaySeconds {
+                message += " away_s=\(awaySeconds)"
+            }
+            await logG7Ble(message)
+        }
+    }
+
     func setActivePeripheralName(_ activePeripheralName: String?, logIfChanged: Bool) -> Bool {
         let normalized = Self.normalizedPeripheralName(activePeripheralName)
         let changed = self.activePeripheralName != normalized
diff --git a/Trio Watch App Extension/WatchState.swift b/Trio Watch App Extension/WatchState.swift
index ffc44536c..f063d4980 100644
--- a/Trio Watch App Extension/WatchState.swift	
+++ b/Trio Watch App Extension/WatchState.swift	
@@ -40,6 +40,7 @@ enum WatchCurrentDataSource {
 
 @Observable final class WatchState: NSObject, WCSessionDelegate {
     static let shared = WatchState()
+    private static let activeG7PeripheralNameAppGroupKey = "g7_active_peripheral_name"
 
     // MARK: - WatchConnectivity
 
@@ -206,6 +207,7 @@ enum WatchCurrentDataSource {
 
     override init() {
         super.init()
+        loadCachedActiveG7PeripheralName()
         setupSession()
 
         DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
@@ -1620,9 +1622,27 @@ enum WatchCurrentDataSource {
         let trimmed = (payload[WatchMessageKeys.activeG7PeripheralName] as? String)?
             .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
         phoneActiveG7PeripheralName = trimmed.isEmpty ? nil : trimmed
+        if let suiteName = TrioComplicationDataStore.shared.appGroupID,
+           let suite = UserDefaults(suiteName: suiteName)
+        {
+            if let name = phoneActiveG7PeripheralName {
+                suite.set(name, forKey: WatchState.activeG7PeripheralNameAppGroupKey)
+            } else {
+                suite.removeObject(forKey: WatchState.activeG7PeripheralNameAppGroupKey)
+            }
+        }
         g7DirectBLEManager.updatePhoneActivePeripheralName(phoneActiveG7PeripheralName)
     }
 
+    private func loadCachedActiveG7PeripheralName() {
+        guard let suiteName = TrioComplicationDataStore.shared.appGroupID,
+              let suite = UserDefaults(suiteName: suiteName)
+        else { return }
+        let cached = suite.string(forKey: WatchState.activeG7PeripheralNameAppGroupKey)
+        let trimmed = cached?.trimmingCharacters(in: .whitespacesAndNewlines)
+        phoneActiveG7PeripheralName = (trimmed?.isEmpty == false) ? trimmed : nil
+    }
+
     private func scheduleUIUpdate(
         with newData: [String: Any],
         fromUserInfo: Bool = false,
```
