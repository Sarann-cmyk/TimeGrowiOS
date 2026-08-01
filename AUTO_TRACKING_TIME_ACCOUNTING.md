# Рахування часу в auto-track (iPhone) — арифметика, пауза, відновлення, статистика

Останнє фактичне оновлення: 2026-08-01.

Цей файл — вузькоспеціалізована карта для ОДНОГО питання: **скільки секунд рахується, коли,
куди записується і чому саме стільки**, коли час задачі рахується автоматично через Screen Time
на iPhone. Він не дублює `AUTO_TRACKING.md` (загальна архітектура: extension → Firestore →
Cloud Function → UI) чи `AUTO_TRACKING_RELIABILITY.md` (чому доставка порогів ненадійна і як з
цим боротись) — читай ці два файли для контексту. Тут — лише арифметика: формули, звідки береться
кожна секунда в `TaskTimeSession.duration`, що саме означає "пауза" й "відновлення" з точки зору
підрахунку, і де в коді (файл + рядок) кожне правило прописано.

## Перше, що треба зрозуміти: чотири незалежні "часові" поняття над тими самими подіями

Одні й ті самі порогові callback'и (`eventDidReachThreshold`) одночасно рухають ЧОТИРИ окремі
речі. Плутанина між ними — джерело майже всіх помилкових звітів про "неправильний підрахунок":

| # | Що це | Поле(-я) | Що визначає | Пишеться в статистику? |
|---|---|---|---|---|
| 1 | **Факт у базі** — сам блок часу | `TaskTimeSession.startedAt`/`endedAt` | Що реально зарахується в Reports/Timeline | **Так — це і є статистика** |
| 2 | **5-хвилинне вікно склеювання** | `autoTrackLiveUntil`, `autoTrackSessionStartedAt` | Чи наступний threshold продовжить (1), чи почне нову сесію | Ні, лише керує (1) |
| 3 | **90-секундна Dynamic Island lease** | `autoTrackLiveActivityUntil`, `autoTrackLiveActivityCycleID` | Чи видно Live Activity на iPhone/на Маку (див. `DYNAMIC_ISLAND.md`) | Ні, чисто UI/ActivityKit |
| 4 | **"Жива" секундна екстраполяція в списку задач** | `AutoTrackPresentationState.displayDate` | Що показує elapsed-лічильник між двома реальними записами (1) | Ні, ефемерне, нікуди не пишеться |

(2) і (3) — окремі дедлайни з різним строком (300с і 90с відповідно), обидва рахуються від
`occurredAt` (момент реального DeviceActivity callback, не момент, коли сервер/клієнт його
обробили). (1) — єдине, що формує підсумок у Reports; решта — тільки про те, коли (1)
продовжується, а не про те, скільки в ньому секунд.

## Одиниця кредиту: один threshold = 60 секунд, але "де саме" ці 60 секунд — не завжди тривіально

DeviceActivity не каже "користувач почав/закінчив користуватись". Вона каже лише "з моменту
старту монітора накопичилось ще на 60 секунд більше use time" (`autoTrackingThresholdSeconds`,
`AutoTrackingStore.swift:15`). Кожен ПРИЙНЯТИЙ (не дубльований) threshold — це рівно один
підтверджений 60-секундний кредит. Є два випадки розміщення цього кредиту в `TaskTimeSession`:

### Випадок A — звичайний, ізольований крок

`occurredAt` нового кроку записується як новий `endedAt` сесії; `startedAt` не рухається.

- Сервер: `functions/src/index.ts:343` (`mergedEndedAt = previousEndedAt && previousEndedAt >
  occurredAt ? previousEndedAt : occurredAt`), застосовується в `transaction.update(taskRef,
  {...})` на `functions/src/index.ts:372-386`.
- Клієнт (офлайн-запасний шлях): `TaskService.recordAutoTrackedSession`
  (`TaskService.swift:1160-1218`) робить те саме через `latestMergeableAutoTrackedSession`
  (`TaskService.swift:1414-1447`): `mergedEnd = max(existingSession.endedAt, endedAt)`.

**Наслідок, який часто дивує:** тривалість сесії = `endedAt - startedAt`, а НЕ "кількість
прийнятих кроків × 60с". Якщо кроки приходять рівно раз на ~60 реальних секунд (нормальне
безперервне використання), це збігається. Але якщо між двома кроками був 4-хвилинний розрив
(мовчання, а не дублікат), `endedAt` просто підстрибує на нове `occurredAt` — і весь 4-хвилинний
проміжок автоматично потрапляє у зараховану тривалість сесії, хоча підтверджено було лише 60
секунд use time. Це свідомий компроміс (див. "Пауза й відновлення" нижче), не баг.

### Випадок B — пакетний крок (кілька distinct steps прийшли практично одночасно)

Коли iOS доставляє кілька РІЗНИХ порогів (наприклад step 8, 9, 10, 11) в одному короткому
пакеті (delivery timestamps ближче, ніж `autoTrackingBatchedThresholdWindowSeconds` = 10с,
`AutoTrackingStore.swift:44`), розміщення `endedAt = occurredAt` для кожного з них дало б лише
кілька РЕАЛЬНИХ секунд сесії за 4 підтверджені хвилини use time — недооблік. Замість цього:

- Сервер: `packedDistinctStep` (`functions/src/index.ts:315-325`) — правда, коли: та сама
  сесія продовжується, є `monitorActivity`/`thresholdStep`/`usageDay`, номер кроку ЗМІНИВСЯ
  відносно останнього збереженого (`autoTrackLastThresholdStep`), і `occurredAt` нового кроку
  в межах 10с від попереднього підтвердженого `autoTrackLastUsageAt`. Якщо так —
  `creditedSessionStartedAt = previousStartedAt - 60_000мс` (`functions/src/index.ts:347-349`):
  сесія отримує +60с, зсуваючи `startedAt` НАЗАД, а не рухаючи `endedAt` вперед.
- Клієнт (офлайн-запасний шлях): `processQueuedAutoTrackEvents`
  (`TaskService.swift:1070-1158`) робить те саме одним проходом на весь пакет: групує distinct
  steps, чиї `occurredAt` в межах 10с одне від одного (`TaskService.swift:1111-1124`), і
  ставить `startedAt = endedAt - (60с × кількість кроків у пакеті)`
  (`TaskService.swift:1126-1127`). Позначає вікно `hasEstimatedTiming = true`.

**Важливо:** `hasEstimatedTiming` — це лише діагностичний прапор ("розміщення реконструйоване,
не точна історична секунда"). З 2026-07-31 він НЕ ховає й не позначає сесію інакше в
Timeline/Reports — така сесія малюється як звичайний блок (рішення користувача, деталі в
`AUTO_TRACKING.md`).

## Пауза: що саме НЕ рахується і НЕ віднімається

"Пауза" в цьому застосунку — виключно UI-поняття (`AutoTrackPresentationState`,
`TimeGrow/Helpers/AutoTrackPresentationState.swift`), яке настає, коли 90-секундна lease (3) уже
вийшла, а 5-хвилинне вікно (2) — ще ні:

```swift
// AutoTrackPresentationState.swift:45-52
if let activityUntil, activityUntil > date, !wasExplicitlyStopped {
    return Self(session: session, phase: .active, displayDate: date)
}
let frozenAt = max(confirmedUsageAt, min(activityUntil ?? confirmedUsageAt, date))
return Self(session: session, phase: .paused, displayDate: frozenAt)
```

Під час паузи:

- **База даних (`TaskTimeSession.endedAt`) не змінюється.** Останній записаний `endedAt`
  залишається таким, яким був на момент останнього прийнятого threshold. Нічого не віднімається
  від уже зарахованого часу — призупинення НІКОЛИ не є ретроактивним "відкатом" статистики.
  Нічого й не додається — секундомір у списку задач (4) заморожується рівно на
  `displayDate` (= момент останнього підтвердженого `occurredAt`, чи трохи пізніше, якщо
  90-секундна lease встигла спливти першою) і перестає рости, поки не прийде новий threshold.
- Кільце/аватарка блимає (`TaskAvatarCircle(isPaused: true)` на iOS,
  `ActiveTaskTimerAvatar(frozenAt:)` на Mac) — це чисто анімація прозорості, не має жодного
  стосунку до записаного часу.
- Dynamic Island зникає (`DYNAMIC_ISLAND.md`) — так само, лише презентаційний ефект.

Тобто "пауза" сама по собі — це нуль операцій над статистикою. Вона лише сигналізує
користувачу "чекаємо на наступне підтвердження use time, поки ще не втратили сесію".

## Відновлення (новий threshold до спливання 5-хвилинного вікна)

Якщо новий threshold приходить, поки `autoTrackLiveUntil` (5-хв вікно) ще не минуло —
`canContinuePreviousSession` на сервері (`functions/src/index.ts:297-300`) або
`latestMergeableAutoTrackedSession` на клієнті (`TaskService.swift:1439-1442`, умова
`forwardGap >= 0 && forwardGap <= autoTrackingInactivityGraceSeconds`) кажуть "так, це та сама
сесія" — і застосовується Випадок A або B вище: `endedAt` просто зсувається до нового
`occurredAt` (`mergedEnd = max(existing.endedAt, endedAt)`).

**Ключовий, часто неочікуваний наслідок:** увесь проміжок тиші всередині 5-хвилинного вікна
(наприклад 3 хвилини, коли threshold не приходив, бо реального use time не назбиралось, або
доставку затримав iOS) **автоматично зараховується як частина тривалості сесії** — не тому, що
ми знаємо, що там реально відбувалось, а тому, що API фізично не дає точнішої інформації, і
консервативний вибір — довіряти, що коротка (≤5хв) перерва в доставці не означає, що людина
поклала телефон. Це задокументований компроміс, не помилка підрахунку — деталі й альтернативи
розібрані в `AUTO_TRACKING_RELIABILITY.md` ("Контракт даних: чого ми знаємо, а чого ні").

## Розрив довший за 5 хвилин: нова сесія, час між ними не рахується НІКУДИ

Якщо `forwardGap > autoTrackingInactivityGraceSeconds` (300с) — стара сесія залишається
незмінною (її `endedAt` не рухається далі), і для нового threshold стартує НОВИЙ документ
`TaskTimeSession` (`TaskService.swift:1242-1259`, сервер — гілка `else` без
`previousSessionSnapshot` в `functions/src/index.ts:356-370`). Діагностика причини розриву
логується явно:

```
[autoTrack] starting new session for X instead of extending previous (ended ...):
forward gap=Ns exceeds merge window=300s
```
(`TaskService.swift:1234`, `AUTO_TRACKING.md` розділ "Діагностика" описує цей рядок).

Сам розрив (наприклад 40 хвилин між кінцем старої сесії і початком нової) **не з'являється ні в
якій сесії** — ні як "втрачений" час старої, ні як "додатковий" час нової. Він просто ніде не
існує в даних; на Timeline це видно як проміжок між двома окремими блоками.

## Явна зупинка і надто короткі сесії

- **Явна зупинка** (`TaskService.stopAutoTracking`, `TaskService.swift:1486-1505`, або кнопка
  Stop на Live Activity через `toggleTrackingFromLiveActivity`) ставить `autoTrackStoppedAt =
  Date()` і одразу зменшує `autoTrackLiveUntil`/`autoTrackLiveActivityUntil` до цього ж моменту.
  Це hard cutoff: подальші threshold-и з тим самим `autoTrackSessionStartedAt` вже не зможуть
  продовжити стару сесію — сервер перевіряє `stoppedAt >= sessionStartedAt`
  (`wasStoppedAfterStart`, `functions/src/index.ts:115-116`), клієнт перевіряє
  `stoppedAt >= session.endedAt` (`latestMergeableAutoTrackedSession`, `TaskService.swift:1429`);
  різні поля порівняння, той самий результат — наступне використання створює нову сесію з нуля, навіть якщо
  формально ще в межах 5-хвилинного вікна.
- **Сесії коротші за `minimumTrackedSessionDuration` (3с, `AutoTrackingStore.swift:36`)**
  видаляються повністю при явній зупинці ручного/пов'язаного таймера
  (`TaskService.swift:1537`, `1599`, `2133`) — трактуються як випадковий дотик, не реальний
  трекінг. Авто-трекінг з Screen Time сам по собі не може створити настільки коротку сесію
  (мінімальний крок — 60с), це стосується головно ручних стартів/зупинок.

## Як це потрапляє у статистику (Reports/Timeline)

`TaskTimeSession.duration(at:)` (`TimeGrow/Models/TaskTimeSession.swift:32-34`):

```swift
func duration(at date: Date = Date()) -> TimeInterval {
    max(0, (endedAt ?? date).timeIntervalSince(startedAt))
}
```

`ReportsView`/`TaskReportDetailView` підсумовують саме це, напряму на масиві `sessions`
(`ReportsView.swift:683,848,929`, `TaskReportDetailView.swift:514,695`) — без жодної спеціальної
обробки auto-track vs ручних сесій. Оскільки `endedAt` для auto-track сесії завжди виставлений
(навіть поки вона "жива" — сервер/клієнт постійно його підсовують вперед при кожному threshold),
`duration(at:)` для неї повертає останнє ЗАПИСАНЕ значення, не живий wall-clock.

Живе, посекундне зростання лічильника, яке бачить користувач у списку задач/тайлах
(`TaskRowView.TaskDurationLabel`, `TaskTileView`, і дзеркально на Mac
`TrackingView.TaskDurationLabel`/`StatusBarController`) — це ОКРЕМА, суто презентаційна
екстраполяція понад останній записаний `endedAt`, через `AutoTrackPresentationState.displayDate`
(iOS) / `TGTask.autoTrackDisplayDate(at:)` (Mac, `TimeGrowMac/Task/TGTask.swift`). Вона ніколи не
пишеться в Firestore і зникає/вирівнюється сама, щойно приходить наступний реальний threshold
(тоді `endedAt` наздоганяє те, що UI вже показував). Тому короткочасна розбіжність "на екрані
секунд на 10-15 більше, ніж буде видно в Reports одразу після" — очікувана, не баг.

## Наскрізний приклад

Користувач відкриває TikTok о 12:00:00.

1. `t=60s` (12:01:00) — threshold step=1. Нова сесія: `startedAt=12:00:00, endedAt=12:01:00`
   (Випадок A, `endedAt = occurredAt`). Кредит: 60с.
2. `t=120s` (12:02:00) — step=2, звичайний. `endedAt=12:02:00`. Кредит: +60с. Разом: 120с.
3. Користувач кладе телефон о 12:02:05. Тиша.
4. `t=90с після 12:02:00` (12:03:30) — 90-секундна lease (3) вийшла: Dynamic Island гасне,
   `AutoTrackPresentationState` переходить у `.paused`, елапсед у списку задач заморожується на
   `12:02:00` (останній підтверджений `occurredAt`) і починає блимати. **Статистика не
   змінюється** — все ще 120с.
5. Користувач повертається о 12:05:30 (розрив = 3хв30с від `endedAt=12:02:00`, тобто в межах
   300с). Нове використання накопичує ще одну хвилину; step=3 приходить, скажімо, о 12:06:20.
   Це звичайний (не пакетний) крок → `endedAt = 12:06:20` (Випадок A). Нова тривалість сесії:
   `12:06:20 - 12:00:00 = 380с`. **Зверніть увагу:** реально підтверджено лише 3 хвилини use
   time (кроки 1,2,3 = 180с), але сесія показує 380с — 200-секундна пауза всередині 5-хвилинного
   вікна автоматично увійшла до тривалості. Це навмисний компроміс, описаний вище.
6. Якби замість повернення о 12:05:30 користувач повернувся лише о 12:10:00 (розрив від
   `endedAt=12:02:00` = 8 хвилин > 300с) — сесія №1 залишилась би зафіксованою на 120с назавжди,
   а нове використання створило б сесію №2 з власним `startedAt`. 8-хвилинний розрив між ними
   не потрапив би в жодну статистику.

## Файли, що безпосередньо рахують час (короткий покажчик; повний список ролей — `AUTO_TRACKING.md`)

| Файл | Що саме тут рахується |
|---|---|
| `AutoTrackingStore.swift:14-44` | Всі константи-множники: 60с/крок, 300с merge, 90с lease, 10с пакетне вікно, 3с мінімальна сесія. |
| `AutoTrackingExtension/AutoTrackingExtension.swift:140-` (`recordThresholdAccounting`) | Локальний diagnostic-облік credited/unaccounted секунд на пристрої (не сама база сесій). |
| `functions/src/index.ts:227-` (`recordAutoTrackEvent`) | Серверна, авторитетна арифметика: Випадок A/B, `canContinuePreviousSession`, запис `TaskTimeSession`. |
| `TimeGrow/Store/TaskService.swift:1070-1259` | Клієнтське, офлайн-запасне дзеркало тієї самої арифметики (пакетування, merge, нова сесія). |
| `TimeGrow/Store/TaskService.swift:1414-1447` (`latestMergeableAutoTrackedSession`) | Клієнтське рішення "продовжити чи розірвати" — умова gap ≤ 300с. |
| `TimeGrow/Store/TaskService.swift:1486-1540` | Явна зупинка й короткі сесії. |
| `TimeGrow/Models/TaskTimeSession.swift:32-34` | Формула `duration(at:)`, яку читає вся статистика. |
| `TimeGrow/Helpers/AutoTrackPresentationState.swift` | UI-заморозка/розморозка (пауза), не чіпає базу. |
| `TimeGrow/Views/ReportsView.swift`, `TaskReportDetailView.swift` | Підсумовування `duration(at:)` у звіти — без спецобробки auto-track. |
| `TimeGrowMac/Task/TGTask.swift` (`autoTrackDisplayDate(at:)`) | Mac-дзеркало UI-заморозки для менюбар-таймера й тайлів (доданo 2026-08-01). |

## Не документується повторно тут (дивись відповідний файл)

- Чому доставка threshold ненадійна, пакетна дедуплікація, server-side traces —
  `AUTO_TRACKING_RELIABILITY.md`.
- Ланцюжок extension → Firestore → Cloud Function → Live Activity, adopt/rearm монітора —
  `AUTO_TRACKING.md`.
- Все про Dynamic Island (90-секундна lease як UI, push-to-start, чому вона гасне і як
  з'являється знову) — `DYNAMIC_ISLAND.md`.
