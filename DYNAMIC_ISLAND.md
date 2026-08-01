# Dynamic Island / Live Activity — AI agent map

Останнє фактичне оновлення: 2026-08-01.

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
- `TimeGrow/Helpers/AutoTrackPresentationState.swift` — UI-only поділ п'ятихвилинного вікна
  автотрекінгу на `.active` і `.paused`. Після завершення 90-секундного
  `autoTrackLiveActivityUntil` фіксує `displayDate`, але не закриває і не змінює сесію.
- `TaskRowView.swift`, `TaskTileView.swift`, `TimelineTabView.swift` — у `.paused` elapsed/progress
  завмирає на `displayDate`, а коло плавно блимає. Картка задачі лишається підсвіченою до кінця
  п'ятихвилинного вікна; новий threshold повертає звичайну активну анімацію.

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
  - Якщо ActivityKit повернув `.dismissed`, менеджер зберігає стабільний ключ поточного циклу
    (`activeSessionID` для manual або `autoTrackLiveActivityCycleID` для auto) в App Group і не
    повторює `Activity.request()` на кожному Firestore snapshot. Захист переживає relaunch
    застосунку, але очищається після reboot iPhone, щоб системний ActivityKit recovery міг зробити
    одну нову спробу. Якщо push-start dismissal випередив завантаження task state, task ID
    утримується до background fetch і тоді прив'язується до правильного циклу.
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
  - Для автотрекінгу `autoTrackLiveActivityUntil` керує лише ActivityKit і продовжується на 90с
    кожним threshold. `autoTrackLiveUntil` окремо лишається 300с для склеювання сесії.

### Автотрекінг (локальний тригер на iPhone)

- `AutoTrackingExtension/AutoTrackingExtension.swift` — `DeviceActivityMonitor` extension.
  **НЕ стартує Live Activity напряму** (спроба через `Activity.request()` прямо з екстеншена
  підтверджено зламана — sandbox-обмеження `DeviceActivityMonitor` екстеншенів, не проблема
  конфігурації; помилка `"Target does not include NSSupportsLiveActivities plist key"` є
  оманливою — реальний ключ на місці, перевірено напряму в зібраному бінарнику. Джерела:
  Apple Developer Forums threads 746416, 760520, 805859). Замість цього екстеншн лише пише
  `autoTrackSessionStartedAt`/`autoTrackLiveUntil`/`autoTrackLiveActivityUntil`/
  `autoTrackLastUsageAt` у Firestore через `recordAutoTrackEvent` — цей запис і є сигналом, який запускає весь ланцюжок
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
- `refreshLiveActivities` — `onSchedule('every 1 minutes')`. Підчищає активності, чий
  90-секундний `autoTrackLiveActivityUntil` вийшов мовчки без нового Firestore-запису, а для активних
  пушить новий `minuteWindowStart`, щоб expanded ring починав наступний 60-секундний sweep.
  Сервер рахує ці 90 секунд від `occurredAt` (фактичного DeviceActivity callback), а не від
  моменту отримання HTTP-запиту, тому затримана мережа не подовжує показ. Через хвилинний крок
  scheduler фактичний server-side `end` очікується приблизно через 90–150 секунд; окреме
  п'ятихвилинне `autoTrackLiveUntil` це не змінює.
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

## Діагностика 90-секундного завершення й UI-паузи

Експорт із Settings тепер містить один ланцюжок без animation-frame спаму:

- `[serverDiag] kind=liveActivityEndAccepted ... source=scheduledCleanup
  autoTrackLiveActivityUntil=... cleanupObservedAt=...` — сервер побачив завершений lease й APNs
  прийняв immediate end-push;
- `[liveActivity] 90-second lease audit ... activityPresent=false expectedUIPhase=pausedBlinking`
  — що ActivityKit фактично показував у списку активностей на телефоні, коли застосунок мав CPU;
- `[liveActivity] Live Activity end verification ... systemRemoved=true stillListed=false state=...`
  — результат локального `activity.end(..., .immediate)` через 250мс. `systemRemoved` означає
  відсутність у `Activity.activities` (найсильніший доступний програмний сигнал), а не pixel-level
  перевірку Dynamic Island;
- `[liveActivity] Recorded system-dismissed Live Activity ... cycle=...` — iOS прибрала Activity,
  і цей цикл записаний у локальний guard;
- `[liveActivity] Suppressed repeated Live Activity start ... reason=systemDismissedSameCycle` —
  наступний snapshot не створив retry storm; нова сесія/auto-cycle запускається звичайно;
- `[autoTrackUI] paused blinking started ... surface=taskRow|taskTile|timelineCorner ...` — SwiftUI
  реально перейшов у заморожений blinking state;
- `[autoTrackUI] paused blinking ended ... reason=usageResumed|returnWindowEndedOrStopped` — вихід
  із паузи через нове використання або завершення п'ятихвилинного вікна.

`DiagnosticsLog.exportText()` синхронно дренить свою serial queue перед читанням файла, тому
експорт одразу після події не втрачає останній рядок.

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
- **Часткове `firebase deploy --only functions:X` після зміни спільної helper-функції** — 2026-08-01,
  90-секундний auto-track ліміт (`autoTrackLiveActivityUntil`) не гасив Dynamic Island без відкриття
  застосунку, хоча `recordAutoTrackEvent` вже коректно писав нове поле. Причина: `activeTimerStart`/
  `autoTrackLiveActivityUntil()` — спільний helper для `recordAutoTrackEvent`, `refreshLiveActivities`,
  `onTaskTimerChanged`, `registerLiveActivityPushToken`, `onDevicePushToStartTokenChanged`,
  `closeInterruptedMacAutoTimers` — але задеплоєно було вибірково лише `recordAutoTrackEvent`.
  `refreshLiveActivities` продовжував виконувати СТАРУ скомпільовану версію helper'а (5-хвилинний
  `autoTrackLiveUntil`), тому щохвилинний sweep вважав активність "ще живою" ще ~3.5 хвилини понад
  очікуване і мовчки слав update замість end-push (обидва шляхи нічого не логують при успіху — це і
  ховало розбіжність). Кожен Cloud Functions Gen2 таргет — окремий Cloud Run сервіс зі своєю
  скомпільованою копією `lib/index.js`; зміна спільної функції в `src/index.ts` вимагає передеплою
  **усіх** таргетів, що її використовують, не тільки того, який первинно тестуєш.

  Діагностика такого розсинхрону: `firebase functions:log --only refreshLiveActivities` після
  очікуваного дедлайну не показує НІ `scheduled Live Activity end accepted`, НІ error/APNs-лог —
  просто порожній рядок (це нормальний вигляд і для "silent success" гілки, і для "нічого не
  знайшли", тому відсутність логу сама по собі не доказ). Найшвидший спосіб підтвердити: тимчасова
  `onRequest` діагностична функція (див. розділ вище), яка дампить сирий таск-документ і звіряє
  `autoTrackLiveActivityUntil` з очікуваним 90-секундним дедлайном.
- **`liveActivityPushToken` (singular) vs `liveActivityPushTokens` (map) розсинхрон** —
  `TaskService.updateLiveActivityPushToken` (клієнт, `TimeGrow/Store/TaskService.swift`) пише/чистить
  **лише** singular-поле; сервер (`registerLiveActivityPushToken`) пише обидва разом. Коли клієнт сам
  локально завершує активність і шле `nil` (`LiveActivityManager` після 2-секундного
  reconciliation grace), singular-поле видаляється, а `liveActivityPushTokens` лишається з застарілим
  токеном назавжди — і, що важливіше, `refreshLiveActivities`'s `collectionGroup` query фільтрує
  **тільки** по singular-полю, тому такий таск-документ повністю зникає з-під щохвилинного sweep, поки
  наступний auto-track цикл не зареєструє новий токен через сервер. Не критично для одного пристрою
  (наступний цикл усе одно перезапише), але вартий уваги при мультипристрійних сценаріях.
