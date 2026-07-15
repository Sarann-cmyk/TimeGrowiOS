# TimeGrow AI Agent Map

Останнє фактичне оновлення карти: 2026-07-12.

Цей файл — стартова карта для AI агента, який працює з поточним станом репозиторію. Вона описує те, що вже є в коді, без припущень про майбутню архітектуру.

## Поточний продукт

TimeGrow — iOS/iPadOS SwiftUI застосунок для трекінгу часу по задачах.

Основні можливості, які вже реалізовані:

- ручне створення, редагування і видалення задач;
- ручний старт/стоп таймера задачі;
- збереження задач, сесій, пристроїв і налаштувань у Firestore;
- anonymous Firebase auth за замовчуванням;
- Sign in with Apple з link anonymous account / sign in existing Apple account flow;
- автотрекінг через Screen Time APIs (`FamilyControls`, `DeviceActivity`);
- окремий `DeviceActivityMonitor` extension для подій автотрекінгу;
- `TimeGrowLiveActivity` extension skeleton для Live Activities / Dynamic Island;
- Timeline, Reports, detail report, edit session, export/share reports;
- локальний app accent color;
- діагностичний лог у App Group контейнері з експортом із Settings.

## Репозиторій і targets

Xcode project:

- `TimeGrow.xcodeproj`

Targets / schemes:

- `TimeGrow` — основний iOS app target.
- `AutoTrackingExtension` — app extension target для `com.apple.deviceactivity.monitor-extension`.
- `TimeGrowLiveActivity` — WidgetKit app extension target для Live Activities.

Build configs:

- `Debug`
- `Release`

Поточні build facts з `project.pbxproj`:

- Swift version: `5.0`
- iOS deployment target: `26.5`
- app bundle id: `WINNER.ltd.TimeGrow`
- extension bundle id: `WINNER.ltd.TimeGrow.AutoTrackingExtension`
- live activity extension bundle id: `WINNER.ltd.TimeGrow.LiveActivity`
- development team: `9CYR3K5YHR`
- marketing version: `1.0`
- current project version: `1`

Swift Package dependency:

- Firebase iOS SDK pinned at `12.15.0`
- linked products: `FirebaseAnalytics`, `FirebaseAuth`, `FirebaseFirestore`

## Вхідні точки

### App

`TimeGrow/TimeGrowApp.swift`

- Викликає `FirebaseApp.configure()` в `init`.
- Створює і прокидає через environment:
  - `TaskService`
  - `AutoTrackingStore`
  - `AccentColorManager`
- На `onAppear`:
  - `taskService.start()`
  - `autoTrackingStore.refreshMonitoring(for: taskService.tasks)`
  - `processPendingAutoTrackEvents()`
- На `scenePhase == .active`:
  - оновлює auth/heartbeat/recovery через `TaskService`;
  - оновлює Screen Time authorization і DeviceActivity monitoring;
  - дренить pending auto-track events з App Group.
- На зміні `taskService.tasks`:
  - перераховує DeviceActivity monitoring.

### Root UI

`TimeGrow/Views/ContentView.swift`

- Root SwiftUI view з темним UI.
- Tabs через `AppTab`:
  - `Tasks`
  - `Timeline`
  - `Reports`
  - `Settings`
- Tasks tab рендерить `TaskRow`.
- Add/edit task через `TaskFormView`.
- Auto tracking picker через `AutoTrackingPickerView`.

### Extension

`AutoTrackingExtension/AutoTrackingExtension.swift`

- `DeviceActivityMonitorExtension: DeviceActivityMonitor`
- Обробляє:
  - `intervalDidStart`
  - `intervalDidEnd`
  - `eventDidReachThreshold`
- При threshold:
  - пише pending event в App Group `UserDefaults`;
  - пробує синхронізувати live-state задачі напряму у Firestore REST API;
  - re-arm monitoring з новим generation id.

### Live Activity Extension

**Застарілий розділ.** Все, що стосується Dynamic Island/Live Activity (архітектура, файли,
push-to-start, Cloud Functions, доступ до Firebase, активні проблеми) — дивись
`DYNAMIC_ISLAND.md` в корені репозиторію, там актуальний стан на 2026-07-14. Розділи нижче
описують стан на 2026-07-12 і містять застарілі факти (кільце видалено, `AutoTrackingExtension`
більше не стартує активність напряму, push-to-start тепер основний, а не резервний шлях).

`TimeGrowLiveActivity/TimeGrowLiveActivityBundle.swift`

- `@main` WidgetBundle entry point. Includes only `TimeGrowLiveActivityLiveActivity` — the
  home-screen-widget and Control Widget templates Xcode scaffolded when the target was created
  were deleted as unused (this project has no home-screen widget).

`TimeGrowLiveActivity/TimeGrowLiveActivityLiveActivity.swift`

- WidgetKit `ActivityConfiguration` for `TimeGrowLiveActivityAttributes`.
- Dynamic Island: `compactLeading` is empty; `compactTrailing` and `minimal` both show
  `MinuteProgressRing` (a circular per-minute progress ring, see below); expanded shows task name
  (leading), `mm:ss`/`hh:mm:ss` elapsed digits (trailing), and an accent-colored capsule (bottom).
- Lock Screen banner shows task name + colored dot + elapsed digits.
- `MinuteProgressRing` sweeps a full circle every 60s via `ProgressView(timerInterval:)` —
  **do not** replace this with a `TimelineView(.animation)`-driven `Circle().trim()`; that was
  tried and confirmed on-device to freeze within the first minute. Live Activities only get
  system-driven continuous animation from `Text`/`ProgressView` with `timerInterval`; nothing else
  (including a hidden/`opacity(0)` `ProgressView` "trick") animates other sibling views.

`TimeGrow/LiveActivity/TimeGrowLiveActivityAttributes.swift`

- Shared ActivityKit attributes file (`taskID`, `taskName`, `colorHex`;
  `ContentState { startedAt, minuteWindowStart }`).
- Lives under `TimeGrow/` so it compiles into the main app automatically via the synchronized
  group. Also manually added (same `fileRef`, separate `PBXBuildFile`) to
  `TimeGrowLiveActivityExtension`'s and `AutoTrackingExtension`'s Sources build phases — those two
  targets are NOT synchronized groups, so new shared files need this manual pbxproj wiring.

`TimeGrow/LiveActivity/LiveActivityManager.swift`

- Main-app `@MainActor` singleton (`LiveActivityManager.shared`). Call
  `reconcile(tasks:)` whenever the task list changes — `TaskService.tasks` calls it from a
  `didSet`, so every mutation path (manual start/stop, auto-track, stale-timer reap, listener
  merge) is covered automatically without extra call sites.
- Starts/ends activities based on `TGTask.timerStartedAt` (manual) or
  `autoTrackSessionStartedAt`/`autoTrackLiveUntil`/`autoTrackStoppedAt` (auto-track).
- Runs an internal `Timer` (10s tick, only while ≥1 activity is running) that refreshes
  `minuteWindowStart` roughly once a minute so the ring keeps sweeping.
- Also owns push-token plumbing (see below): `startObservingPushToStartTokens()` subscribes to
  device-level `Activity.pushToStartTokenUpdates` during `TimeGrowApp.init`, caches its
  hex-encoded result, and delivers it through `pushToStartTokenHandler`; `pushTokenHandler`
  receives each activity's own `pushTokenUpdates`. Both persist through `TaskService` once the
  app's Firebase/UI wiring is ready.

### AutoTrackingExtension also starts the Live Activity directly (added 2026-07-12)

Cross-device push-to-start proved unreliable in testing (see "Push infrastructure" below) — APNs
accepts and delivers the push, but iOS doesn't reliably grant the freshly-installed app CPU time to
materialize the activity. `AutoTrackingExtension.swift`'s `eventDidReachThreshold` now also calls
`Activity.request()` **directly, synchronously, with no network/push involved** — since
`DeviceActivityMonitor` is already guaranteed to run right when the Screen Time threshold fires,
this bypasses the whole background-execution-budget problem for the local (same-device)
auto-tracking case (it does **not** help the cross-device "started on another device" case, which
still depends on push).

Requirements this needed that are easy to miss if extending this pattern to another extension:
- `NSSupportsLiveActivities = true` must be added to **that extension's own `Info.plist`**, not
  just the main app's — `Activity.request()` throws `"Target does not include
  NSSupportsLiveActivities plist key"` otherwise even though the main app has the key.
- `TimeGrowLiveActivityAttributes.swift` must be added to the extension's Sources build phase (see
  above).
- Task display metadata (`name`/`colorHex`) isn't otherwise available to the extension, so
  `AutoTrackingStore.refreshMonitoring(for:)` mirrors it into the App Group under
  `autoTracking.taskMeta.{taskID}` (`["name": ..., "colorHex": ...]`) whenever the app's task list
  changes, so the extension can read it locally with no network round trip.

## Ключові директорії

```text
TimeGrow/
  AutoTracking/       Screen Time picker/store для основного app target
  Helpers/            UI/theme/date/report/diagnostics helpers
  LiveActivity/        Shared ActivityKit attributes + LiveActivityManager
  Models/             Firestore Codable models + один SwiftData template model
  Store/              TaskService, sync config, accent color manager
  Views/              SwiftUI screens/components
  Assets.xcassets/
  GoogleService-Info.plist
  Info.plist
  TimeGrow.entitlements

AutoTrackingExtension/
  AutoTrackingExtension.swift
  Info.plist
  AutoTrackingExtension.entitlements

TimeGrowLiveActivity/
  TimeGrowLiveActivityBundle.swift
  TimeGrowLiveActivityLiveActivity.swift
  Info.plist

functions/            Firebase Cloud Functions (push-to-start / background wake), see
                      "Push infrastructure" section above
  src/index.ts
  src/apns.ts
```

## Core state model

### `TGTask`

`TimeGrow/Models/TGTask.swift`

Firestore task document.

Important fields:

- `@DocumentID var id`
- `name`
- `colorHex`
- `createdAt`
- `updatedAt`
- manual/live timer fields:
  - `timerStartedAt`
  - `activeSessionID`
  - `timerOwnerDeviceID`
  - `timerOwnerPlatform`
  - `timerOwnerDeviceName`
  - `timerOwnerLastAliveAt`
  - `timerOwnerIsActive`
- auto-track live display fields:
  - `autoTrackLastUsageAt`
  - `autoTrackLiveUntil`
  - `autoTrackActiveSessionID`
  - `autoTrackSessionStartedAt`
  - `autoTrackStoppedAt`
- `liveActivityPushToken` — per-activity ActivityKit push token (hex), set by
  `LiveActivityManager` while an activity is running; a Cloud Function uses it to push
  `update`/`end` events. Cleared on end.

Computed:

- `symbol` — first letter of task name.
- `color` — from `colorHex`.
- `isTimerRunning` — `timerStartedAt != nil`.

### `TaskTimeSession`

`TimeGrow/Models/TaskTimeSession.swift`

Firestore session document.

Fields:

- `@DocumentID var id`
- `taskID`
- `taskName`
- `colorHex`
- `startedAt`
- `endedAt`
- device origin:
  - `startedByDeviceID`
  - `startedByPlatform`
  - `startedByDeviceName`
- `startedAutomatically`
- `notes`

Computed:

- `isRunning`
- `duration(at:)`
- `color`

### `TrackingSettings`

`TimeGrow/Models/TrackingSettings.swift`

Firestore settings document for auto tracking:

- `autoTrackStartDelaySeconds`
- `autoTrackStopDelaySeconds`
- `updatedAt`

Defaults:

- start delay: `30`
- stop delay: `90`

### `UserDeviceHeartbeat`

`TimeGrow/Models/UserDeviceHeartbeat.swift`

Firestore device heartbeat document:

- `deviceID`
- `deviceName`
- `platform`
- `isActive`
- `lastAliveAt`
- `activityPushToStartToken` — hex-encoded ActivityKit push-to-start token for this device.
- `apnsDeviceToken` — hex-encoded regular APNs device token, used for the silent
  background-wake push. See "Push infrastructure" above.

### Template / probably unused

`TimeGrow/Models/Item.swift`

- SwiftData template `@Model final class Item`.
- No current references outside the file. Do not assume SwiftData persistence is part of the active architecture.

## Firestore layout

All active app data is under authenticated Firebase user id:

```text
users/{uid}/tasks/{taskID}
users/{uid}/sessions/{sessionID}
users/{uid}/devices/{deviceID}
users/{uid}/settings/tracking
```

Implemented in `TaskService` helpers:

- `tasksCollection(for:)`
- `sessionsCollection(for:)`
- `devicesCollection(for:)`
- `trackingSettingsDocument(for:)`
- `currentDeviceDocument(for:)`

Important behavior:

- `observeTasks` listens to all tasks ordered by `createdAt`.
- `observeSessions` listens only to sessions with `startedAt` newer than 30 days ago.
- Reports/timeline ranges outside the observed cache use `fetchSessions(from:to:)`.
- `fetchSessions(from:to:)` queries `startedAt < endDate`, then filters client-side for overlap with `startDate`.
- `deleteTask` blocks deletion if any session exists for that task.
- `deleteSession` also clears active timer fields if deleting a running session.
- `updateSession` edits ended/past sessions from report editing UI.

## Auth model

`TaskService.start()` registers `Auth.auth().addStateDidChangeListener`.

Current flow:

- If no Firebase user exists, app signs in anonymously.
- `isSignedIn` is `user != nil`; anonymous users are still signed in.
- Sign in with Apple:
  - if current user is anonymous, it tries to `link(with:)`;
  - if the Apple credential is already associated with an existing account, it signs in with the updated credential from Firebase error metadata;
  - before switching to the existing account, it fetches anonymous tasks and imports them into the existing account.

As-is edge:

- The existing Apple-account conflict migration imports tasks only. It does not import anonymous sessions.

## Timer lifecycle

Central owner: `TimeGrow/Store/TaskService.swift`.

Manual start:

- `startTimer(for:at:startedAutomatically:)`
- Creates a `TaskTimeSession`.
- Applies optimistic local state.
- Writes session doc.
- Updates task with:
  - `timerStartedAt`
  - `activeSessionID`
  - timer owner device/platform/name/heartbeat fields.

Manual stop:

- Public `stopTimer(for:)` calls private `stopTimer(for:endedAt:reason:)`.
- Clears active timer fields on task.
- Updates active session `endedAt`.
- If duration is below `minimumTrackedSessionDuration`, deletes the session.

Constants from `AutoTrackingStore.swift`:

- `minimumTrackedSessionDuration = 3`
- `autoTrackingThresholdSeconds = 60`
- `autoTrackingInactivityGraceSeconds = 120`

Heartbeat / stale handling:

- App writes current device heartbeat to `users/{uid}/devices/{currentDeviceID}`.
- Heartbeat interval: `15s`.
- Stale check interval: `5s`.
- Manual timers are intentionally not stopped by heartbeat inactivity.
- Auto-tracked sessions can be stopped through pending-stop/recovery logic.
- `autoCloseInterruptedMacTimers()` can remotely close interrupted Mac-owned auto sessions based on owner heartbeat fields.

## Auto tracking architecture

Files:

- `TimeGrow/AutoTracking/AutoTrackingStore.swift`
- `TimeGrow/AutoTracking/AutoTrackingPickerView.swift`
- `AutoTrackingExtension/AutoTrackingExtension.swift`

Shared App Group:

- `group.WINNER.ltd.TimeGrow`

Shared keys:

- `autoTracking.pendingEvents`
- `autoTracking.debugEvents`
- `autoTracking.selectionData.{taskID}`
- `autoTracking.firebase.uid`
- `autoTracking.firebase.idToken`
- `autoTracking.firebase.idTokenExpiration`
- `autoTracking.firebase.projectID`

Main app behavior:

- `AutoTrackingPickerView` requests Screen Time authorization and shows `FamilyActivityPicker`.
- `AutoTrackingStore.saveSelection` stores selection in:
  - `UserDefaults.standard`
  - App Group `UserDefaults`
- `refreshMonitoring(for:)`:
  - requires Screen Time authorization approved;
  - resets monitoring once per app run;
  - schedules monitoring for tasks with selection and no running timer;
  - stops monitoring for running tasks or tasks with empty selection.
- Monitoring schedule:
  - daily `00:00` to `23:59`
  - threshold: `1 minute`
  - `includesPastActivity: false`

Extension behavior:

- Threshold event appends pending event:
  - `taskID`
  - `occurredAt`
- Extension also patches Firestore task live fields via REST if a non-expired Firebase ID token snapshot is available.
- If token/auth is missing or expired, the pending event remains for the main app to process later.
- Extension stores local `lastUsage` and `sessionStart` values to decide whether to continue the same auto-track live window.
- Extension re-arms monitoring after each threshold with a new `DeviceActivityName`.

Main app pending-event processing:

- `TimeGrowApp.processPendingAutoTrackEvents()`
- `AutoTrackingStore.drainPendingEvents()`
- `TaskService.processPendingAutoTrackEvents(_:)`

When processing:

- event is backdated by `autoTrackingThresholdSeconds`;
- app records or merges an auto-tracked session;
- merge window is `autoTrackingInactivityGraceSeconds`;
- task live display fields are updated optimistically and in Firestore.

## Views map

### Tasks

- `ContentView.swift`
  - app shell, tabs, add/edit/autotrack sheets.
- `TaskRowView.swift`
  - task row, active state, auto-track live badge, duration label.
- `TaskFormView.swift`
  - create/edit task, built-in colors and custom color sheet.
- `AutoTrackingPickerView.swift`
  - Screen Time permission prompt and `FamilyActivityPicker`.

### Timeline

- `TimelineTabView.swift`
  - day/week timeline.
  - Uses observed sessions cache when possible.
  - Fetches sessions through `TaskService.fetchSessions(from:to:)` when range is outside the observed cache.

### Reports

- `ReportsView.swift`
  - overall reports for day/week/month/year.
  - stacked chart, task breakdown, sessions list, report sharing.
  - Allows editing/deleting sessions.
- `TaskReportDetailView.swift`
  - per-task report details.
  - Uses `Charts`.
  - Has bar/line chart style persisted via `@AppStorage`.
- `SessionEditView.swift`
  - edit started/ended date, task assignment, notes.
  - delete session.
- `ReportPeriodKit.swift`
  - shared date math, bucket generation, formatters.

### Settings / account

- `AccountView.swift`
  - sign in/out.
  - accent color picker.
  - session-list minimum duration setting.
  - diagnostics export/clear.
- `AccentColorPickerSheet.swift`
  - app-level accent color selection.

## Helpers and local persistence

- `AccentColorManager`
  - app accent color in `UserDefaults.standard`, key `app_accent_color_hex`.
- `TaskAppearance`
  - converts `Color` <-> hex string.
- `Color+Theme`
  - static UI colors.
- `Haptics`
  - simple haptic wrappers.
- `DiagnosticsLog`
  - persistent log in App Group container.
  - trims around `400_000` characters.
  - combines app log and extension debug events on export.
- `SyncConfiguration`
  - contains `syncCode`.
  - No current references outside `SyncConfiguration.swift`; treat as legacy/placeholder unless new code proves otherwise.

## Entitlements / capabilities

Main app entitlements:

- Push environment: development.
- CloudKit entitlement present, but no active CloudKit code found.
- Sign in with Apple.
- App Group: `group.WINNER.ltd.TimeGrow`.
- Family Controls.

Extension entitlements:

- Family Controls.
- App Group: `group.WINNER.ltd.TimeGrow`.

Live Activity extension entitlements:

- App Group: `group.WINNER.ltd.TimeGrow`.

Info:

- Main app `Info.plist` currently has `UIBackgroundModes` with `remote-notification`.
- Main app `Info.plist` has `NSSupportsLiveActivities = true`.
- Extension `Info.plist` declares `com.apple.deviceactivity.monitor-extension`.
- Live Activity extension `Info.plist` declares `com.apple.widgetkit-extension`.

## Push infrastructure / Cloud Functions (added 2026-07-12)

New top-level `functions/` — Firebase Cloud Functions (TypeScript, Firebase Functions v2),
Firebase project `timegrowmac` (Blaze plan required, already enabled). `firebase.json`/
`.firebaserc` at repo root point at it. Deploy: `firebase deploy --only functions` from repo root
(needs `firebase login` as a project member first; CLI isn't in PATH by default in this repo's dev
setup — invoke via `"$(npm config get prefix)/bin/firebase"` if `firebase` isn't found).

Why this exists: the Dynamic Island ring only started/stopped when `TaskService`'s Firestore
listener was live (i.e. app foregrounded on some device). The goal was making it react
automatically when another device (e.g. a macOS TimeGrow client, same Firestore backend) starts or
stops a task — see `functions/src/index.ts`:

- **`onTaskTimerChanged`** — `onDocumentUpdated` on `users/{uid}/tasks/{taskID}`. On a
  not-running→running transition: sends a **silent background-wake push**
  (`content-available: 1`, `apns-push-type: background`, topic = bare bundle ID) to every device
  with a registered `apnsDeviceToken`, so the app wakes and runs the already-reliable local
  `LiveActivityManager.reconcile()`; also attempts ActivityKit **push-to-start** as a best-effort
  secondary path. On running→not-running: sends an `end` push to the task's
  `liveActivityPushToken`.
- **`refreshLiveActivities`** — `onSchedule('every 1 minutes')`. For every task with a live
  `liveActivityPushToken`: if still running, pushes an `update` with a fresh `minuteWindowStart`
  (keeps the ring sweeping even with every device fully closed); if not running anymore (the
  auto-track grace period lapsed with no new Firestore write to trigger the handler above), pushes
  `end` and clears the token. Needs a Firestore **collection-group single-field index exemption**
  on `tasks`/`liveActivityPushToken` (ascending, collection-group scope) — set via Firestore
  Console → Indexes → Automatic index settings → Exemptions, not via `firestore.indexes.json`
  (Firestore rejects that field as a composite index with "this index is not necessary, configure
  using single field index controls").

`functions/src/apns.ts` — raw HTTP/2 APNs client (Node's `http2` + `jsonwebtoken` for the ES256
provider JWT; no `node-apn` dependency). Three secrets required
(`firebase functions:secrets:set NAME`, pipe the value in — e.g. `< AuthKey_XXXX.p8` for the auth
key — rather than pasting interactively, which is easy to corrupt via terminal line-wrapping):
`APNS_AUTH_KEY` (.p8 file contents), `APNS_KEY_ID`, `APNS_TEAM_ID` (`9CYR3K5YHR`). `useSandbox:
true` in `functions/src/index.ts` matches the current `aps-environment = development` entitlement
— flip to `false` for a production/TestFlight build.

**Critical Date-encoding gotcha**: Swift's synthesized `Codable` for `Date` uses
`.deferredToDate`: a JSON number of seconds since Apple's reference date (2001-01-01), **not**
Unix seconds since 1970 and not ISO8601. ActivityKit uses that decoder for `content-state`.
Sending a Unix timestamp decodes the date decades into the future (the elapsed timer shows
`0:00`); sending ISO8601 can make the activity silently fail to start/update. Therefore
`functions/src/index.ts`'s `contentState()` subtracts `978_307_200` from Unix seconds.

**Known reliability gap (as of 2026-07-12, unresolved)**: on a freshly-reinstalled app, both
push-to-start and the background-wake push are reliably accepted by APNs and correctly routed
on-device (confirmed via macOS Console.app: `liveactivitiesd`/`apsd`/`SpringBoard` all show correct
receipt) but the app doesn't reliably get woken to actually process them — this is iOS's
background-execution-budget throttling for apps with no usage history, not a bug in this code.
Confirmed empirically: leaving the phone actively in use (e.g. YouTube playing) makes the same
push mechanism work; locking/idling the phone makes it stop working again. Apple does not
guarantee `content-available` push delivery timing. This budget is expected to improve with
organic daily use over time. The `AutoTrackingExtension` direct-start (above) sidesteps this
entirely for the local same-device auto-tracking case; the cross-device "started on another
device" case still depends on this push path and has no other known workaround.

## Known gaps in current repo

- No `README.md`.
- No test target found.
- No CI configuration found.
- No Firestore security rules in repo.
- No local `Package.swift`; dependencies are managed by Xcode project SwiftPM integration.
- `Item.swift` SwiftData template is present but unused.
- `SyncConfiguration.syncCode` is present but unused.
- CloudKit entitlement is present but no CloudKit code was found.
- Firebase Analytics is linked but no direct Analytics calls were found in source.
- `TimeGrowLiveActivity` target exists, builds, and is validated on a real device (Dynamic Island ring + Lock Screen banner). Cross-device push-to-start remains unreliable on freshly-installed apps — see "Push infrastructure" above.

## Guardrails for future AI agents

1. Treat `TaskService` as the central state/sync owner. Avoid duplicating Firestore writes in views unless there is a clear reason.
2. Keep `TaskService` main-actor assumptions intact. It is annotated `@MainActor` and publishes UI-facing state.
3. If changing auto tracking constants or App Group keys, update both:
   - `TimeGrow/AutoTracking/AutoTrackingStore.swift`
   - `AutoTrackingExtension/AutoTrackingExtension.swift`
4. If changing Firestore field names, update:
   - models,
   - `TaskService` write/update paths,
   - extension REST patch body/update masks,
   - report/timeline code that reads sessions.
5. Do not break the invariant that tasks with existing sessions cannot be deleted through normal UI.
6. Manual timers are intentionally allowed to survive background/inactive heartbeat gaps. Do not apply auto-stop heartbeat rules to manual sessions without a product decision.
7. Auto-tracked sessions are intentionally short-lived/mergeable around a 60-second threshold and 120-second live grace window.
8. DeviceActivity extension has limited runtime. Keep extension work small and resilient; missing auth should still leave pending events for the main app.
9. Be careful with the 30-day observed session cache. Reports/timeline can need explicit `fetchSessions(from:to:)` for older ranges.
10. If wiring Live Activities to timers, update them from `TaskService` so manual/auto timer state remains centralized.
11. Before large UI changes, inspect the large files directly:
    - `ReportsView.swift`
    - `TaskReportDetailView.swift`
    - `TimelineTabView.swift`
    - `TaskService.swift`

## Useful validation commands

List project targets/schemes:

```sh
xcodebuild -list -project TimeGrow.xcodeproj
```

Attempt a build when local Xcode destinations/codesigning allow it:

```sh
xcodebuild -project TimeGrow.xcodeproj -scheme TimeGrow -configuration Debug -destination 'generic/platform=iOS Simulator' build
```

Fast repository inspection:

```sh
rg --files
rg -n "TODO|FIXME|TaskService|AutoTracking|DeviceActivity|Firestore" TimeGrow AutoTrackingExtension
```
