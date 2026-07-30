# Надійність і точність автотрекінгу — робоча карта для AI агента

Останнє фактичне оновлення: 2026-07-30.

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

Поточна реалізація обережна: вона радше недорахує неоднозначну пачку, ніж запише фальшивий час.
Це не остаточне рішення; перед зміною правила потрібні зібрані server-side докази.

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
`TaskTimeSession` після прийняття threshold. Але і статистика, і Dynamic Island залежать від
того, чи сам callback узагалі був доставлений і чи HTTP-запит дійшов до сервера.

## Монітор, накопичувальні кроки та rearm

`AutoTrackingStore.accumulatedThresholdEvents` і
`DeviceActivityMonitorExtension.accumulatedThresholdEvents` ставлять 15 окремих events:
`1, 2, …, 15` хвилин з одним `generation` UUID. Це зменшує дорогий `stopMonitoring` /
`startMonitoring` з разу на хвилину до разу на 15 порогів.

Після `step == 15` extension викликає `rearmMonitoring(after:)`, створює нову generation і новий
лічильник. `includesPastActivity: false` означає, що новий monitor не відновлює прогрес старого.
Тому безпричинний rearm, скидання монітора під час запуску або зміна selection можуть реально
втратити неповну хвилину. `AutoTrackingStore.adoptExistingMonitoring` існує саме щоб не робити
такого на кожному холодному запуску.

## Поточна дедуплікація і її небезпечна межа

### Як працює зараз

1. Extension тримає `autoTracking.lastQueuedThreshold.{taskID}`. Якщо наступний callback для
   тієї ж задачі прийшов менше ніж через 55 секунд, він логує
   `eventIgnored:duplicateThreshold` і не створює локальну/серверну подію.
2. При відкритті app `AutoTrackingStore.drainPendingEvents()` ще раз зливає pending events тієї
   ж задачі, які ближчі за 55 секунд.
3. `recordAutoTrackEvent` на сервері має ідемпотентний ID
   `{taskID}_{deviceID}_{occurredAtSecond}`, тому повтор того самого callback-а в ту саму секунду
   не створює новий raw event.

Це добре захищає від одного event, який iOS викликала двічі. Але правило не враховує event name.
Різні `step` однієї generation теж можуть бути відкинуті лише через близькі timestamps.

### Підтверджений приклад, 2026-07-30

Для TikTok extension отримав `step=7` о 17:03:04 (Kyiv), а потім `step=8, 9, 10, 11, 12, 13`
практично одночасно о 17:03:07. Усі швидкі кроки отримали `eventIgnored:duplicateThreshold`.
Пізніше прийшли `step=15`, rearm, а з нової generation — рівні кроки 1…5.

Це доводить пакетну доставку різних порогів. Але **не доводить**, що треба зарахувати кожен з
них як нову безперервну хвилину: кроки накопичуються протягом усього життя generation, а не лише
поточної сесії. Саме тому потрібна телеметрія до зміни алгоритму.

### Що вважати успіхом / помилкою

- Якщо той самий `monitorActivity + step` повторився — це реальний duplicate, не зараховувати.
- Якщо різні кроки прийшли пачкою, але їхній серверний trace показує новий, послідовний live
  window та немає попередніх прийнятих кроків — це кандидат на обережне додаткове зарахування.
- Якщо різні кроки приходять одразу після rearm або після довгої паузи, не можна припускати, що
  вони описують одну безперервну сесію.
- Ніколи не синтезувати «точний» початок usage тільки з номера кроку. У кращому разі можна
  додати консервативно позначений кредит; для Timeline це все одно потребує окремого продуктового
  рішення щодо його розміщення в часі.

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
6. Для розбіжності статистики порахувати distinct `thresholdAccepted` та порівняти з
   `eventIgnored:duplicateThreshold`: велика кількість різних step, що були відкинуті пачкою,
   є конкретним кандидатом на втрату часу.

## План безпечного розвитку

1. **Спершу зібрати дані.** Не міняти дедуплікацію лише за одним днем: обидва типи багів
   (справжні дублікати та реальні пакетні пороги) існують.
2. **Виділити identity події.** Майбутня дедуплікація має розрізняти щонайменше
   `taskID + monitorActivity(generation) + step`, а не тільки task + timestamp. Для цього треба
   узгоджено змінити extension, App Group pending model, `autoTrackEvents` ID і серверний endpoint.
3. **Окремо вибрати модель кредиту.** Зарахувати всі distinct steps — не те саме, що правильно
   розташувати їх у Timeline. Якщо iOS віддала пороги пізно, ми не знаємо точний розподіл usage.
4. **Порівняти з Screen Time на серії днів.** Мета — зменшити великі недорахунки без системного
   завищення в дні з помилковими callback-ами.
5. **Перевірити повторний rearm.** Будь-яка зміна не має знову перетворити monitoring на
   щохвилинний `stopMonitoring`/`startMonitoring` цикл.

## Задіяні файли

| Файл | Відповідальність |
|---|---|
| `AUTO_TRACKING.md` | Базова архітектурна карта автотрекінгу. |
| `AutoTrackingExtension/AutoTrackingExtension.swift` | Отримує DeviceActivity threshold, local pending queue, поточний 55с dedup, rearm, HTTPS POST. |
| `TimeGrow/AutoTracking/AutoTrackingStore.swift` | Selection, arm/adopt monitor, App Group drain і другий 55с dedup. |
| `TimeGrow/Store/TaskService.swift` | Server-event recovery, session merge, import server traces в export. |
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
