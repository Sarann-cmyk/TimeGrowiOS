# Автотрекінг використання застосунків (Screen Time / DeviceActivity) — AI agent map

Останнє фактичне оновлення: 2026-07-21.

Цей файл — вузькоспеціалізована карта для частини TimeGrow, яка автоматично рахує час у задачі
на основі того, скільки на iPhone реально використовувався обраний застосунок (наприклад TikTok),
без ручного натискання Start. Загальна карта репозиторію — `AGENTS.md` в корені. Пов'язана, але
окрема тема — `DYNAMIC_ISLAND.md` (Dynamic Island/Live Activity); цей файл посилається на нього,
де логіка перетинається, і не дублює.

**Важливо:** у коді є ще один, повністю не пов'язаний механізм із тим самим префіксом
`autoTrack*` — `TrackingSettings`/`autoTrackStopDelaySeconds` (`TaskService.swift`, секція
`recover`/heartbeat). Це відновлення після зависання **ручного** таймера на іншому пристрої
(Mac), не має жодного стосунку до Screen Time. Не плутати.

## Що це і навіщо

Користувач один раз обирає в `FamilyActivityPicker`, які застосунки/категорії/домени
відповідають задачі (наприклад "TikTok" → задача "TikTok"). Далі, поки ці застосунки
використовуються на iPhone, TimeGrow сам створює/продовжує сесії часу для відповідної задачі —
без відкриття TimeGrow і без натискання Start.

## Ключова річ, яку варто зрозуміти першою: ми НЕ бачимо "застосунок відкрито"

iOS з міркувань приватності не дає жодного API виду "користувач зараз дивиться в TikTok".
Apple's `DeviceActivity` framework натомість дає лише **порогові сповіщення**: "з моменту
реєстрації цієї події сумарне використання обраних застосунків досягло N хвилин" —
і рахує саме сумарний **час використання**, не астрономічний час. Тобто:

- Немає події "застосунок відкрився/закрився".
- Є лише `eventDidReachThreshold`, яка спрацьовує, коли накопичилась ще одна повна хвилина
  реального використання (`threshold: DateComponents(minute: 1)`).
- Між спрацюваннями наш код не має жодної інформації про те, що відбувається — ні "усе ще
  використовується", ні "вже закрито". Тиша може означати і те, і те.

Це пояснює майже всі нетривіальні рішення нижче (вікна, склеювання сесій, grace-період).

## Ланцюжок розширення (`AutoTrackingExtension`)

Файл: `AutoTrackingExtension/AutoTrackingExtension.swift`, клас `DeviceActivityMonitorExtension`
(`DeviceActivityMonitor` extension target).

DeviceActivity-подія з порогом спрацьовує **один раз** за зареєстрований інтервал моніторингу —
але на один `startMonitoring` можна зареєструвати одразу **словник з кількох подій** із різними
порогами. Код реєструє одразу 15 накопичувальних порогів (1, 2, 3, … 15 хвилин) в одному
монітори, тож перереєстрація (`stopMonitoring`+`startMonitoring`) потрібна лише раз на ~15
хвилин безперервного використання, а не після кожної хвилини:

1. `scheduleMonitoring` (`AutoTrackingStore.swift`, головний застосунок) і `rearmMonitoring`
   (`AutoTrackingExtension.swift`) обидва будують словник подій через
   `accumulatedThresholdEvents(for:generation:)`: для `step` від 1 до
   `accumulatedThresholdStepCount` (=15) — подія з іменем `thresholdReached|\(generation)|\(step)`
   і `threshold: DateComponents(minute: step), includesPastActivity: false`.
2. `eventDidReachThreshold` (`AutoTrackingExtension.swift`) спрацьовує на кожен крок → записує
   подію в чергу App Group. `accumulatedStep(from:)` парсить `step` з імені події; лише коли
   `step == accumulatedThresholdStepCount` (останній, 15-й поріг цієї генерації вичерпано)
   викликається `rearmMonitoring(after:)`, який `stopMonitoring([activity])` +
   `startMonitoring(nextActivity, events: ...)` з новою генерацією (`"\(taskID)|\(UUID())"`) і
   свіжим набором 15 порогів. Для кроків 1...14 монітор нічого не перереєстровує — iOS сам
   продовжує рахувати накопичене використання до наступного порогу в тому самому моніторі.
3. `taskID(from:)` відрізає UUID-суфікс генерації від `DeviceActivityName`, щоб усі наступні
   генерації однієї задачі трактувались як одна логічна сутність у ключах `UserDefaults`.

`includesPastActivity: false` означає: щойно зареєстрований монітор рахує з нуля, будь-який
прогрес попереднього (вже зупиненого) монітора пропадає безповоротно — тому важливо, що
перереєстрація тепер трапляється рідше (раз на 15 хвилин, а не щохвилини).

`accumulatedThresholdStepCount` (15) — контрольне число для першого on-device прототипу.
Apple попереджає не реєструвати забагато DeviceActivity-моніторів одночасно; перш ніж піднімати
це число вище, варто перевірити на реальному пристрої, що всі 15 порогів одного монітора
доставляються надійно.

### Дедуплікація на рівні розширення

`minimumDistinctThresholdInterval = 55с` (`AutoTrackingExtension.swift:24`) — якщо дві події для
однієї задачі прийшли з інтервалом менше 55с, друга ігнорується
(`eventIgnored:duplicateThreshold`) — захист від зайвого double-counting при дрібних збоях
доставки, не основний механізм проти реальних затримок (див. нижче).

## Три шляхи, куди йде кожна подія

Кожна прийнята подія (`eventDidReachThreshold`) одночасно йде ТРЬОМА шляхами:

### 1. Сервер (Cloud Function) — near-real-time, для Live Activity І для самого блоку сесії

`submitAutoTrackEvent` (`AutoTrackingExtension.swift:110-`) синхронно (з таймаутом 3с) шле
POST на `recordAutoTrackEvent` (`functions/src/index.ts`) з `deviceID`/`deviceSecret`
(довгоживучий секрет пристрою, не Firebase ID-token — лишається дійсним і після нічного
закриття застосунку). Ця функція в одній транзакції пише в Firestore:
- `autoTrackLastUsageAt` / `autoTrackLiveUntil` / `autoTrackSessionStartedAt` /
  видаляє `autoTrackStoppedAt` на задачі. Саме цей запис — єдиний сигнал, який запускає
  push-to-start Dynamic Island (див. `DYNAMIC_ISLAND.md`).
- **З 2026-07-24**: сам документ `TaskTimeSession` (блок у Reports/Timeline) — продовжує
  (`endedAt` update) сесію, на яку вказує `autoTrackActiveSessionID` на задачі, якщо `liveUntil`
  ще не минув, або створює новий документ. Це означає блок з'являється на таймлайні **в реальному
  часі, без відкриття жодного застосунку** — раніше він з'являвся лише коли якийсь клієнт
  (iPhone/Mac) відкривався і вичитував локальну чергу чи `autoTrackEvents` (шляхи 2 і 3 нижче).
  `autoTrackActiveSessionID` — той самий покажчик на сесію, який пише і клієнт, тож обидва
  джерела продовжують один документ, а не форкають два.

### 2. Локальна черга (App Group) — офлайн-запасний шлях для клієнта

Подія також дописується в `autoTracking.pendingEvents` (спільний `UserDefaults(suiteName:
autoTrackingAppGroupID)`). До 2026-07-24 це було основне джерело `TaskTimeSession`; тепер сервер
(шлях 1) зазвичай встигає першим, а цей шлях — страховка на випадок, коли мережевий POST до
`recordAutoTrackEvent` взагалі не пройшов (немає інтернету в момент спрацювання розширення).
`recordAutoTrackedSession`'s merge-логіка (нижче) ідемпотентна: повторна обробка вже
відображеної сервером події просто продовжує той самий документ до того самого значення, без
дублю. Обробляється тільки коли головний застосунок відкривається/переходить у foreground:

- `AutoTrackingStore.drainPendingEvents()` (`AutoTrackingStore.swift:172-213`) — вичитує й чистить
  чергу, дедублікує події ближче ніж `minimumDistinctPendingEventInterval = 55с` одна до одної.
- `TaskService.processQueuedAutoTrackEvents` → `processQueuedAutoTrackEvents()`
  (`TaskService.swift:664-709`) — склеює сусідні події в "вікна" (`windows`), якщо розрив між
  ними ≤ `autoTrackingInactivityGraceSeconds`, і для кожного вікна викликає
  `recordAutoTrackedSession`.
- `recordAutoTrackedSession` (`TaskService.swift:711-794`) — або продовжує (`endedAt` update)
  останню сумісну сесію через `latestMergeableAutoTrackedSession` (`TaskService.swift:822-842`,
  теж за `autoTrackingInactivityGraceSeconds`), або створює новий документ `TaskTimeSession` у
  Firestore. **Тепер (2026-07-21) логує причину**, коли створює нову сесію замість продовження
  попередньої: `"starting new session for X instead of extending previous ... gap=Ns exceeds
  merge window=Ms"` — це прямий, без ручного підрахунку, лог на запитання "чому сесія
  розірвалась".

### 3. Серверна колекція `autoTrackEvents` — відновлення, коли локальна черга не доїхала

Додано 2026-07-23. `recordAutoTrackEvent` (`functions/src/index.ts`) в тій самій транзакції
ідемпотентно пише сирий запис у `users/{uid}/autoTrackEvents/{taskID}_{deviceID}_{occurredAtSec}`
(детермінований ID з таск/пристрій/секунда — повторний POST того самого callback перезаписує той
самий документ, не створює дублікат). Це не заміна локальної черги (шлях 2 лишається головним і
швидшим), а страховка на випадок, коли локальна `autoTracking.pendingEvents` ніколи не
доїжджає до `TaskService` — застосунок місяцями не відкривався, App Group контейнер втрачено,
перевстановлення тощо. iOS, що не доставила сам `eventDidReachThreshold`, цим не лікується —
лікується лише втрата вже прийнятої extension-ом події між нею й головним застосунком.

- `TaskService.reconcileServerAutoTrackEvents()` (`TaskService.swift`) — викликається з
  `TimeGrowApp.swift` поряд з кожним `processPendingAutoTrackEvents()` (при відкритті і при
  переході в `.active`). Читає `autoTrackEvents` де `createdAt` більше за локально збережений
  watermark (`autoTracking.serverEventsWatermark.<uid>` в `UserDefaults.standard`), просуває
  watermark і прогонює відновлені події через той самий `processPendingAutoTrackEvents` пайплайн,
  що й локальна черга.
- Навмисно watermark на `createdAt` (коли сервер прийняв подію), а не на `occurredAt` (коли вона
  сталась на пристрої) — подія, що сталась раніше, але доїхала пізніше через погану мережу,
  все одно потрапить у наступний прохід замість того, щоб застрягти за вже просунутим по
  `occurredAt` watermark-ом.
- Повторна обробка вже локально застосованої події — не проблема: `recordAutoTrackedSession`
  просто продовжує (`endedAt` update) те саме вікно до того самого значення, ідемпотентно.
- `pruneAutoTrackEvents` (`functions/src/index.ts`, `every 24 hours`) видаляє записи старші за
  `AUTO_TRACK_EVENT_RETENTION_MS = 14 днів` — колекція існує тільки для відновлення нещодавно
  пропущеного, не як вічний дублікат історії сесій.

## "Сесія" (`TaskTimeSession`) і "live"-стан (`autoTrackLiveUntil`) — це РІЗНІ речі

Легко переплутати, бо обидва звучать як "чи це ще той самий безперервний трекінг":

- **Сесія** — Firestore-документ, який малюється як блок у Reports/Timeline. Рішення про
  склеювання/розрив рахується **тільки на клієнті**, в `TaskService.swift` (шлях 2 вище).
- **Live-стан** (чи горить Dynamic Island, чи `LiveActivityManager.activeTimerStart` вважає
  задачу запущеною) — читається з `autoTrackLiveUntil` на задачі. Це поле **пишеться і сервером
  (Cloud Function), і клієнтом**, і сервер зазвичай встигає першим (він пише синхронно в
  момент кожної події, клієнт — лише коли застосунок відкриють).

Це означає: клієнтський grace-період впливає на те, чи склеяться сесії в Reports. Але на те, чи
живе Dynamic Island прямо зараз, найбільше впливає **серверна** константа
`AUTO_TRACK_LIVE_GRACE_MS` — з 2026-07-23 синхронізована з клієнтською (обидві 300с).

## Ключові константи (і де кожна продубльована)

| Константа | Значення | Де | Що робить |
|---|---|---|---|
| `autoTrackingThresholdSeconds` | 60с | `AutoTrackingStore.swift:14`, `AutoTrackingExtension.swift` (`thresholdSeconds`) | Розмір одного порогу DeviceActivity; кожна прийнята подія = рівно +60с у вікні, незалежно від того, скільки реального часу пройшло до її отримання. |
| `autoTrackingInactivityGraceSeconds` | **300с (5хв)**, піднято 2026-07-21 з 180с | `AutoTrackingStore.swift:15-22` (глобальна, `let`, доступна всьому app target), продубльована як `inactivityGraceSeconds` в `AutoTrackingExtension.swift:22-25` (окремий target — не може імпортувати з app target) | "Це ще та сама сесія?" — і для склеювання `TaskTimeSession`, і для того, чи резюмувати `sessionStartedAt` в розширенні. **Обидва місця треба міняти разом.** |
| `AUTO_TRACK_LIVE_GRACE_MS` | **300 000мс (5хв)**, піднято 2026-07-23 з 180 000мс | `functions/src/index.ts` | Те саме поняття "ще жива", але на сервері, для `autoTrackLiveUntil`, який реально визначає, коли гасне Dynamic Island. Тепер синхронізована з клієнтським `autoTrackingInactivityGraceSeconds`. |
| `minimumDistinctThresholdInterval` | 55с | `AutoTrackingExtension.swift:24` | Дедуп у розширенні: друга подія для тієї ж задачі раніше ніж за 55с — ігнорується. |
| `minimumDistinctPendingEventInterval` | 55с | `AutoTrackingStore.swift:23` | Той самий дедуп, але при вичитуванні черги в головному застосунку (друга лінія захисту). |
| `thresholdDelayWarningSeconds` | 90с | `AutoTrackingExtension.swift:28` | Поріг для діагностичного логування "ця подія прийшла підозріло пізно" (див. нижче). |
| `minimumTrackedSessionDuration` | 3с | `AutoTrackingStore.swift:18` | Сесії коротші за це видаляються повністю при зупинці — випадкові дотики, не реальний трекінг. |

## Відоме, непоправне на нашому боці обмеження: iOS не гарантує швидку доставку `eventDidReachThreshold`

Розслідування 2026-07-20/21 (реальний кейс: користувач безперервно сидів у TikTok 07:29–08:12,
жодного разу не згортав його, але Dynamic Island погас, а сесія розірвалась на дві).

Факти з логів (діагностичний файл `TimeGrow-diagnostics-2026-07-21_085427.log`):
- До розриву: 27 спрацювань поспіль, рівно раз на ~62с, без жодного збою (04:29:59–04:57:17 UTC).
- Розрив: **299 секунд повної тиші** — жодного `intervalDidEnd`/`rearmed`/`eventDidReachThreshold`
  для розширення взагалі. Не поступова деградація — одна чиста діра.
- Після розриву: знову ідеальний ритм ~60-65с, без жодних змін у поведінці.

Apple офіційно не документує `DeviceActivityMonitor` як механізм реального часу — доставка
best-effort, без SLA і без опублікованої верхньої межі затримки. Найправдоподібніша гіпотеза
(непідтверджена документально, бо Apple не публікує алгоритм): наша власна архітектура
(повна перереєстрація монітора з новим `DeviceActivityName` **щохвилини, безперервно**) — це
саме той патерн високочастотного будження фонового розширення, який iOS-івський захист
батареї навчений розпізнавати й притримувати. 27 перезапусків поспіль за пів години — це багато
для фонового розширення.

**Спостережені реальні значення затримки** (через новий лічильник `thresholdDelay`, див. нижче):
156с і 299с у межах підтверджено безперервного використання; є й куди більші (12640с, 26679с),
але ті — законні нічні/денні паузи, не збої доставки.

Висновок: цю затримку не можна усунути в нашому коді — Apple навмисно не дає важіль форсувати
часті пробудження розширення. Єдине, що можна зробити — розширити grace-вікно (див. константи
вище), щоб типові затримки в кілька хвилин не розривали видиму поведінку (сесію, Dynamic Island).

## Діагностика — де саме дивитись у diagnostics-лозі

Усі нижченаведені рядки з'являються в тексті, який повертає `DiagnosticsLog.exportText()`
(кнопка поділитись логами в застосунку):

- `[autoTrack] extension debug: thresholdDelay expected=60s actual=Ns creditedToday=... unaccountedToday=...`
  — подія прийшла суттєво пізніше очікуваного (>90с). `N` — фактична затримка в секундах.
  (`AutoTrackingExtension.swift`, `recordThresholdAccounting`)
- `--- Auto-track totals today (per task) ---` / `task=X credited=Ym Zs unaccounted~=Am Bs`
  — підсумок за поточний локальний день: скільки реально зараховано і скільки часу пройшло без
  жодного зарахування. Скидається щодня. (`DiagnosticsLog.swift`, `autoTrackTotalsSummary`)
- `[autoTrack] starting new session for X instead of extending previous (ended ...): gap=Ns
  exceeds merge window=Ms` — момент і причина розриву сесії. (`TaskService.swift`,
  `recordAutoTrackedSession`)
- `[liveActivity] Ending Live Activity task=... after reconciliation grace autoTrackLiveUntil=...
  autoTrackStoppedAt=... autoTrackSessionStartedAt=...` — повний стан задачі в момент, коли
  Dynamic Island гаситься. (`LiveActivityManager.swift`, `scheduleEndAfterReconciliationGrace`)
- `[autoTrack] adopted live DeviceActivity monitor for task X activity=...` /
  `stopped N orphaned DeviceActivity monitor(s) at launch: ...` — що сталось із моніторингом при
  відкритті застосунку (див. наступний розділ). (`AutoTrackingStore.swift`,
  `adoptExistingMonitoring`)
- `[autoTrack] recording usage window for X from=... to=... events=N` /
  `wrote new session ...` / `extended session ...` — власне побудова вікон і запис у Firestore.
  (`TaskService.swift`)

## Виправлений баг: скидання моніторингу при кожному холодному старті (2026-07-20)

До виправлення: `AutoTrackingStore.refreshMonitoring` при першому виклику за запуск застосунку
безумовно викликав `activityCenter.stopMonitoring()` (зупинити геть усе) і реєстрував усі задачі
заново. Побічний ефект: якщо в момент відкриття TimeGrow розширення вже накопичувало прогрес до
наступної хвилини (a живий, ще не спрацьований монітор) — цей прогрес просто викидався.
Що частіше iOS вбиває TimeGrow у фоні й користувач його переоткриває, то більше таких втрат
за день.

Виправлення: `adoptExistingMonitoring` (`AutoTrackingStore.swift`) перед скиданням перевіряє,
чи `DeviceActivityCenter().activities` все ще містить монітор, записаний розширенням у спільні
`UserDefaults` (`monitoredActivityKeyPrefix`) для цієї задачі з відповідним selection'ом — якщо
так, просто "усиновлює" його замість перезапуску. Зупиняються лише дійсно осиротілі активності.

## Файли, що стосуються автотрекінгу

- `AutoTrackingExtension/AutoTrackingExtension.swift` — `DeviceActivityMonitor` extension:
  прийом порогових подій, rearm-ланцюжок, підрахунок затримок, синхронізація з сервером.
- `TimeGrow/AutoTracking/AutoTrackingStore.swift` — `@MainActor` `ObservableObject`: авторизація
  Screen Time, збереження вибору застосунків per-задача, реєстрація/усиновлення/зупинка
  `DeviceActivityCenter`-моніторингу, вичитування черги подій.
- `TimeGrow/AutoTracking/AutoTrackingPickerView.swift` — UI вибору застосунків/категорій
  (`FamilyActivityPicker`) для задачі.
- `TimeGrow/Store/TaskService.swift` — обробка черги подій у вікна, склеювання/створення сесій
  (`processQueuedAutoTrackEvents`, `recordAutoTrackedSession`,
  `latestMergeableAutoTrackedSession`), явна зупинка (`stopAutoTracking`).
- `TimeGrow/Models/TGTask.swift` — поля стану: `autoTrackLastUsageAt`, `autoTrackLiveUntil`,
  `autoTrackActiveSessionID`, `autoTrackSessionStartedAt`, `autoTrackStoppedAt`.
- `TimeGrow/Helpers/DiagnosticsLog.swift` — персистентний, експортований лог + щоденний
  підсумок credited/unaccounted per-задача.
- `functions/src/index.ts` — `recordAutoTrackEvent` (HTTP-функція, приймає подію від розширення
  напряму через пристрій-секрет), `activeTimerStart` (дзеркало клієнтської логіки "чи запущено"
  для серверних рішень про push).
- `TimeGrow/LiveActivity/LiveActivityManager.swift` — `activeTimerStart` (клієнтське дзеркало
  тієї ж перевірки) — див. `DYNAMIC_ISLAND.md` для решти Live Activity логіки.

## Відомі пастки / TODO

- **Не додавай назад `DeviceActivityMonitor.intervalDidEnd`-based "expiry watcher"** — вже
  задокументовано в `DYNAMIC_ISLAND.md` ("Автотрекінг (локальний тригер на iPhone)"), там же
  причина (закороткий `DeviceActivitySchedule` ламав `rearmMonitoring`).
- **Розширення НЕ може стартувати Live Activity напряму** (sandbox-обмеження, підтверджено
  зламано) — весь шлях іде через Firestore-запис → Cloud Function → push-to-start. Детально в
  `DYNAMIC_ISLAND.md`.
- **Не плутати з `TrackingSettings`/`autoTrackStopDelaySeconds`** (`TaskService.swift`, секція
  `recover`) — це відновлення ручного таймера після зависання іншого пристрою, ніяк не пов'язане
  з Screen Time-трекінгом, описаним у цьому файлі.
