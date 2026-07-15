# Dynamic Island / Live Activity — AI agent map

Останнє фактичне оновлення: 2026-07-14.

Цей файл — вузькоспеціалізована карта саме для Dynamic Island / Live Activity частини
TimeGrow, для AI агента, який продовжує роботу над цією фічею. Загальна карта репозиторію —
`AGENTS.md` в корені; деякі розділи там (Live Activity, Push infrastructure) застарілі відносно
цього файлу — довіряй цьому файлу для всього, що стосується Dynamic Island.

## Що показує Dynamic Island зараз

У compact/minimal presentation показуються тільки цифри/аватар. Expanded presentation має
60-секундне кільце прогресу: воно реалізоване лише через системний `ProgressView(timerInterval:)`
і щохвилинний `minuteWindowStart` update. `TimelineView`/`.animation`-based `Circle.trim()` для
цього не використовувати — такий варіант підтверджено зависає на реальному пристрої.

- `compactLeading` — обведене коло з першою літерою назви задачі кольору акценту, без фону.
- `compactTrailing` — цифри `MM:SS`/`NNN:SS`; формат ніколи не перемикається на години (`61:00`,
  не `1:01:00`) — `showsHours: false`.
- `minimal` — обведене коло з першою літерою назви задачі кольору акценту (як
  `TaskAvatarCircle` в основному застосунку).
- `expanded` — 60-секундне акцентне кільце зліва, elapsed digits справа, назва задачі знизу.
- Lock Screen banner — кольорова крапка + назва + цифри.

## Файли, що відповідають за появу/зникнення Dynamic Island

### UI шар (сам віджет)

- `TimeGrowLiveActivity/TimeGrowLiveActivityBundle.swift` — `@main` WidgetBundle entry point.
- `TimeGrowLiveActivity/TimeGrowLiveActivityLiveActivity.swift` — вся розмітка Dynamic
  Island/Lock Screen (`ActivityConfiguration`, `DynamicIsland`, `TimerDigitsText`).
- `TimeGrow/LiveActivity/TimeGrowLiveActivityAttributes.swift` — спільний `ActivityAttributes`
  (`taskID`, `taskName`, `colorHex`) + `ContentState { startedAt, minuteWindowStart? }`. Лежить під `TimeGrow/`, тому
  автоматично компілюється в основний app target (synchronized group); в
  `TimeGrowLiveActivityExtension` і `AutoTrackingExtension` доданий вручну через окремий
  `PBXBuildFile` в `project.pbxproj` (ці два таргети НЕ synchronized groups).

### Логіка старту/завершення в основному застосунку

- `TimeGrow/LiveActivity/LiveActivityManager.swift` — `@MainActor` singleton
  (`LiveActivityManager.shared`).
  - `reconcile(tasks:)` — головний метод. Викликається з `TaskService.tasks`'s `didSet`, з
    background-wake push handler'а, і з внутрішнього 30-секундного `Timer` (поки є хоч одна
    активність). Для кожного running/не-running переходу: завершує зайві активності
    (`activity.end()`), стартує нові (`Activity.request()`).
  - **Важливо (додано 2026-07-14):** старт нової активності (`start(for:startedAt:)`) виконується
    тільки якщо `UIApplication.shared.applicationState == .active` — Apple кидає `"Target is not
    foreground"` при спробі `Activity.request()` поза foreground, підтверджено на реальному
    пристрої. Завершення активності (`.end()`) цим обмеженням не гейтиться.
  - `observePushToken(of:taskID:)` — підписується на `activity.pushTokenUpdates` і синхронізує
    hex-токен через `pushTokenHandler` в Firestore (`liveActivityPushToken` на таск-документі).
    Викликається для БУДЬ-якої активності, яку `reconcile()` виявляє через
    `Activity<TimeGrowLiveActivityAttributes>.activities` — не тільки тих, що сам застосунок
    щойно стартував (виправлено 2026-07-14; раніше активності, що стартували не через
    `start(for:)`, ніколи не отримували синхронізований push-token, і `end`-push з Cloud Function
    не мав куди слати).
  - `startObservingPushToStartTokens()` — підписується на
    `Activity.pushToStartTokenUpdates` ще під час `TimeGrowApp.init`, кешує пристрій-рівневий
    токен і передає його в `pushToStartTokenHandler`, щойно Firebase/UI готові. Це не дає
    загубити одноразову ранню видачу токена до появи SwiftUI сцени.
- `TimeGrow/TimeGrowApp.swift` — `AppDelegate` реєструє APNs (`registerForRemoteNotifications`),
  обробляє `didRegisterForRemoteNotificationsWithDeviceToken` /
  `didFailToRegisterForRemoteNotificationsWithError` / `didReceiveRemoteNotification`. В
  `TimeGrowApp.onAppear`/`.task` підключає:
  - `LiveActivityManager.shared.pushTokenHandler` → `taskService.updateLiveActivityPushToken`
  - `delegate.remoteNotificationTokenHandler` → `taskService.updateAPNsDeviceToken`
  - `delegate.backgroundNotificationHandler` → `taskService.fetchTasksOnce` → `reconcile(tasks:)`
  - `LiveActivityManager.shared.pushToStartTokenHandler` →
    `taskService.updateActivityPushToStartToken`; handler отримує і кешований токен, якщо він
    був виданий до `onAppear`.
- `TimeGrow/Store/TaskService.swift` — `updateActivityPushToStartToken`, `updateAPNsDeviceToken`,
  `updateLiveActivityPushToken`, `fetchTasksOnce(completion:)` (one-shot фетч тасків для
  background-wake обробника, без очікування live listener'а).

### Автотрекінг (локальний тригер на iPhone)

- `AutoTrackingExtension/AutoTrackingExtension.swift` — `DeviceActivityMonitor` extension.
  **НЕ стартує Live Activity напряму** (спроба через `Activity.request()` прямо з екстеншена
  підтверджено зламана — sandbox-обмеження `DeviceActivityMonitor` екстеншенів, не проблема
  конфігурації; помилка `"Target does not include NSSupportsLiveActivities plist key"` є
  оманливою — реальний ключ на місці, перевірено напряму в зібраному бінарнику. Джерела:
  Apple Developer Forums threads 746416, 760520, 805859). Замість цього екстеншн лише пише
  `autoTrackSessionStartedAt`/`autoTrackLiveUntil`/`autoTrackLastUsageAt` в Firestore напряму
  через REST API (`patchTaskFields`) — цей запис і є єдиним сигналом, який запускає весь ланцюжок
  старту (див. нижче).
  - **НЕ додавай назад** `DeviceActivityMonitor.intervalDidEnd`-based "expiry watcher" для
    локального завершення активності з коротким (менше ~10-15 хв) вікном —
    `DeviceActivitySchedule` вимагає мінімальну тривалість, яку Apple явно не документує, але
    підтверджено empiрично: 3-хвилинне вікно (`autoTrackingInactivityGraceSeconds`) завжди падало
    з `"Графік активності закороткий"` (0 успіхів зі 100 спроб, 14 липня). Ці невдалі виклики,
    ймовірно, і зламали `rearmMonitoring` через виснаження `DeviceActivityCenter` — після
    видалення цього коду автотрекінг знову запрацював стабільно.

### Серверна частина (Cloud Functions)

- `functions/src/index.ts`
  - `onTaskTimerChanged` — `onDocumentUpdated` на `users/{uid}/tasks/{taskID}`. На переході
    "не запущено → запущено": (1, основний шлях) шле **push-to-start** на всі
    `activityPushToStartToken` пристроїв користувача — єдиний спосіб Apple створити нову
    активність, коли застосунок не на передньому плані (система сама створює активність, без
    виконання коду застосунку); на `410 Unregistered` від APNs автоматично видаляє застарілий
    токен з Firestore. (2, допоміжний) шле **silent background-wake push**
    (`content-available: 1`) на всі `apnsDeviceToken`, щоб застосунок міг прогнати
    `reconcile()` для всього, що НЕ потребує foreground (синхронізація push-token, завершення
    активностей). На переході "запущено → не запущено": шле `end`-push на
    `liveActivityPushToken` конкретної задачі.
- `refreshLiveActivities` — `onSchedule('every 1 minutes')`. Підчищає активності, чий таск
  більше не запущений (grace period вийшов мовчки, без нового Firestore-запису), а для активних
  пушить новий `minuteWindowStart`, щоб expanded ring починав наступний 60-секундний sweep.
  Потребує
    Firestore collection-group single-field index exemption на `tasks`/`liveActivityPushToken`
    (Firestore Console → Indexes → Automatic index settings → Exemptions — НЕ через
    `firestore.indexes.json`, Firestore відхиляє це як "непотрібний" composite index).
- `functions/src/apns.ts` — сирий HTTP/2 APNs клієнт (`http2` + `jsonwebtoken` для ES256 provider
  JWT). `sendLiveActivityStart`/`sendLiveActivityEnd` йдуть на топік
  `${bundleId}.push-type.liveactivity` (той самий топік для push-to-start І звичайних
  update/end — **немає** окремого `.push-to-start` суфіксу, це поширена помилкова порада ззовні,
  вже перевірено й відхилено). `sendBackgroundWake` йде на голий bundle ID,
  `apns-push-type: background`.

## Доступ до Firebase / консолі

- Firebase проєкт: `timegrowmac` (Blaze план, вже увімкнено).
- CLI: `firebase` вже в PATH цієї машини. Логін вже виконано.
- Деплой однієї функції: `firebase deploy --only functions:onTaskTimerChanged` (швидше за повний
  деплой).
- Логи: `firebase functions:log --only onTaskTimerChanged -n 500` — фільтруй порожні
  invocation-маркери (`grep -v ": $"`), реальний контент лежить в `console.log`/`console.error` з
  тексту `push-to-start sent OK` / `push-to-start failed` / `background wake sent OK`.
- Секрети (APNs): `APNS_AUTH_KEY` (вміст `.p8` файлу), `APNS_KEY_ID`, `APNS_TEAM_ID`
  (`9CYR3K5YHR`) — `firebase functions:secrets:set NAME`, обов'язково пайпом
  (`< file.p8` або `printf '%s' "value" | firebase ...`), НЕ інтерактивним вставленням — це вже
  ламало значення через перенос рядків у терміналі.
- `aps-environment` зараз `development` (sandbox), `useSandbox: true` в
  `functions/src/apns.ts`'s `credentials()`. Перемикання на `production` вимагає TestFlight/App
  Store дистрибуції (окремий provisioning profile) — навмисно відкладено, поки застосунок активно
  розробляється через Xcode-debug білди на пристрій.
- Тимчасова діагностика реальних Firestore-даних: можна тимчасово додати HTTP-функцію
  (`onRequest`) в `functions/src/`, задеплоїти, викликати через `curl`, і **обов'язково видалити
  одразу після використання** (`rm` файл + `firebase functions:delete <name> --region <region>
  --force`) — вона публічно доступна без авторизації. Uid поточного користувача можна знайти через
  `firebase auth:export /tmp/users.json && cat /tmp/users.json` (і видалити файл після).

## Дві головні проблеми в роботі (станом на 2026-07-14)

### 1. Передача "таск зупинився" з іншого пристрою на iPhone

Коли інший пристрій (Mac-клієнт, окремий застосунок, що пише напряму в Firestore) зупиняє таск,
iPhone має погасити Dynamic Island без відкриття застосунку.

Механізм: `onTaskTimerChanged` детектить running→not-running перехід і шле `end`-push на
`liveActivityPushToken`. **Це працює тільки якщо токен реально синхронізований** — а це вимагає,
щоб `LiveActivityManager.reconcile()` хоч раз відпрацював, поки активність була жива (щоб
викликати `observePushToken`). Якщо активність стартувала через push-to-start і застосунок жодного
разу не забув в foreground/не отримав background-wake до моменту зупинки — токен може бути
не синхронізований, і `end`-push буде посилати нікуди.

Статус: базовий механізм на місці й мав пройти перше реальне підтвердження 14 липня (push-to-start
вперше отримав `200 OK` від APNs на реальний токен поточного встановлення, а не `410`). Потребує
подальшого польового тестування на реальному сценарії "Mac зупиняє → iPhone заблокований, не
відкривався".

### 2. Автоматична поява Dynamic Island при спрацюванні автотрекера на iPhone

Коли `AutoTrackingExtension` фіксує поріг використання застосунку на iPhone, Dynamic Island має
з'явитись сама, без відкриття TimeGrow.

Історія: пряма спроба `Activity.request()` з екстеншена (12 липня) — підтверджено зламана
(sandbox-обмеження `DeviceActivityMonitor`, не проблема конфігурації, 14 липня). Поточний
механізм: екстеншн лише пише Firestore, той самий `onTaskTimerChanged` шле push-to-start на той
самий пристрій (локальний старт і кросдіврайсний старт тепер один і той самий шлях, а не два
окремих). Це залежить від тих самих факторів надійності push-to-start, що й проблема №1 —
непрозорий iOS background execution budget, менш щедрий одразу після свіжого встановлення.

Статус: 14 липня вперше зафіксовано успішний `push-to-start sent OK` на реальний токен. Чи
матеріалізується активність на екрані в цьому конкретному випадку — ще не підтверджено
користувачем на пристрої.

## Виправлені баги, які НЕ варто повторювати

- **`startedAutomatically` як строге `== true`** в мерджі блоків Timeline — Mac-клієнт не пише це
  поле (`nil`), тому мердж має перевіряти `!= false`, не `== true`. Ручний старт з iPhone завжди
  явно `false` (`TaskService.startTimer` дефолтить на `false`).
  (`TimeGrow/Views/TimelineTabView.swift`, `mergingAdjacentAutoTrackedSessions`)
- **`DeviceActivitySchedule` з вікном коротшим за мінімум Apple** — див. секцію про
  `AutoTrackingExtension` вище.
- **Позиційний (не по taskID) мердж сусідніх сесій в Timeline** — якщо між двома сесіями однієї
  задачі в часі встряє сесія іншої задачі, позиційна перевірка "це попередній елемент" ніколи не
  побачить їх сусідніми. Мердж має групувати по `taskID` окремо, а вже потім сортувати назад по
  часу.
- **`Text(timerInterval:)` з широким діапазоном в compact pill** — резервує ширину під
  найдовший можливий рядок в усьому діапазоні; 24-годинний діапазон розтягував капсулу.
  Обмежено до ~10 годин для compact.
- **APNs топік з суфіксом `.push-to-start`** — не існує, push-to-start і звичайні update/end йдуть
  на той самий `.push-type.liveactivity` топік, різниця лише в тому, на який токен (пристрій vs
  активність) і з яким `event` в payload.
