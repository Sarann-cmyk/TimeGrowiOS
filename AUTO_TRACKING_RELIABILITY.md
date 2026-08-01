# Надійність і точність автотрекінгу — робоча карта для AI агента

Останнє фактичне оновлення: 2026-08-01.

Це доповнення до `AUTO_TRACKING.md`. Воно концентрується не на UI чи базовому потоці даних, а
на найскладнішому питанні: чому в більшість днів TimeGrow збігається зі Screen Time, але інколи
відстає на десятки хвилин або годину — і як покращувати це без неконтрольованого double-counting.

## Висновок, з якого треба починати

`DeviceActivityMonitor` не є потоком точних секунд використання. Він дає дискретні, асинхронно
доставлені порогові callback-и. Для TimeGrow один прийнятий поріг зараз означає один підтверджений
мінімум використання в 60 секунд. Коли callback-и приходять рівномірно, статистика природно
збігається зі Screen Time. Коли iOS затримує, пропускає або віддає кілька різних порогів пачкою,
ми повинні вибирати між двома поганими варіантами:

- зарахувати все автоматично і ризикувати завищити час через відомі дублікати iOS;
- відкинути швидкі події і ризикувати втратити реальні хвилини.

Поточна реалізація розрізняє точний duplicate і distinct step. Кожен distinct step є
підтвердженим 60-секундним кредитом; коли iOS віддає їх пачкою, ми не вигадуємо точні timestamps,
а консервативно розміщуємо кредити прямо перед доставкою. Server-side traces лишаються потрібні,
щоб перевірити цей баланс на реальному використанні.

З 2026-08-01 п'ятихвилинне вікно склеювання сесії не дорівнює строку Dynamic Island:
`autoTrackLiveUntil` лишається 300с, а окремий `autoTrackLiveActivityUntil` — 90с. Тому затриманий
callback більше не розриває сесію, але може спричинити згасання і повторну появу Island.

## Контракт даних: чого ми знаємо, а чого ні

| Факт | Джерело | Надійність / обмеження |
|---|---|---|
| Обраний застосунок був на передньому плані щонайменше N хвилин у межах монітора | `DeviceActivityEvent` | Сумарний usage, а не подія відкриття/закриття. |
| Точна секунда, коли користувач відкрив або закрив TikTok | Немає | Screen Time API її не видає. |
| Час delivery callback-а | `Date()` у `eventDidReachThreshold` | Це час, коли extension прокинувся, не обов'язково фактичний кінець хвилини usage. |
| Номер кроку `1...15` | `thresholdReached|generation|step` | Це накопичувальний поріг поточного monitor generation, не гарантія безперервних хвилин саме зараз. |
| Точний час у системному Screen Time | iOS Settings | Він не експортується в TimeGrow через `DeviceActivityMonitor`. |

Тому не можна побудувати точний журнал usage лише за timestamp-ами callback-ів. Зокрема, не можна
безпечно «домалювати» шість хвилин назад, лише тому що `step=7`: попередні шість хвилин могли бути
розкидані окремими короткими відкриттями протягом дня.

## Повний ланцюжок однієї threshold-події

```text
TikTok frontmost usage
  → iOS накопичує usage у DeviceActivity monitor
  → eventDidReachThreshold(event, activity) у AutoTrackingExtension
  → App Group pendingEvents (синхронний локальний запас)
  → HTTPS recordAutoTrackEvent (спроба одразу, extension чекає максимум 3 с на відповідь)
  → Firestore transaction: TaskTimeSession + autoTrack* поля + autoTrackEvents
  → onTaskTimerChanged: push-to-start / background wake для Live Activity
  → iOS створює Activity → registerLiveActivityPushToken
```

Статистика не залежить від того, чи Dynamic Island стала видимою: сервер створює/продовжує
`TaskTimeSession` після прийняття threshold. Якщо HTTP-запит не дійшов, callback уже лежить у
локальній App Group черзі й буде перетворений на сесію при наступному відкритті/переході app у
foreground. Невідновлюваною є лише подія, для якої iOS взагалі не викликала extension.

## Offline-first: локальна подія перед мережею

`recordAutoTrackEvent` потрібний для near-real-time Timeline, cross-device sync і Dynamic Island,
але **не є єдиним сховищем часу**. Порядок у `eventDidReachThreshold` навмисно незмінний:

1. Extension дедублікує identity і синхронно додає запис до App Group
   `autoTracking.pendingEvents`.
2. Лише після успішного локального запису extension запускає HTTPS POST на
   `recordAutoTrackEvent` (таймаут 3 с).
3. Якщо POST успішний, сервер одразу матеріалізує `TaskTimeSession`; локальний replay пізніше
   ідемпотентно зіллється з тією самою сесією.
4. Якщо мережі або server credential немає, pending event лишається в App Group.
   `TimeGrowApp.processPendingAutoTrackEvents()` викликає
   `AutoTrackingStore.drainPendingEvents()` на launch і при `.active`, а `TaskService` створює
   або продовжує сесію локально; Firestore SDK доставить цей запис, коли мережа стане доступною.
5. `autoTrackEvents` — ще один, серверний запасний шлях: він допомагає відновити вже прийняту
   сервером подію, якщо локальна черга не була дочитана або App Group контейнер втрачено.

Отже, повернення мережі саме по собі не гарантує запуск main app: черга дрениться при його
наступному launch/foreground. Це усвідомлений offline-first компроміс, а не привід відкидати
подію в extension.

## Монітор, накопичувальні кроки та rearm

`AutoTrackingStore.accumulatedThresholdEvents` і
`DeviceActivityMonitorExtension.accumulatedThresholdEvents` ставлять 15 окремих events:
`1, 2, …, 15` хвилин з одним `generation` UUID. Це зменшує дорогий `stopMonitoring` /
`startMonitoring` з разу на хвилину до разу на 15 порогів.

Після `step == 15` extension викликає `rearmMonitoring(after:)`, створює нову generation і новий
лічильник. `includesPastActivity: false` означає, що новий monitor не відновлює прогрес старого.
Тому безпричинний rearm, скидання монітора під час запуску або зміна selection можуть реально
втратити неповну хвилину. На першому `refreshMonitoring` кожного process run
`AutoTrackingStore.adoptExistingMonitoring` звіряє `activityCenter.activities` зі збереженим
`autoTracking.monitoredActivity.{taskID}` і підхоплює чинний monitor у пам'ять. Після цього
`refreshMonitoring` створює monitor лише для задачі без adopted/current monitor; не робить
`stopMonitoring`/`startMonitoring` «про всяк випадок». Зупиняються тільки orphaned generation,
задачі без selection або задача з ручним таймером.

Фінальний `step=15` все одно потребує rearm. Якщо iOS затримала саме цей callback, час між
фактичним 15-м порогом і новим monitor може не потрапити в наступну generation через
`includesPastActivity: false`. Це обмеження Screen Time API; не повертати щохвилинний rearm як
уявне виправлення — він систематично збільшує ризик таких втрат.

## Поточна дедуплікація і її небезпечна межа

### Як працює зараз (після рефакторингу 2026-07-30)

1. Extension тримає identity `usageDay + monitorActivity + step` у App Group. Повтор саме цього
   identity ігнорується як `eventIgnored:duplicateIdentity`; різні steps не залежать від того,
   скільки секунд між їх delivery timestamps.
2. `AutoTrackingStore.drainPendingEvents()` дедублікує current-format записи за тим самим
   identity. Лише legacy записи без metadata мають короткий timestamp fallback.
3. `recordAutoTrackEvent` на сервері створює детермінований hash ID з
   `taskID + deviceID + usageDay + monitorActivity + step`. Тому різні кроки з однієї секунди
   стають різними raw events, а retry того самого кроку лишається ідемпотентним.

Це добре захищає від одного event, який iOS викликала двічі, не втрачаючи різні cumulative steps.
Для пачки distinct steps `TaskService` і server session writer додають по 60 секунд на step,
розміщуючи технічні межі перед доставкою пакета. Сесія отримує `hasEstimatedTiming = true`:
Reports включають підтверджену тривалість, diagnostics містить `credited packet`, і **з
2026-07-31 той самий реконструйований інтервал малюється й у Timeline** — як звичайний блок, без
візуального маркування "приблизно" (рішення користувача: те, що зараховано в Stats, має бути
видимим на Timeline). `autoTrackLastUsageAt`/Dynamic Island при цьому лишаються на реальному
delivery time — live UI не стрибає у майбутнє, розбіжність стосується лише історичного блока.

### Підтверджений приклад, 2026-07-30

Для TikTok extension отримав `step=7` о 17:03:04 (Kyiv), а потім `step=8, 9, 10, 11, 12, 13`
практично одночасно о 17:03:07. До рефакторингу швидкі кроки були відкинуті як
`eventIgnored:duplicateThreshold`. Тепер вони мають різні identity і обробляються. Пізніше
прийшли `step=15`, rearm, а з нової generation — рівні кроки 1…5.

Це доводить пакетну доставку різних порогів. Кожен окремий step є окремим досягнутим порогом,
тому він зараховується як 60 секунд; це не означає, що його точний момент у Timeline відомий.
Саме тому placement залишається консервативним, а server traces потрібні для перевірки результату.

### Що вважати успіхом / помилкою

- Якщо той самий `monitorActivity + step` повторився — це реальний duplicate, не зараховувати.
- Якщо різні кроки приходять пачкою, зарахувати один 60-секундний кредит на кожен distinct step.
- Не трактувати пакет як доказ того, що usage було безперервним від першого до останнього номера
  кроку; обидва writers ставлять цей кредит перед delivery time пакета.
- Ніколи не називати такий placement «точним початком usage».

## Серверна діагностика (додано 2026-07-30)

Щоб не покладатися на 300 записів у локальному extension buffer, Cloud Functions пишуть безпечні
технічні traces у:

```text
users/{uid}/liveActivityDiagnostics/{autoID}
```

Записи живуть 14 днів і чистяться `pruneLiveActivityDiagnostics` щодня. У них немає повного APNs
token або device secret; token записується лише як короткий suffix.

| `kind` | Де пишеться | Що відповідає |
|---|---|---|
| `thresholdAccepted` | `recordAutoTrackEvent` | Номер `thresholdStep`, monitor generation, час події, server session ID, чи відкрито нове live-вікно. |
| `thresholdRejected` | `recordAutoTrackEvent` | Відмова автентифікації/валідації або внутрішня помилка. |
| `liveActivityStartClaimed` | `onTaskTimerChanged` | Сервер прийняв право один раз стартувати Activity для конкретного session/window key. |
| `pushToStartAccepted` / `pushToStartFailed` | `onTaskTimerChanged` | APNs status, APNs id, suffix токена та destination device document. |
| `pushToStartSkipped` | `onTaskTimerChanged` | Немає addressable push-to-start token. |
| `activityTokenRegistered` | `registerLiveActivityPushToken` | iPhone вже побачив Activity й передав її update/end token серверу. |
| `activityTokenRegisteredAfterStop` | `registerLiveActivityPushToken` | Activity створилась пізно, після stop; сервер одразу відправив їй `end`. |
| `activityTokenRegistrationFailed` | `registerLiveActivityPushToken` | Реєстрація токена не завершилась. |
| `liveActivityEndAccepted` / `liveActivityEndFailed` | `onTaskTimerChanged`, `refreshLiveActivities`, `registerLiveActivityPushToken` | APNs прийняв / не прийняв саме ActivityKit `end`; `source` показує `taskStop`, `scheduledCleanup` або `registeredAfterStop`. Це підтверджує транспорт, але iOS не повертає окремий ACK фактичного зникнення Island. |
| `liveActivityEndFallbackWake` | `onTaskTimerChanged` | Немає per-activity token, тому сервер надіслав silent wake для локального reconcile; `outcome` показує прийняття чи помилку APNs. |
| `liveActivityEndSkippedNoToken` | `onTaskTimerChanged` | Немає ні per-activity token для `end`, ні адресного APNs token для fallback wake. |

`TaskService.reconcileServerLiveActivityDiagnostics()` читає нові записи під час запуску та
переходу app у `.active`, кладе їх у `DiagnosticsLog` як `[serverDiag]`, тому наступний
export містить повний trace. Водяний знак:
`liveActivity.serverDiagnosticsWatermark.{uid}`. При першому запуску імпортується максимум
останні 48 годин, щоб не засмічувати export старою історією.

## Як розслідувати новий випадок

1. Не очищати diagnostics і не міняти selection до експорту логу.
2. Зіставити локальний `[extension] eventDidReachThreshold…|step` з `[serverDiag]
   kind=thresholdAccepted` за task, step і часом.
3. Якщо extension event є, але `thresholdAccepted` немає — проблема в мережі, credential або
   extension runtime до сервера.
4. Якщо `thresholdAccepted` є, але `liveActivityStartClaimed`/`pushToStartAccepted` немає —
   перевіряти server transition і token пристрою.
5. Якщо `pushToStartAccepted` є, але `activityTokenRegistered` немає — APNs прийняв запит, але
   iOS не дала app достатньо runtime для реєстрації токена або не матеріалізувала Activity.
6. Для розбіжності статистики порахувати distinct `thresholdAccepted` та локальні
   `eventIgnored:duplicateIdentity`. Різні step однієї generation більше не мають відкидатися
   через близькі delivery timestamps; якщо це знову видно, identity-contract був зламаний.
7. Якщо є extension callback, але немає server trace, перевірити наступний launch/foreground:
   `drained N pending event(s)` і `recording usage window` підтверджують offline-first recovery.
8. Якщо replay з минулого створює новий блок замість extension існуючого, шукати
   `out-of-order replay refused`: це захист від злиття старого вікна з пізнішою сесією через
   ніч. Такий replay має залишитися окремою історичною сесією.

## План безпечного розвитку

1. **Збирати дані.** Перевірити, що server traces показують один `thresholdAccepted` на кожен
   distinct step і один на retry точної identity.
2. **Перевірити placement.** Зарахувати всі distinct steps — не те саме, що знати їх точний час.
   Для пакетів має бути `hasEstimatedTiming = true` і `credited packet` у diagnostics — це
   технічний слід реконструкції, не привід ховати блок. **З 2026-07-31 такі сесії малюються в
   Timeline так само, як будь-які інші** (рішення користувача: якщо час зарахований у Stats, він
   має бути видимим і на Timeline) — див. `AUTO_TRACKING.md`.
3. **Порівняти з Screen Time на серії днів.** Мета — зменшити великі недорахунки без системного
   завищення в дні з помилковими callback-ами.
4. **Перевірити повторний rearm.** Будь-яка зміна не має знову перетворити monitoring на
   щохвилинний `stopMonitoring`/`startMonitoring` цикл.
5. **Зберегти порядок replay.** `latestMergeableAutoTrackedSession` може зливати лише
   інтервали, що перетинаються, або короткий розрив у напрямку часу вперед. Ніколи не вважати
   великий від'ємний розрив «меншим за grace window».

## Задіяні файли

| Файл | Відповідальність |
|---|---|
| `AUTO_TRACKING.md` | Базова архітектурна карта автотрекінгу. |
| `AutoTrackingExtension/AutoTrackingExtension.swift` | Отримує DeviceActivity threshold, identity-дедуп за generation + step, **спочатку** пише local pending queue, виконує final-step rearm і HTTPS POST. |
| `TimeGrow/AutoTracking/AutoTrackingStore.swift` | Selection, arm/adopt monitor без cold-start reset, App Group drain, identity-дедуп і консервативне відновлення пакетів. |
| `TimeGrow/Store/TaskService.swift` | Local/server-event recovery, session merge, `hasEstimatedTiming` та import server traces в export. |
| `TimeGrow/TimeGrowApp.swift` | Викликає recovery і import diagnostics на launch/active. |
| `functions/src/index.ts` | `recordAutoTrackEvent`, server session materialization, push-to-start trace, trace retention. |
| `functions/src/apns.ts` | HTTP/2 APNs calls та APNs response id. |
| `TimeGrow/LiveActivity/LiveActivityManager.swift` | Отримує створену Activity та надсилає її per-activity token на сервер. |
| `TimeGrow/Helpers/DiagnosticsLog.swift` | Формує export, до якого потрапляють `[serverDiag]`. |
| `DYNAMIC_ISLAND.md` | Вузька карта старту/зупинки Live Activity; читати разом із цим файлом для push питання. |

## Заборони для майбутніх змін

- Не називати callback timestamp «точним usage time».
- Не зараховувати пакет різних steps без обраної й перевіреної моделі часу.
- Не прибирати локальну App Group чергу лише тому, що є сервер: це незалежний офлайн-запасний шлях.
- Не залежати від відкриття основного app для запису реальної сесії: `recordAutoTrackEvent` уже
  матеріалізує її на сервері.
- Не повертати щохвилинний rearm або короткий `intervalDidEnd` expiry watcher.
