# Trio Watch Data Update Testing Protocol

## Overview
This document outlines comprehensive testing procedures to verify all data update paths to the Apple Watch in the Trio app. The testing covers both manual verification steps and automated testing approaches.

## Data Update Paths Identified

### 1. **WatchConnectivity Message Path (Foreground)**
- **Trigger**: iPhone app sends data when watch is reachable (foreground)
- **Method**: `session.sendMessage()` in `BaseWatchManager.sendDataToWatch()`
- **Data Flow**: iPhone → Watch App → WatchState → Complication

### 2. **WatchConnectivity UserInfo Path (Background)**
- **Trigger**: iPhone app sends data when watch is not reachable (background)
- **Method**: `session.transferUserInfo()` in `BaseWatchManager.sendDataToWatch()`
- **Data Flow**: iPhone → Watch App → TrioComplicationDataStore → Complication

### 3. **Background Refresh Path**
- **Trigger**: System-initiated background refresh
- **Method**: `WKApplicationRefreshBackgroundTask` in `ExtensionDelegate`
- **Data Flow**: System → ExtensionDelegate → WatchState → Complication

### 4. **App Activation Path**
- **Trigger**: User raises wrist or opens watch app
- **Method**: `applicationDidBecomeActive()` in `ExtensionDelegate`
- **Data Flow**: System → ExtensionDelegate → WatchState → Complication

### 5. **Manual Request Path**
- **Trigger**: Watch requests update from iPhone
- **Method**: `requestWatchUpdate` message from watch
- **Data Flow**: Watch → iPhone → BaseWatchManager → Watch

## Manual Testing Protocol

### Prerequisites
1. **iPhone Setup**:
   - Ensure iPhone has latest Trio app installed
   - Verify WatchConnectivity is working (check in iPhone Settings > General > Apple Watch)
   - Enable debug logging in Trio app

2. **Watch Setup**:
   - Ensure Apple Watch has Trio app installed
   - Add Trio complication to watch face (both corner and circular)
   - Enable watch app logging

3. **Test Data**:
   - Have glucose data flowing (CGM connected)
   - Have some override presets configured
   - Have some temp target presets configured

### Test Scenarios

#### Scenario 1: Foreground Data Updates
**Objective**: Test WatchConnectivity message path when watch is in foreground

**Steps**:
1. Open Trio app on iPhone
2. Open Trio app on Apple Watch (keep in foreground)
3. Wait for new glucose reading or trigger a data change
4. Verify data appears on watch within 5 seconds

**Expected Results**:
- Watch app shows updated glucose, trend, delta
- Complication updates immediately
- Watch logs show: `"📤 Sending via sendMessage (foreground)"`

**Verification Points**:
- [ ] Glucose value matches iPhone
- [ ] Trend arrow is correct
- [ ] Delta value is correct
- [ ] Complication updates on watch face
- [ ] No error messages in logs

#### Scenario 2: Background Data Updates
**Objective**: Test WatchConnectivity userInfo path when watch is in background

**Steps**:
1. Open Trio app on iPhone
2. Close Trio app on Apple Watch (put in background)
3. Wait for new glucose reading or trigger a data change
4. Check complication on watch face after 1-2 minutes

**Expected Results**:
- Complication updates within 2 minutes
- Data persists when watch app is reopened

**Verification Points**:
- [ ] Complication shows updated glucose
- [ ] Complication shows correct trend
- [ ] Complication shows correct delta
- [ ] iPhone logs show: `"📤 Sending via transferUserInfo (background)"`

#### Scenario 3: Background Refresh Updates
**Objective**: Test system-initiated background refresh

**Steps**:
1. Put watch in background for 5+ minutes
2. Wait for system background refresh (check logs)
3. Verify complication updates

**Expected Results**:
- Background refresh occurs every 5 minutes (when reachable) or 15 minutes (when not reachable)
- Complication updates with latest data

**Verification Points**:
- [ ] Watch logs show: `"⌚️ Background refresh triggered"`
- [ ] Complication updates with current data
- [ ] Timeline reload occurs

#### Scenario 4: App Activation Updates
**Objective**: Test updates when user activates watch app

**Steps**:
1. Put watch in background for several minutes
2. Raise wrist or tap to open Trio app
3. Verify immediate data update

**Expected Results**:
- App shows latest data immediately
- Complication updates
- Timeline reload occurs

**Verification Points**:
- [ ] Watch logs show: `"⌚️ Watch app became active"`
- [ ] App shows current glucose data
- [ ] Complication updates
- [ ] No stale data displayed

#### Scenario 5: Manual Update Requests
**Objective**: Test watch-initiated update requests

**Steps**:
1. Put watch in background
2. Force close watch app
3. Open watch app
4. Pull down to refresh (if available) or wait for automatic request

**Expected Results**:
- Watch requests update from iPhone
- iPhone sends latest data
- Watch updates with current information

**Verification Points**:
- [ ] iPhone logs show: `"📱 Watch requested watch state data update"`
- [ ] Watch receives and displays updated data
- [ ] Complication updates

#### Scenario 6: Treatment Acknowledgment Flow
**Objective**: Test bidirectional communication for treatments

**Steps**:
1. Open Trio app on watch
2. Enter carbs or bolus
3. Verify acknowledgment messages

**Expected Results**:
- Treatment is processed on iPhone
- Acknowledgment is sent back to watch
- Watch shows success/failure message

**Verification Points**:
- [ ] Treatment appears in iPhone app
- [ ] Watch shows acknowledgment banner
- [ ] Success/failure message is appropriate

#### Scenario 7: Override and Temp Target Updates
**Objective**: Test override and temp target data flow

**Steps**:
1. Activate an override from iPhone
2. Verify watch receives override data
3. Activate temp target from iPhone
4. Verify watch receives temp target data

**Expected Results**:
- Watch shows updated override presets
- Watch shows updated temp target presets
- Complication reflects current state

**Verification Points**:
- [ ] Override presets list updates on watch
- [ ] Temp target presets list updates on watch
- [ ] Complication shows appropriate state

#### Scenario 8: Error Handling and Fallbacks
**Objective**: Test error scenarios and fallback behavior

**Steps**:
1. Disconnect iPhone from watch temporarily
2. Send data from iPhone
3. Reconnect and verify recovery

**Expected Results**:
- App handles disconnection gracefully
- Data syncs when reconnected
- Fallback data is shown when needed

**Verification Points**:
- [ ] App doesn't crash on disconnection
- [ ] Fallback data (--) is shown appropriately
- [ ] Data syncs when reconnected

### Data Verification Checklist

For each test scenario, verify these data points:

#### Core Glucose Data
- [ ] `currentGlucose`: Matches iPhone value
- [ ] `trend`: Correct arrow symbol
- [ ] `delta`: Correct change value
- [ ] `currentGlucoseColorString`: Appropriate color

#### Additional Data
- [ ] `iob`: Insulin on board value
- [ ] `cob`: Carbs on board value
- [ ] `lastLoopTime`: Time since last loop
- [ ] `glucoseValues`: Historical data for graph

#### Settings Data
- [ ] `maxBolus`: Correct limit
- [ ] `maxCarbs`: Correct limit
- [ ] `bolusIncrement`: Correct increment
- [ ] `overridePresets`: Current presets
- [ ] `tempTargetPresets`: Current presets

#### Complication Data
- [ ] `TrioComplicationSnapshot`: Saved correctly
- [ ] Timeline entries: Generated properly
- [ ] Widget refresh: Occurs as expected

## Automated Testing Approaches

### 1. Unit Tests for Data Flow
Create unit tests for each data update path:

```swift
// Example test structure
class WatchDataFlowTests: XCTestCase {
    func testForegroundMessagePath() {
        // Test sendMessage path
    }
    
    func testBackgroundUserInfoPath() {
        // Test transferUserInfo path
    }
    
    func testComplicationSnapshotSaving() {
        // Test TrioComplicationDataStore
    }
    
    func testWatchStateProcessing() {
        // Test WatchState data processing
    }
}
```

### 2. Integration Tests
Test the complete data flow from iPhone to watch:

```swift
class WatchIntegrationTests: XCTestCase {
    func testCompleteDataFlow() {
        // Test iPhone → Watch → Complication flow
    }
    
    func testBidirectionalCommunication() {
        // Test treatment acknowledgments
    }
}
```

### 3. Watch Simulator Testing
Use Xcode's watch simulator for automated testing:

1. **Setup**:
   - Use Xcode's watch simulator
   - Create test data scenarios
   - Automate UI interactions

2. **Test Cases**:
   - Data update verification
   - Complication refresh testing
   - Error handling verification

### 4. Continuous Integration Testing
Set up CI/CD pipeline for watch testing:

1. **Automated Builds**:
   - Build watch app for simulator
   - Run automated tests
   - Verify data flow

2. **Regression Testing**:
   - Test against known good data
   - Verify no regressions in data flow
   - Performance testing

## Logging and Debugging

### iPhone Logs to Monitor
- `📱 Phone session activated`
- `📤 Sending WatchState to Watch`
- `📤 Sending via sendMessage (foreground)`
- `📤 Sending via transferUserInfo (background)`
- `📱 Watch requested watch state data update`

### Watch Logs to Monitor
- `⌚️ Watch session activated`
- `📱 Received WatchState data`
- `⌚️ Background refresh triggered`
- `⌚️ Watch app became active`
- `✅ Saved complication snapshot`

### Debug Tools
1. **Xcode Console**: Monitor logs in real-time
2. **Watch App Logs**: Use `WatchLogger.shared.log()`
3. **Complication Data**: Check App Group container
4. **Network Inspector**: Monitor WatchConnectivity

## Troubleshooting Common Issues

### Issue: Complication Not Updating
**Possible Causes**:
- WatchConnectivity session not activated
- App Group container not accessible
- Timeline not reloading

**Debug Steps**:
1. Check session activation status
2. Verify App Group container access
3. Check timeline reload calls
4. Verify snapshot saving

### Issue: Data Out of Sync
**Possible Causes**:
- Message delivery failure
- Data processing errors
- Timing issues

**Debug Steps**:
1. Check message delivery logs
2. Verify data processing
3. Check timestamp comparisons
4. Verify reachability status

### Issue: Background Updates Not Working
**Possible Causes**:
- Background refresh not scheduled
- System limitations
- App state issues

**Debug Steps**:
1. Check background refresh scheduling
2. Verify app state transitions
3. Check system background refresh logs
4. Test with different watch states

## Performance Considerations

### Data Size Limits
- WatchConnectivity messages: ~65KB limit
- UserInfo transfers: ~65KB limit
- Complication snapshots: Keep minimal

### Update Frequency
- Foreground updates: Immediate
- Background updates: Every 5-15 minutes
- Complication refresh: Every 5 minutes

### Battery Impact
- Minimize unnecessary updates
- Use efficient data structures
- Optimize complication refresh frequency

## Success Criteria

A successful test run should demonstrate:

1. **Data Accuracy**: All data matches between iPhone and watch
2. **Update Reliability**: Updates occur within expected timeframes
3. **Error Handling**: Graceful handling of connection issues
4. **Performance**: Updates don't impact battery life significantly
5. **User Experience**: Smooth, responsive watch app experience

## Maintenance

### Regular Testing Schedule
- **Daily**: Basic functionality verification
- **Weekly**: Complete test suite execution
- **Monthly**: Performance and battery impact review
- **Before Releases**: Full regression testing

### Test Data Management
- Maintain test glucose data sets
- Keep override and temp target presets
- Document test scenarios and results
- Update tests when new features are added

---

*This testing protocol should be updated as new features are added or existing functionality changes.*

