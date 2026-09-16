# Запись звонков (любое приложение) — macOS

## Context

Corvin умеет диктовку с микрофона (удержание fn) и распознавание файлов. Записать звонок в Telegram
или любом другом приложении нельзя: звук собеседника не захватывается, режима длинной записи нет,
роли в тексте не различаются.

Цель — пункт меню «Записать звонок ▸ <приложение>». Микрофон («Я») и звук выбранного приложения
(«Собеседник») пишутся в стерео-файл; после «Стоп» файл сам распознаётся в сценарий `…_roles.txt`.
Опирается на [распознавание диалогов](2026-09-15-dialog-transcription-design.md).

## Принятые решения (с пользователем)

| Вопрос | Решение |
|---|---|
| Захват звука приложения | **Core Audio process tap** (macOS 14.2+); запасной путь — **ScreenCaptureKit audio** (13–14.1); на 11–12 пункт неактивен |
| Источник | **одно приложение** из списка запущенных, не привязываемся к Telegram; звучащие сейчас — сверху; последний выбор запоминается по bundle ID; helper-процессы приложения входят автоматически |
| Когда текст | **после остановки**: файл → очередь распознавания, роли «Я / Собеседник» |
| Управление | **меню в менюбаре + плавающий индикатор** (таймер ч:мм:сс, кнопка Стоп) |
| Эхо без наушников | **voice processing на микрофоне + фильтр дублей** в тексте |
| Аудиофайл | **сохраняется рядом с текстом**: m4a, стерео, L = Я, R = Собеседник |
| Длина части записи | настройка «Писать частями по, мин» (по умолчанию 5, диапазон 1–30); части сливаются в один файл после звонка |
| Порядок | сначала общий фундамент из распознавания диалогов, потом звонки |
| Папка | `outputDirectory` очереди, если задана, иначе `~/Documents/Corvin/Calls/`; при отказе TCC — `TranscriptSaver.fallbackDirectory` |
| Приватность | всё на Mac; сеть не используется |

## Архитектура

```
MicSource (AVAudioEngine, voice processing) ─┐ 16k mono Float + hostTime
                                             ├─► TimelineWriter ─► part1.caf, part2.caf… (PCM, 2ch, 16k) ─Стоп─► merge ─► .m4a
RemoteSource ────────────────────────────────┘                                                  │
  ├─ ProcessTapSource    (14.2+: CATapDescription → aggregate device → IOProc)                  ▼
  └─ ScreenCaptureSource (13+: SCStream capturesAudio, фильтр по приложению)        FileTranscriptionQueue (.call)
                                                                                                │
 decodeChannels → transcribeTimed(L), transcribeTimed(R) → [диаризация R] → EchoFilter → CallTranscriptBuilder → RolesFormatter
```

**Почему два независимых потока, а не один aggregate device с микрофоном.** Voice processing
(AUVoiceIO) работает только на своём устройстве и не встраивается в aggregate. ScreenCaptureKit тоже
даёт два потока. Одна схема сведения по host-времени обслуживает оба пути.

### 1. Захват — `macOS/Services/CallRecording/`

- **`AudioAppCatalog`** — список приложений.
  - 14.2+: `kAudioHardwarePropertyProcessObjectList`; у процесса `PID`, `BundleID`, `IsRunningOutput`.
    Группировка в приложение по префиксу bundle ID (`com.google.Chrome.helper` → Chrome), иконка из
    `NSRunningApplication`.
  - 13–14.1: `SCShareableContent.current.applications`, без пометки «звучит».
  - Corvin исключён. Последний выбор — `UserDefaults` `callRecording.lastBundleID`.
- **`RemoteSource`** — протокол: `start(app:onBuffer:)` (16k mono Float + hostTime), `stop()`, `onEnded`.
  - **`ProcessTapSource`**: `CATapDescription(stereoMixdownOfProcesses:)`,
    `AudioHardwareCreateProcessTap`, private aggregate device с `kAudioAggregateDeviceTapListKey`,
    `AudioDeviceCreateIOProcIDWithBlock`. Формат из `kAudioTapPropertyFormat` → downmix →
    `AVAudioConverter` в 16k. Появились новые процессы приложения — обновить
    `kAudioTapPropertyDescription`. Все процессы завершились — `onEnded`: запись останавливается и
    сохраняется.
  - **`ScreenCaptureSource`**: `capturesAudio = true`, `excludesCurrentProcessAudio = true`,
    минимальное видео (2×2, большой `minimumFrameInterval`), PTS → hostTime.
- **`MicSource`** — свой `AVAudioEngine`, `AudioCaptureService` диктовки не трогаем.
  `inputNode.setVoiceProcessingEnabled(true)`; на 14+ приглушение других приложений отключается
  (`voiceProcessingOtherAudioDuckingConfiguration`). Не удалось включить → сырой микрофон и запись в лог.
  Downmix и конвертация — общие с `AudioCaptureService`.
- **`TimelineWriter`** — позиция сэмпла `(hostTime − t0) × 16000`.
  - Разрыв заполняется тишиной; расхождение больше 20 мс — переякорение.
  - Канал без буферов дольше 0,5 с при живом втором — дописываются нули (SCK молчит на тишине).
  - **Запись частями.** Файл `<база>.partN.caf`: CAF, 16-bit PCM, 2 канала, 16 кГц, в
    `Application Support/Corvin/Recordings`. Длина части — из настройки (по умолчанию 5 мин).
    Каждая завершённая часть закрыта на диске, поэтому сбой стоит не больше одной части; PCM, а не
    AAC, потому что у AAC таблица пакетов пишется при закрытии и файл после падения не читается.
    Таймлайн (`TimelineCursor`) непрерывен через границы частей.
  - «Стоп» → `CallRecorder.merge` склеивает части в один AAC `.m4a` (48 кбит/с, ~21 МБ/час) в папку
    звонков, части удаляются. Не вышло — части переносятся в `Application Support/Corvin/Calls` и
    распознаются по отдельности. Оставшиеся при запуске части группируются по имени, склеиваются и
    распознаются как обычный звонок.
- **`CallRecorder`** — `@MainActor ObservableObject`, владеет `AppDelegate`.
  `state: idle | starting | recording(app, startedAt) | finishing | failed(LocalizedMessage)`.
  `SessionState` **не расширяется**: любое не-idle состояние останавливает очередь файлов
  (`FileTranscriptionQueue.micBusy`) и мешает fn-диктовке во время звонка.
  «Стоп» → финализация → `fileQueue.enqueue(url, mode: .call)`.

### 2. Разрешения и сборка

- `NSAudioCaptureUsageDescription` в `macOS/Resources/Info.plist` и `InfoPlist.strings` (en/ru/es).
- У тапа нет preflight. Если через 3 с правый канал нулевой, а процесс `IsRunningOutput`, —
  баннер «Разрешите запись системного звука» со ссылкой
  `x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture`.
- ScreenCaptureKit: `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`.
- Строки обоих разрешений в табе Permissions — по образцу микрофона.
- `Package.swift`: `-Xlinker -weak_framework -Xlinker ScreenCaptureKit`; то же в `project.yml`.
  API тапа — за `@available(macOS 14.2, *)`, нужен SDK 14.2+. Entitlements не меняются.

### 3. Распознавание — `macOS/Services/Roles/`

- **`AudioFileDecoder.decodeChannels(url:) -> (left: Data, right: Data)`** — чтение блоками, 16k Int16
  на канал. Сейчас все пути декодера смешивают стерео в моно и читают файл одним буфером.
- **Очередь, `Job.mode == .call`:** decode → `transcribeTimed(L)` → `transcribeTimed(R)` по очереди
  (контекст whisper один) → если macOS 14 и модели есть — `DiarizationClient.diarize(pcm: R)`,
  статус `.diarizing`.
- **`EchoFilter.filter(me:other:)`** — чистая функция. Фраза «Я» (слова между паузами > 0,6 с), у
  которой ≥60% нормализованных слов есть у собеседника в окне ±1,5 с, отбрасывается.
- **`CallTranscriptBuilder.build(me:other:otherSegments:)`** — чистая функция. Правый канал →
  `SpeakerTranscriptBuilder.build`; реплики «Я» режутся паузой > 1,5 с и началом реплики собеседника;
  слияние по времени начала.
- **`RolesFormatter`** получает функцию меток: «Я», «Собеседник», «Собеседник 2»; для файлов — как
  раньше «Спикер N».
- Сохранение: `TranscriptSaver.write(…suffix: "_roles"…)` рядом с `.m4a`.

### 4. UI

- **Меню** (`StatusBarController.buildMenu`), рядом с «Распознать файл»: подменю «Записать звонок ▸» —
  последнее приложение, затем звучащие, затем остальные. Во время записи — «Остановить запись
  (<App>, 12:34)». Иконка красная, пока идёт запись и диктовка не активна.
- **Индикатор** — отдельная плашка звонка, когда `SessionState == .idle`: точка, имя приложения,
  таймер `h:mm:ss`, уровни двух каналов, кнопка Стоп.
- Все строки — ключи `.localized` в en/ru/es.

## Этапы

0. **Дизайн-док + спайк (go/no-go).** Спайк-CLI вне продукта: тап на Telegram
   (`ru.keepcoder.Telegram`, `org.telegram.desktop`) во время реального звонка; наш voice processing
   одновременно с voice processing Telegram; дрейф каналов за 30 мин; путь ScreenCaptureKit.
1. **Фундамент из распознавания диалогов:** `Job.mode` (`.plain | .roles | .call`), статус
   `.diarizing`, суффикс в `TranscriptSaver`, метки в `RolesFormatter`.
2. **Чистая логика + тесты:** `EchoFilter`, `CallTranscriptBuilder`, расчёт позиций `TimelineWriter`.
   Тест-таргет `CorvinTests`.
3. **Захват:** `MicSource`, `ProcessTapSource`, `TimelineWriter`, `CallRecorder`, m4a,
   `AudioAppCatalog`, weak-link, Info.plist.
4. **`ScreenCaptureSource`** за тем же протоколом.
5. **Распознавание звонка:** `decodeChannels`, режим `.call`, диаризация правого канала.
6. **UI:** меню, индикатор, разрешения, баннер; локализация.
7. **Сборка и документация:** проверка подписи в `build-dmg.sh`, README/CLAUDE.md.

## Verification

- `swift build -c release --arch arm64 --arch x86_64`; iOS-таргет собирается.
- `swift test` (`CorvinTests`, без whisper); `make lint-l10n`.
- Во время записи и распознавания `nettop -p <pid Corvin>` не показывает соединений.
- `scripts/build-dmg.sh` → `codesign --verify --deep --strict`; первый старт тапа показывает системный запрос.
- Ручные сценарии (записи 1–2 мин):
  1. Звонок в Telegram в наушниках → m4a с L/R, `_roles.txt` с «Я»/«Собеседник» в правильном порядке.
  2. То же через динамики → нет дублей реплик собеседника у «Я».
  3. Звонок в браузере — helper-процессы попадают в запись.
  4. Закрыть приложение-источник во время записи → запись сохранена и распознана.
  5. fn-диктовка во время записи работает; очередь файлов не стоит.
  6. Отказ в разрешении → баннер; macOS 13 — путь ScreenCaptureKit; macOS 12 — пункт неактивен.
  7. Убить Corvin во время записи → `.caf` распознаётся через «Распознать файл».
