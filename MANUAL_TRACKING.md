# Старт/стоп ручного таймера на телефоні — AI agent map

Останнє фактичне оновлення: 2026-07-31.

Цей файл — вузькоспеціалізована карта для частини TimeGrow, яка керує **ручним** таймером
(користувач сам тисне на рядок задачі, щоб почати/зупинити відлік) — на відміну від автотрекінгу
через Screen Time, який описаний у `AUTO_TRACKING.md`. Загальна карта репозиторію — `AGENTS.md`
в корені. Пов'язана, але окрема тема — `DYNAMIC_ISLAND.md` (Dynamic Island/Live Activity); цей
файл посилається на нього, де логіка перетинається, і не дублює internals `LiveActivityManager`.

**Фокус цього файлу** — конкретно затримки й нестабільна поведінка, які користувач спостерігає
під час звичайного тапу: "натиснув Start — таймер починає тікати за 2-3с", "натиснув Stop —
зупинка трапляється аж за ~4с", "зупинив — а він сам активувався за пару секунд". Нижче — де саме
в коді народжується кожна з цих затримок, і чому.

## Модель даних одного ручного таймера

Ручний таймер — це не окремий тип, а стан на самому документі задачі (`TGTask`,
`TimeGrow/Models/TGTask.swift`) плюс один `TaskTimeSession`-документ з `startedAutomatically ==
false`:

- `task.timerStartedAt` — коли почався поточний запуск. `task.isTimerRunning` == `timerStartedAt
  != nil`. Це поле — єдине джерело правди для "чи запущено" всюди в UI (`TaskRowView`,
  `TaskTileView`, `TimelineTabView`, `ContentView`).
- `task.activeSessionID` — id відповідного `TaskTimeSession`.
- `task.timerOwnerDeviceID` / `timerOwnerPlatform` / `timerOwnerDeviceName` /
  `timerOwnerLastAliveAt` / `timerOwnerIsActive` — який пристрій володіє цим запуском.
  Актуально для крос-пристрійного сценарію (той самий акаунт на iPhone і Mac) — див.
  `timerOwnerStatus(for:)` і розділ "Крос-пристрійні гонки" нижче.

## Крок 0: що насправді вирішує сам тап

Це пропущений на першому проході крок — тап на рядку **не** одразу викликає
`startTimer`/`stopTimer`. Обробник (`TaskRowView.swift:36-49`, **дослівно продубльований** у
`TaskTileView.swift:36-49` — два окремі місця, які треба міняти разом) спершу вирішує, яку з трьох
дій викликати:

```swift
.onTapGesture {
    Haptics.impact(.light)
    if !task.isTimerRunning, isAutoTrackLive(at: Date()) {
        stopAutoTrackAction()   // → TaskService.stopAutoTracking(for:) — НЕ stopTimer!
    } else {
        onToggleTimer()         // → ContentView.toggleTimer → startTimer АБО stopTimer
    }
}
```

- `Haptics.impact(.light)` — спрацьовує синхронно на будь-який тап, до будь-якої мережевої дії.
- **Гілка 1:** якщо `task.isTimerRunning == false`, але рядок усе одно виглядає активним через
  auto-track grace-вікно (`isAutoTrackLive(at:)`, той самий метод, що й у розділі "Реактивація"
  нижче) — тап викликає `stopAutoTrackAction()` → `TaskService.stopAutoTracking(for:)`
  (`TaskService.swift:1423-1440`, докладно в `AUTO_TRACKING.md`). Це **інша функція**, ніж
  `stopTimer` — вона лише виставляє `autoTrackStoppedAt`/`autoTrackLiveUntil` на вже закритій
  сесії, нічого не робить із `timerStartedAt` (бо його й не було).
- **Гілка 2:** інакше — `onToggleTimer()`, який в `ContentView.toggleTimer(_:)`
  (`ContentView.swift:256-262`) дивиться на `task.isTimerRunning` і викликає `startTimer` або
  `stopTimer`, описані нижче.

Практичний наслідок: якщо рядок у момент тапу показує "активно" **лише** через auto-track
grace-вікно (а не через реальний ручний запуск), тап його **не запускає ручний таймер** — він
гасить auto-track-стан. Другий тап після цього вже піде гілкою 2 і реально стартує ручний таймер.
З боку користувача це може виглядати як "перший тап не подіяв" — насправді подіяв, просто інакше,
ніж очікувалось.

## Старт: `TaskService.startTimer(for:at:startedAutomatically:)`

Файл: `TimeGrow/Store/TaskService.swift:745-841`. Викликається з `ContentView.toggleTimer`
(`TimeGrow/Views/ContentView.swift:256-262`) напряму, без проміжного шару — тап на рядку в
`TaskRowView`/`TaskTileView` викликає `onToggleTimer()` closure синхронно.

Послідовність:

1. Guard: `!task.isTimerRunning && optimisticTimerStarts[id] == nil` — подвійний тап або тап під
   час незавершеного попереднього старту ігнорується (`DiagnosticsLog` рядок `startTimer
   ignored`).
2. `applyOptimisticTimerStart` (`TaskService.swift:851-886`) — **синхронно**, на `@MainActor`,
   оновлює `tasks[taskIndex]` **одним** присвоєнням (не сімома окремими мутаціями полів — це
   навмисно, див. коментар на місці і розділ нижче). Це і є момент, коли рядок в UI має
   перемалюватись з "не запущено" на "запущено" — має бути в межах одного SwiftUI update циклу,
   без мережевого round-trip.
3. `db.runTransaction` — атомарно перевіряє на сервері, що `timerStartedAt` все ще `nil` (захист
   від гонки з іншим пристроєм/тригером, що стартував той самий таск на 100мс раніше — див.
   коментар `TaskService.swift:787-792`, "mirrors the Mac app's fix for duplicate timeline blocks,
   2026-07-25"), і лише тоді пише сесію + оновлення таска. Якщо програв гонку — `rollbackOptimisticTimerStart`
   відкатує локальний оптимізм; справжній власник прийде через listener.
4. Якщо транзакція технічно не змогла виконатись (офлайн, timeout) — фолбек на прямі
   `setData`/`updateData` без транзакційного захисту (`TaskService.swift:822-829`).

### Чому "тікати" починає не миттєво

Два **незалежні** таймери реагують на один і той самий старт, з дуже різною швидкістю:

- **Рядок у списку задач / аватар з кільцем прогресу** — має оновитись практично миттєво (крок 2
  вище — синхронний, до будь-якого мережевого виклику). Якщо тут реально відчутна затримка в
  секунди — дивись `[timer] manual start tap ...` / `[timer] manual start rendered ... latencyMs=N`
  у diagnostics-лозі (`TaskRowView.swift:26-30, 47-52` — вимірює саме "тап → `task.isTimerRunning`
  став `true`" end-to-end, щоб не гадати, в якій стадії затримка: розпізнавання жесту, Firestore
  round-trip чи SwiftUI re-render). До фіксу 2026-07-24 тут реально було ~700-800мс через сім
  окремих мутацій `tasks[taskIndex].X = ...`, кожна з яких форсила окремий `didSet` →
  `LiveActivityManager.reconcile` `Task` (`TaskService.swift:859-865`). Зараз має бути одне
  присвоєння.
- **Dynamic Island / Live Activity** — це окремий шлях і саме тут найімовірніше живуть "2-3
  секунди". `TaskService.tasks`'s `didSet` → `scheduleLiveActivityReconciliationIfNeeded`
  (`TaskService.swift:178-196`) навмисно чекає `Task.yield()` + **100мс** сну, щоб UI-рядок встиг
  промалюватись до того, як почнеться `ActivityKit`-робота, і лише тоді викликає
  `LiveActivityManager.reconcile(tasks:)` → `start(for:startedAt:)` →
  `Activity.request(...)` (`LiveActivityManager.swift:267-294`). `Activity.request` — це
  синхронний IPC-виклик у демон ActivityKit; Apple не публікує SLA, і на реальному пристрої він
  сам по собі може зайняти від кількасот мс до 1-3с (холодний виклик, перша активність за сесію,
  завантаженість системи). Це **не** наша затримка коду — вона видна в лозі як `requestMs=N` у
  рядку `Started Live Activity for X id=... requestMs=N` (`LiveActivityManager.swift:287-290`).
  Якщо "тікати починає за 2-3с" — це майже напевно про Dynamic Island: складіть 100мс coalesce-сон
  + `requestMs` з логу.

### Крос-пристрійні гонки при старті

`db.runTransaction` на кроці 3 гарантує, що з двох одночасних стартів (напр. тап на iPhone і на
Mac за секунди) виграє лише один запис у Firestore — другий програє і відкочується. Це захищає
від дубльованого блоку на Timeline, але **не** від видимої затримки: пристрій, що програв гонку,
на секунду-дві показує себе "запущеним" (оптимістично), а потім listener приносить справжній
стан іншого власника і повертає рядок назад у "не запущено". З боку користувача це виглядає як
"натиснув — запустилось — саме зупинилось".

## Стоп: `TaskService.stopTimer(for:)` → `stopTimer(for:endedAt:reason:)`

Файл: `TaskService.swift:1386-1442-` (приватна версія з `reason`). Викликається так само напряму
з `ContentView.toggleTimer`.

1. `applyOptimisticTimerStop` (`TaskService.swift:1481-1517`) — синхронно чистить
   `timerStartedAt`/`activeSessionID`/`timerOwner*` в локальному `tasks[taskIndex]`. Це і є
   момент, коли рядок у списку реально гаситься — **тепер справді миттєво** (див. фікс
   2026-07-31 нижче; до нього це твердження було невірним і саме воно ховало реальний баг).
2. Firestore-запис: `FieldValue.delete()` для власницьких полів таска +, **з фіксу 2026-07-31**,
   `autoTrackStoppedAt`/`autoTrackLiveUntil`, якщо сесія, що зупиняється, сама була автотрекінговою
   (`wasAutoTracked = activeSession(for: task)?.startedAutomatically == true`) — див. розділ
   "Реактивація після Stop" нижче, чому це важливо і чому досі не покриває всі випадки.
3. Якщо `endedAt - startedAt < minimumTrackedSessionDuration` (3с, `AutoTrackingStore.swift:30` —
   константа спільна з автотрекінгом) — Firestore-документ сесії видаляється повністю замість
   запису `endedAt`: випадковий подвійний тап "старт-стоп" не лишає сміттєвого нульового блоку
   в Reports. Локальний масив `sessions` теж прибирає його — але, як і звичайне `endedAt`,
   відкладено (крок нижче).

### Виправлений баг (2026-07-31): `sessions`-мутація тримала перемальовку рядка в заручниках

Діагностика реального пристрою (`TimeGrow-diagnostics-2026-07-31_130815.log`) показала стабільну
паузу **1-2.2с** саме на Stop — між рядком логу `[timer] stopTimer task=...` і буквально наступним
рядком того самого синхронного tap-обробника (`onToggleTimer()` → одразу
`log("...onToggleTimer returned...")`, без жодного `await` між ними, `TaskRowView.swift:36-49`).
Для Start такої паузи не було (`latencyMs` у діагностиці — одноцифрові/низькі двозначні мс).

Причина: `applyOptimisticTimerStop` до фіксу мутувало `sessions[sessionIndex].endedAt = endedAt`
**синхронно**, на тому самому виклику, що й флаг `task.isTimerRunning`. Ця мутація `@Published
sessions` синхронно перебудовує `sessionsByTaskID` (`TaskService.swift:61-65`) і викликає
`CalendarSyncManager.shared.observeSessions(...)` — а той на той момент, якщо в користувача була
увімкнена синхронізація з Apple Calendar, проходив по **всьому** 30-денному кешу і робив окремий
`eventStore.save(event, ..., commit: true)` (синхронний EventKit-запис) для кожної
(`CalendarSyncManager.swift:153-190`). `task.isTimerRunning` логічно вже `false` в цей момент, але
SwiftUI фізично не може перемалювати екран, поки головний потік зайнятий цією роботою — тому
рядок "тримався" активним, попри те, що стан уже був змінений.

Старт від самого початку **не мав** цієї проблеми — `applyOptimisticTimerStart` навмисно відкладає
вставку сесії через `scheduleOptimisticSessionInsertion` (`Task.yield()` + 100мс сон,
`TaskService.swift:888-903`; коментар прямо каже: rebuild `sessions` "may take hundreds of
milliseconds", тож він має відбутись **після** того, як SwiftUI відмалює новий активний стан).

**Фікс:** `applyOptimisticTimerStop` тепер робить лише синхронну частину — мутацію `tasks`. Сама
мутація `sessions` (і `endedAt`, і видалення для короткої сесії) винесена в новий
`scheduleOptimisticSessionEnd` (`TaskService.swift:1520-1541`) — той самий `Task.yield()` + 100мс
патерн, що й у старту. Firestore-записи для сесії лишились синхронними/fire-and-forget у самому
`stopTimer` (`TaskService.swift:1442-`) — вони й раніше не блокували, блокувала саме локальна
мутація масиву.

### Виправлений баг (2026-08-01): Calendar sync блокував запуск і переходи між вкладками

Навіть після defer мутації `sessions` Firestore snapshot на запуску все одно передавав весь
30-денний кеш у `CalendarSyncManager`, а старий `synchronize` безумовно робив окремий
`eventStore.save(..., commit: true)` для кожної сесії на main actor. З увімкненою синхронізацією
це давало видимі зависання приблизно на 3–5с при відкритті застосунку або коли snapshot приходив
під час переходу між вкладками.

Тепер `observeSessions` coalesce-ить cache/server snapshots на 300мс і дає SwiftUI відмалювати
кадр. `synchronize` порівнює існуючу подію з бажаним станом, пропускає незмінені записи, stage-ить
лише реальні зміни з `commit: false`, а потім виконує один `eventStore.commit()` на весь batch.
Diagnostics пише `[performance] Calendar sync completed in ...` для повільних/непорожніх batch-ів.

### Виправлений баг (2026-07-31): Stop міг зупиняти сесію, якої ще не існувало на сервері — вона лишалась "вічно запущеною"

Другий, серйозніший баг, знайдений у тому самому діагностичному циклі
(`TimeGrow-diagnostics-2026-07-31_134552.log`), під час швидкого тестування Старт/Стоп поспіль:

```
10:33:04.861  [timer] manual start tap task=БІБЛІЯ ...
10:33:08.617  [timer] stopTimer task=БІБЛІЯ reason=manual ...            ← стоп через ~3.75с
10:33:09.665  [timer] startTimer committed task=... session=ybtZZi9S371rmsiW4emB   ← коміт старту через ~1с ПІСЛЯ стопу
```

`startTimer`'s `db.runTransaction` (`TaskService.swift:793-814`) **вимагає реального round-trip
до сервера** — на відміну від звичайного `setData`/`updateData`, транзакція не застосовується
проти локального кешу одразу. Якщо мережа повільна (або йде злива швидких тапів, як тут), коміт
може зайняти кілька секунд. Стара версія `stopTimer` про це не знала: вона одразу слала

```swift
sessionsCollection(for: uid).document(sessionID).updateData(["endedAt": ...])
```

**без жодної обробки помилки.** `updateData` вимагає, щоб документ уже існував — якщо стоп летить
до сервера раніше, ніж транзакція старту встигла створити цей самий документ сесії, запис
провалюється мовчки. Сесію зрештою створює (із запізненням) транзакція старту — але без
`endedAt`. Для ручних сесій жодного іншого механізму "закрити" її нема (на відміну від
автотрекінгових, у яких є watchdog-и) — вона лишається видимою як "запущена" й у Reports/Timeline
рендериться аж до "зараз" щоразу, коли екран відкривають. Саме так з'являється блок на 15-20+
хвилин, хоча реальний тап тривав секунди.

**Фікс:** новий `sessionCreationInFlight: Set<String>` (`TaskService.swift:118`) відстежує
sessionID, чия транзакція старту ще не резолвилась; `startTimer` додає його перед
`db.runTransaction` (`TaskService.swift:786`) і знімає через `resolveSessionCreation(sessionID:
created:)` (`TaskService.swift:1524-1529`) у кожній з трьох гілок завершення — комітнута
транзакція, офлайн-фолбек на прямий `setData` (він застосовується до кешу миттєво, тож для нього
гонки нема — резолвиться відразу як `created: true`), і відхилена транзакція (`created: false` —
рахувати нема чого, сесію так і не створили). `stopTimer` тепер іде через
`finishSessionStop(uid:sessionID:endedAt:isShortSession:)` (`TaskService.swift:1500-1508`): якщо
`sessionID` усе ще в `sessionCreationInFlight`, реальний Firestore-запис (`applySessionStopWrite`,
`TaskService.swift:1510-1517`) відкладається в `pendingSessionStopActions` і виконується лише
після резолву — так само, як стоп-версія оптимістичного мутування `sessions`, локальний UI
лишається миттєвим, відкладається тільки сам мережевий запис.

### Safety-сітка (2026-07-31): `reconcileOrphanedManualSessions`

Фікс вище закриває race **наперед**, але (а) не лікує вже зіпсовані документи, що встигли
накопичитись до фіксу, і (б) не рятує від того самого результату, якщо застосунок вб'ють
(force-quit/crash) саме в проміжку між тим, як стоп поставили в чергу `pendingSessionStopActions`,
і тим, як вона реально спрацювала — ця черга живе лише в пам'яті, не персиститься. Обидва випадки
дають один і той самий артефакт: ручна сесія з `endedAt: nil`, яку жодна задача більше не називає
своєю `activeSessionID` (сам таск давно коректно зупинений — саме тому проблему важко помітити:
рядок у списку задач не "тікає", бо `task.isTimerRunning` вже `false`; висить лише сам запис сесії
в Reports/Timeline, статично, як "у процесі").

`reconcileOrphanedManualSessions` (`TaskService.swift:1900-1930`, викликається в кінці
`observeSessions`'s snapshot-колбека, `TaskService.swift:510-519`, кожен раз, коли приходить новий
знімок сесій) шукає сесії, де: `endedAt == nil`, `startedAutomatically != true` (авто-трекінгові
сесії пишуться напряму, без транзакції — на них ця гонка не може статись), `startedAt` старіше за
`orphanedSessionGraceSeconds` (**300с**, `TaskService.swift:131-134` — щоб не займатись сесією, яка
просто ще в нормальному, короткому вікні свого створення), і жоден `task.activeSessionID` на неї
не вказує. Для кожної знайденої — видаляє документ повністю, а не вигадує правдоподібний
`endedAt`: реальної тривалості ми надійно не знаємо, тож поводимось як і зі звичайною
"закороткою, щоб рахувати" сесією (`minimumTrackedSessionDuration`).

### Чому Stop раніше "тримався" довше, ніж очікувалось (Dynamic Island)

Окремо від щойно виправленого багу, **Dynamic Island — навмисно** не гасне миттєво навіть після
фіксу вище. `LiveActivityManager.scheduleEndAfterReconciliationGrace`
(`LiveActivityManager.swift:210-259`) чекає рівно **2 секунди** (`Task.sleep(for: .seconds(2))`),
перш ніж реально викликати `activity.end(...)`, і лише якщо до кінця цих 2с жоден новіший знімок
задач не показав таск знову запущеним. Причина grace-періоду задокументована прямо в коді
(`LiveActivityManager.swift:51-54`): Firestore може на мить віддати проміжний/неповний документ
задачі, поки паралельно мерджаться записи auto-track/push-token/timer — миттєве завершення
активності з цього одного знімка дає видимий "блимок" Dynamic Island навіть коли наступний
знімок каже, що таск усе ще йде.

Разом: 100мс coalesce-затримка перед тим, як `reconcile` взагалі побачить зупинку, + 2с
навмисний grace + сам виклик `activity.end()` (IPC, теж не миттєвий) — легко складається в ~2.5-4с
від тапу Stop до реального зникнення з Dynamic Island. Це за дизайном, не баг у сенсі "щось
зламано" — це свідомий компроміс "трохи повільніше зникає" проти "блимає під час звичайного
мерджу записів". Лог для перевірки: `[liveActivity] Deferring Live Activity end task=... id=...`
→ (за 2с) → `[liveActivity] Ending Live Activity task=... after reconciliation grace ...` або
`Cancelled deferred end ...; task resumed in later snapshot`, якщо скасувалось.

## Реактивація після Stop — два різні механізми

Користувач може натиснути Stop і за кілька секунд побачити, що таймер знову виглядає активним.
Це не один баг, а дві різні, накладені одна на одну причини:

### 1. Dynamic Island "блимає назад" (та сама 2-секундна грейс-логіка вище)

Якщо протягом 2-секундного `scheduleEndAfterReconciliationGrace`-вікна прийде **будь-який**
проміжний/застарілий знімок `tasks`, де цей таск усе ще виглядає запущеним (наприклад, локальний
Firestore-кеш ще не встиг застосувати щойно відправлений `FieldValue.delete()`, або паралельний
запис від автотрекінгу того ж таска перекрив кадр), `reconcile()` скасовує заплановане завершення
(`cancelPendingEnd`, лог `Cancelled deferred end id=...; task is running`) — і Dynamic Island
лишається/повертається до активного вигляду, хоча користувач щойно натиснув Stop.

### 2. Автотрекінг реально відкриває нове "живе" вікно для того самого таска

Це серйозніший випадок і головна підозра для "сам активувався за пару секунд" саме на **рядку
в списку задач** (не тільки Dynamic Island). Якщо для цього таска налаштоване стеження Screen
Time (`AUTO_TRACKING.md`) і застосунок/сайт, який стежиться, продовжує використовуватись
**після** ручного Stop — наступний поріг `DeviceActivity` (`eventDidReachThreshold`) все одно
прийде і пройде через звичайний конвеєр (`processQueuedAutoTrackEvents` →
`recordAutoTrackedSession` → `applyOptimisticAutoTrackLiveState`,
`TaskService.swift:1121-1270`). Це вмикає `isAutoTrackLive`-стан на рядку
(`TaskRowView.autoTrackLiveSession`, `TaskRowView.swift:180-190`) — пульсуючий колір і лічильник
знову ростуть, хоча жодного ручного Start не було.

`shouldPublishAutoTrackLiveState`/`latestMergeableAutoTrackedSession` явно перевіряють
`task.autoTrackStoppedAt` і відмовляються продовжувати/публікувати вікно, що почалось до
зафіксованого стопу (`TaskService.swift:1191, 1294-1299, 1318-1321, 1366`) — **але тільки якщо
`autoTrackStoppedAt` взагалі виставлено**. Фікс 2026-07-31 (розділ "Стоп" вище) закриває це для
випадку, коли **сама зупинена сесія була автотрекінговою**. Він **не** закриває інший випадок:
таск запущено **вручну** (`startedAutomatically == false`), користувач тисне ручний Stop — це
проходить через ту саму `stopTimer`, але `wasAutoTracked` там `false` (сесія, яку зупиняють, —
ручна), тож `autoTrackStoppedAt` не пишеться. Якщо для цього ж таска паралельно ввімкнено Screen
Time-стеження й моніторинг усе ще накопичує використання — щойно прийде черговий поріг, він
відкриє нове auto-track "живе" вікно так, ніби ручного Stop не було. **Це відкрита прогалина, не
виправлена в цьому проході** — див. TODO нижче.

## Ключові константи (і де кожна продубльована)

| Константа | Значення | Де | Що робить |
|---|---|---|---|
| `minimumTrackedSessionDuration` | 3с | `AutoTrackingStore.swift:30`, використовується і в ручному, і в автотрекінг-стопі | Сесії коротші за це видаляються повністю при зупинці замість запису `endedAt`. |
| Live Activity start-to-render coalesce | 100мс | `TaskService.swift:191` (`scheduleLiveActivityReconciliationIfNeeded`) | Дає рядку в списку промалюватись до початку `ActivityKit`-роботи; коалесує послідовні снапшоти в один reconcile-виклик. |
| Live Activity end grace | 2с | `LiveActivityManager.swift:222` (`scheduleEndAfterReconciliationGrace`) | Захищає від видимого "блимка" Dynamic Island через проміжний/неповний Firestore-знімок під час зупинки. |
| `interruptedMacHeartbeatGrace` | 180с | `TaskService.swift:124` | **Не про це.** Відновлення після зависання ручного таймера на **іншому** пристрої (Mac) через застаріле серцебиття — не має стосунку до затримки Start/Stop на цьому ж пристрої. Див. `AUTO_TRACKING.md` (розділ "Важливо") — той самий застережний нюанс. |
| `autoTrackStopDelaySeconds` | 90с (default, `TrackingSettings`) | `TaskService.swift:1541` і навколо | Так само не про локальний тап — grace-період, перш ніж **цей** пристрій сам закриє свій автотрекінговий таймер після переходу в фон. |

## Діагностика — де саме дивитись у diagnostics-лозі

- `[timer] manual start tap task=X id=... at=...` / `[timer] manual start rendered task=X id=...
  latencyMs=N` — end-to-end час від тапу Start до того, як `task.isTimerRunning` реально став
  `true` в опублікованому стані. (`TaskRowView.swift`)
- `[timer] startTimer task=X id=... auto=false at=... device=...` → `startTimer optimistic apply
  done` → `startTimer committed task=...` (або `refused ... rolling back optimistic session`) —
  повний слід одного старту, включно з результатом транзакційної гонки. (`TaskService.swift`)
- `[timer] stopTimer task=X id=... reason=manual endedAt=...` — старт зупинки; `reason` відрізняє
  ручний тап від watchdog/pending-stop шляхів, описаних в `AUTO_TRACKING.md`.
- `[liveActivity] Started Live Activity for X id=... requestMs=N` — фактична вартість
  `Activity.request()` для цього конкретного старту.
- `[liveActivity] Deferring Live Activity end task=... id=...` → `Ending Live Activity task=...
  after reconciliation grace ...` або `Cancelled deferred end id=...; task is running` —
  2-секундне вікно зупинки і його результат.
- `[autoTrack] credited packet ...` / `recording usage window for X from=... to=...` одразу
  **після** `[timer] stopTimer ... reason=manual` для того самого таска — прямий доказ сценарію
  "Реактивація, механізм 2" вище: автотрекінг відкрив нове вікно вже після ручного стопу.
- **Спосіб виміряти реальну паузу Stop без здогадок:** різниця часу між `[timer] stopTimer
  task=X ... reason=manual` і буквально наступним рядком `[timer] manual start onToggleTimer
  returned task=X` для того самого `taskID` — обидва логуються в одному синхронному tap-виклику,
  тож будь-яка різниця більша за одноцифрові мс означає, що щось на цьому виклику блокує головний
  потік (до фіксу 2026-07-31 це послідовно було 1-2.2с). Якщо ця пауза колись повернеться —
  перевір `CalendarSyncManager.isEnabled` і рядок `[performance] Calendar sync completed in ...`.
  Після фіксу 2026-08-01 сам факт увімкненості вже не має означати багатосекундну паузу: важливий
  виміряний час batch-а та кількість `changed`.
- `[hang] Main thread unresponsive for X.XXs` (`HangDetector.swift`) — мав би зловити подібне
  зависання головного потоку, **але вимикається, якщо підключений дебагер**
  (`isDebuggerAttached()`), тож відсутність `[hang]`-рядків у логу, знятому під час розробки з
  Xcode, нічого не доводить.

## Файли, що стосуються ручного таймера

- `TimeGrow/Store/TaskService.swift` — `startTimer`/`stopTimer`/`toggleTrackingFromLiveActivity`,
  оптимістичні хелпери (`applyOptimisticTimerStart`, `applyOptimisticTimerStop`,
  `scheduleOptimisticSessionEnd`, `rollbackOptimisticTimerStart`), крос-пристрійна транзакція
  старту, `timerOwnerStatus`, `reconcileOrphanedManualSessions` (safety-сітка проти "вічно
  запущених" сесій).
- `TimeGrow/Store/CalendarSyncManager.swift` — не про ручний таймер напряму, але
  отримує оновлення з `sessions`'s `didSet`. З 2026-08-01 робота coalesced на 300мс,
  інкрементальна й комітиться одним EventKit batch; не повертай per-сесію `commit: true` або
  безумовний перезапис усього 30-денного кешу.
- `TimeGrow/Views/ContentView.swift` — `toggleTimer(_:)`, пряме з'єднання тапу з
  `TaskService`.
- `TimeGrow/Views/TaskRowView.swift` / `TaskTileView.swift` — рендер рядка/тайла, `isTimerRunning
  || isAutoTrackLive` як єдина умова "показувати активним", діагностика латентності тапу.
- `TimeGrow/LiveActivity/LiveActivityManager.swift` — `reconcile`, `start`,
  `scheduleEndAfterReconciliationGrace` — джерело майже всієї "видимої" затримки Dynamic Island
  щодо Start/Stop. Детально — `DYNAMIC_ISLAND.md`.
- `TimeGrow/Models/TGTask.swift` — поля `timerStartedAt`, `activeSessionID`, `timerOwner*`,
  `autoTrackStoppedAt`, `autoTrackLiveUntil`.
- `AUTO_TRACKING.md` — окремий, повністю самостійний механізм (Screen Time), який, тим не менш,
  може непрямо "реактивувати" рядок після ручного Stop — див. розділ вище.

## Відомі пастки / TODO

- **Виправлено (2026-07-31):** синхронна мутація `sessions` всередині `applyOptimisticTimerStop`
  тримала перемальовку рядка на Stop в заручниках на 1-2.2с (розділ "Виправлений баг" вище).
  Якщо після цього фіксу пауза на Stop повернеться — підозра № 1 та сама:
  `CalendarSyncManager`, якщо хтось додасть ще один синхронний виклик на шляху `sessions`'s
  `didSet`, або якщо `scheduleOptimisticSessionEnd`-деферал випадково приберуть.
- **Виправлено (2026-08-01):** `CalendarSyncManager` безумовно перезаписував увесь 30-денний кеш
  окремими `commit: true` і блокував main thread на запуску/під час snapshot. Тепер це coalesced
  incremental batch. Якщо пауза повернеться, дивись `[performance] Calendar sync...`,
  `[performance] Screen Time monitoring refresh...` і `[hang] Main thread unresponsive...`.
- **Виправлено (2026-07-31):** `stopTimer` міг слати `updateData(["endedAt": ...])` на сесію,
  чию транзакцію старту сервер ще не закомітив — запис мовчки провалювався, і сесія лишалась
  "запущеною" назавжди (розділ "Stop міг зупиняти сесію, якої ще не існувало" вище). Якщо
  подібний "вічний" запис з'явиться знову — перевір, чи `sessionCreationInFlight`/
  `pendingSessionStopActions` досі правильно резолвяться в усіх трьох гілках завершення
  транзакції старту (коміт / офлайн-фолбек / відмова). Додано safety-сітку
  `reconcileOrphanedManualSessions` (розділ вище) саме на випадок, якщо цей чи подібний шлях колись
  все ж лишить сесію без `endedAt` — вона підбирає й прибирає такі записи автоматично, без потреби
  лізти в Firestore Console вручну.
- **Відкрита прогалина, не досліджена до кінця (2026-07-31):** `[sync] tasks snapshot ...
  applied=7` у діагностиці приходив ~377 разів за годину (кожні ~5-10с), безперервно, навіть без
  жодного тапу користувача. Кожен такий знімок — повна заміна `tasks` + перемальовка всіх рядків,
  і, найімовірніше, саме він конкурує за головний потік із щойно натиснутим тапом (спостережено
  `latencyMs=2586` на старті вже ПІСЛЯ фіксів вище). Підозра — інший пристрій (в лозі одночасно
  `MacBook Air:isActive=true`) періодично пише в спільну колекцію задач; Mac-код — окремий
  репозиторій, не видно звідси. Щоб підтвердити: зняти діагностику одночасно з телефону й з Mac
  (якщо в Mac-застосунку є такий самий diagnostics-експорт) і звірити, чи цикл запису на Mac-боці
  збігається з цим ~5-10с інтервалом.
- **Відкрита прогалина (2026-07-31):** ручний `stopTimer` для сесії, що сама була ручною
  (`startedAutomatically == false`), не пише `task.autoTrackStoppedAt`. Якщо для того ж таска
  паралельно активне Screen Time-стеження, наступний поріг DeviceActivity відкриє нове
  auto-track "живе" вікно так, ніби ручного Stop не було — саме це, найімовірніше, і є
  "сам активувався за пару секунд" з боку користувача. Виправлення за аналогією з
  `stopAutoTracking(for:)`: коли ручний Stop трапляється для таска з активним автотрекінг-вибором
  (`autoTrackingStore.hasSelection(for:)`), варто так само проставляти `autoTrackStoppedAt =
  endedAt`, щоб придушити будь-яке auto-track "живе" вікно, що почалось до цього моменту — не
  тільки коли зупинена сесія сама автотрекінгова.
- **Не плутати** `interruptedMacHeartbeatGrace`/`autoTrackStopDelaySeconds` (крос-пристрійне
  відновлення завислого таймера) із затримками Start/Stop на цьому ж пристрої, описаними в цьому
  файлі — вони не мають спільного коду, тільки схожі назви.
- 2-секундний grace `scheduleEndAfterReconciliationGrace` — навмисний компроміс. Перш ніж його
  скорочувати заради "швидшого зникнення" Dynamic Island, перевір, чи не повернеться видимий
  блимок під час звичайного мерджу auto-track/push-token/timer-полів, задля якого grace і
  додавався.
