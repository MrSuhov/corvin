# Распознавание диалогов (роли) + словари терминов — macOS

## Context

Стенограммы встреч сейчас выходят сплошным текстом, говорящие не различаются, профессиональные
термины искажаются. Нужно:
- галочка «Распознавание диалогов» в табе Transcription → текст как сценарий, реплика каждого
  говорящего отдельным абзацем;
- у аудио два независимых результата: `name.txt` и `name_roles.txt`;
- постоянный список распознанных файлов; любой можно распознать заново; если источник изменился
  после распознавания — строка подсвечивается цветом;
- запущенное распознавание можно остановить и перезапустить с текущим положением галочки;
- несколько именованных словарей терминов, активный выбирается перед запуском.

## Принятые решения (с пользователем)

| Вопрос | Решение |
|---|---|
| Движок диаризации | **FluidAudio** (CoreML/ANE, pyannote Community-1: powerset + WeSpeaker + VBx), Apache 2.0 |
| Платформы | **только macOS** |
| Минимальная ОС | приложение остаётся **macOS 11**; диаризация доступна на **macOS 14+**, иначе галочка неактивна |
| Повторное распознавание | не перезаписывать: `name_1.txt`, `name_roles_1.txt` (как сейчас) |
| Формат `_roles.txt` | `[00:00:03] Спикер 1:` + абзац, пустая строка между репликами |
| Список файлов | постоянный (переживает перезапуск), кнопка «Распознать снова» в строке |
| Словари | несколько именованных, выбор активного в табе |
| Приватность | **всё распознавание только на Mac**. Аудио, текст и словари не покидают устройство. Сеть используется только для разовой загрузки файлов моделей, как у whisper сейчас |

## Анализ: чего не хватает в моделях

**Диаризация.** Whisper не различает говорящих. tinydiarize в whisper.cpp — только англ. `small.en`
и лишь маркер смены говорящего, без идентичности. Стерео-энергия работает только если каждый на
своём канале. Нужна отдельная модель → FluidAudio (~100 МБ моделей `pyannote_segmentation.mlmodelc` +
`wespeaker_v2.mlmodelc`, RTFx ~150× на M2, языконезависима, число спикеров авто).
Ограничения: `platforms: macOS 14 / iOS 17`; известный краш BNNS на macOS 14 (исправлен в 15);
перекрывающаяся речь приписывается одному говорящему.

**Сопутствующие пробелы в нашем стеке:**
1. Batch-путь `TranscriptionEngine.run` выбрасывает таймкоды; чанки ~25 с независимы, смещения
   чанков не хранятся → нельзя сопоставить текст со спикерами.
2. Нужны пословные таймкоды (`token_timestamps`), чтобы резать сегмент whisper, если внутри
   сменился говорящий. Streaming-путь уже умеет это (`TimedWord`, `transcribeWindow`) — переиспользовать.
3. Opus-декодер прореживает 48→16 кГц без ФНЧ (`AudioFileDecoder.downsample48kToPCM16k`) —
   алиасинг портит эмбеддинги голоса.

**Словарь.** В whisper.cpp нет hotword-boosting. Рабочий путь: `initial_prompt` +
`carry_initial_prompt = true` (промпт на каждый чанк). Лимит ~224 токена, кириллица «дорогая» →
реально ~50–100 терминов; UI показывает заполненность и предупреждает об обрезке.
Риск: на тишине модель повторяет промпт → фильтр отбрасывает сегменты, совпадающие со словарём.
`logits_filter_callback`-буст и нечёткая постзамена — не делаем (YAGNI), возможное продолжение.

## Архитектура

```
файл ─► AudioFileDecoder (16k mono) ─┬─► [roles, macOS 14+] DiarizationClient ─► corvin-diarize (процесс, FluidAudio)
                                     │                                             └─► [SpeakerSegment]
                                     └─► TranscriptionEngine.transcribe(options: prompt, wordTimestamps)
                                                                  └─► [TimedWord] с абсолютным временем
                    SpeakerTranscriptBuilder(words, speakerSegments) ─► turns ─► RolesFormatter ─► name_roles.txt
```

### 1. Helper-процесс `corvin-diarize` (изоляция FluidAudio)
Swift не импортирует модуль с min macOS 14 в таргет с min 11, SPM тоже не разрешит зависимость.
Поэтому отдельный пакет `Helpers/Diarizer/Package.swift` (`platforms: [.macOS(.v14)]`, зависимость
FluidAudio, executable `corvin-diarize`). Плюс изоляции: краш BNNS на 14 не роняет Corvin.
- Кладётся в `Corvin.app/Contents/Helpers/corvin-diarize`, подписывается в `scripts/build-dmg.sh`
  (hardened runtime, до подписи внешнего бандла); расширить проверку `@rpath`.
- Протокол: `corvin-diarize --input <raw float32 16k mono> --models <dir>`; stdout — JSON-строки
  `{"progress":n,"total":m}` … `{"segments":[{"speaker":"S1","start":1.2,"end":4.8}]}`; ошибки в stderr + exit code.
- Модели скачивает `ModelManager` приложения (как ggml-модели) в
  `~/Library/Application Support/Corvin/Models/diarization/`. Helper **не ходит в сеть**: он
  загружает модели только из этого каталога (`DiarizerModels.load(localSegmentationModel:localEmbeddingModel:)`)
  и не вызывает `prepareModels`, который умеет скачивать. Если моделей нет, helper завершается с ошибкой.
- **Обновление через манифест.** Модели объявляются в том же `models.json` (hyperstack.ru), что и
  модели whisper, в новом ключе верхнего уровня; `schemaVersion` остаётся 1 (старые клиенты
  игнорируют неизвестный ключ):
  ```json
  "diarization": [{ "id": "fluid-offline-v1", "revision": "<HF commit>", "minAppVersion": "1.5.0",
                    "helperAPI": 1, "sizeBytes": 21510001,
                    "files": [{ "path": "Segmentation.mlmodelc/weights/weight.bin",
                                "url": "https://huggingface.co/FluidInference/speaker-diarization-coreml/resolve/<commit>/…",
                                "sha256": "…", "sizeBytes": 5959360 }, …] }]
  ```
  URL закреплены на коммит, а не `main`: обновление происходит только после публикации манифеста.
  `scripts/generate-models-manifest.py` получает `--diarization-revision`: скачивает файлы ревизии,
  считает sha256 (у мелких не-LFS файлов HF не отдаёт sha256), пишет секцию; `publish-models-manifest.sh`
  валидирует её. Если в секции нет записи, приложение использует compiled-in fallback с той же структурой.
  `helperAPI` — версия формата моделей, которую понимает встроенный `corvin-diarize`, чтобы новые модели
  не попадали к старой сборке. Установка: скачивание во временный каталог → проверка sha256 → атомарная
  замена `Models/diarization/`, запись в `InstalledModelStore` (ключ = id, sha = хэш списка файлов);
  расхождение с манифестом → «Доступно обновление моделей диаризации».
- Приложение: `macOS/Services/DiarizationClient.swift` — `Process`, парсинг stdout, отмена через
  `terminate()`, всё за `if #available(macOS 14, *)`.

### 2. Движок whisper (`Shared/Core/TranscriptionEngine.swift`, должен собираться и для iOS)
- `struct TranscriptionOptions { var prompt: String?; var wordTimestamps: Bool }` — параметр
  `transcribe(audioData:options:...)` с дефолтом, текущие вызовы не меняются.
- `splitAtSilence` возвращает смещения чанков; при `wordTimestamps` включать `token_timestamps`
  и собирать `TimedWord` (как в `transcribeWindow`) со сдвигом на смещение чанка.
- `prompt` → `initial_prompt` + `carry_initial_prompt = true`; фильтр сегментов-эхо промпта.
- `TranscriptionResult` получает опциональное `words: [TimedWord]`.

### 3. Сборка сценария (`Shared/Core/Dictation/` или `macOS/Services/Roles/`)
- `SpeakerTranscriptBuilder` — чистая функция: слово → спикер по максимальному перекрытию
  (иначе ближайший сегмент); склейка подряд идущих слов одного спикера; короткие вставки < ~0.7 с
  без смены спикера не рвут абзац; спикеры нумеруются по первому появлению.
- Границы смены спикера сдвигаются к ближайшему концу предложения (`.?!…`) в окне ±1 с, иначе к
  самой длинной паузе (спайк: таймкоды токенов whisper на ±0,3–0,5 с, DTW не улучшил и требует
  выключить flash attention — не используем).
- **Перебивки.** Whisper сам ставит « - » в начале реплики при смене говорящего, а диаризация
  короткие (1–2 с) реплики сливает с соседом. Реплика дробится по таким тире (тире после конца
  предложения); части получают спикера по доле перекрытия с сегментами диаризации (≥25%), а если
  диаризация видит там одного — чередуются с предыдущим собеседником.
- `RolesFormatter` — `[HH:MM:SS] Спикер N:\n<текст>\n\n`, слово «Спикер» локализуется,
  ведущее « - » у реплики удаляется.

### 4. Реестр распознанных файлов — `macOS/Services/TranscriptRegistry.swift`
JSON `~/Library/Application Support/Corvin/transcripts.json`:
`{ sourcePath, variants: { plain?: Variant, roles?: Variant } }`,
`Variant = { outputPath, sourceSize, sourceMtime, dictionaryName?, date }`.
- «Источник изменился»: текущие size/mtime ≠ записанным → оранжевая подсветка строки + подпись.
- «Источник не найден» → серый, «Распознать снова» неактивна.
- Проверка при открытии таба и при `didBecomeActive` (не на каждый рендер).

### 5. Очередь — `macOS/Services/FileTranscriptionQueue.swift`
- `Job` получает `mode: .plain | .roles` и `dictionaryID`, фиксируемые при постановке;
  дубликат определяется парой (url, mode) — оба варианта одного файла могут стоять в очереди.
- Новый статус `.diarizing` (между `.decoding` и `.transcribing`), прогресс от helper.
- `rerun(sourcePath)` — ставит в очередь с текущими галочкой и словарём.
- `stopAndRestart(jobID)` — `cancelCurrent` только для этого job (без `stopRequested`), затем
  тот же файл снова в начало очереди с текущими настройками. Прекращает helper-процесс.
- После сохранения — запись в реестр. Список в UI = реестр ∪ активные jobs.

### 6. Запись файлов — `macOS/Services/TranscriptSaver.swift`
`write(text:audioName:suffix:into:)`: base = `stem + suffix` (`""` или `"_roles"`), коллизии
`_1`, `_2` как сейчас → `name_roles.txt`, `name_roles_1.txt`. `safeBaseName` учитывает суффикс.

### 7. Словари — `macOS/Services/VocabularyStore.swift`
JSON `~/Library/Application Support/Corvin/vocabularies.json`: `[{id, name, terms: [String]}]`,
активный id в UserDefaults. Сборка промпта: термины через запятую, обрезка по токенам
(`whisper_tokenize`) до ~200, счётчик «N из M терминов поместилось».

### 8. UI — `macOS/UI/Settings/TestTranscriptionView.swift`
- В `fileSection`: галочка «Распознавание диалогов» (неактивна < macOS 14 с подписью
  «Требуется macOS 14»; если моделей нет — «Скачать модели (~22 МБ)» с прогрессом);
  Picker «Словарь: Нет / …» + «Изменить…» (sheet: список словарей, имя, многострочное поле терминов).
- `JobRow` → строка файла: имя; бейджи `TXT` / `ROLES` (открыть в Finder); меню «Распознать снова»;
  во время работы — «Остановить и перезапустить»; фон оранжевый при изменённом источнике.
- Все строки — ключи `.localized` в en/ru/es; `make lint-l10n`.

## Этапы работ

0. **Дизайн-док + спайк (go/no-go).** Записать дизайн в
   `docs/plans/2026-09-15-dialog-transcription-design.md` и закоммитить. Собрать `corvin-diarize`,
   прогнать на 2–3 реальных русскоязычных встречах: качество разбиения, скорость, работа на x86_64,
   управление каталогом моделей, поведение на macOS 14.
1. **Таймкоды и опции движка** (п.2) + ФНЧ в Opus-декодере.
2. **Сборка сценария** (п.3) на фиксированных данных (слова + сегменты) → ожидаемый текст.
3. **Helper + DiarizationClient + build-dmg** (п.1), загрузка моделей.
4. **Суффикс `_roles`, реестр, режим job, `.diarizing`** (п.4–6).
5. **Stop-and-restart, «Распознать снова», подсветка изменённых** (п.5, UI).
6. **Словари** (п.7, UI).
7. **Локализация, README/CLAUDE.md** (раздел про pipeline файлов), релиз.

## Критичные файлы
- `Shared/Core/TranscriptionEngine.swift` — опции, таймкоды, промпт
- `Shared/Core/AudioFileDecoder.swift` — ресемплинг Opus
- `macOS/Services/FileTranscriptionQueue.swift` — режим, статусы, перезапуск
- `macOS/Services/TranscriptSaver.swift` — суффикс
- `macOS/UI/Settings/TestTranscriptionView.swift` — галочка, словари, строки списка
- `scripts/build-dmg.sh`, новый `Helpers/Diarizer/` — сборка/подпись helper
- новые: `DiarizationClient`, `SpeakerTranscriptBuilder`, `RolesFormatter`, `TranscriptRegistry`, `VocabularyStore`
- `Shared/Resources/{en,ru,es}.lproj/Localizable.strings`

## Verification
- `swift build -c release --arch arm64 --arch x86_64`; iOS-таргет компилируется (`make project`, сборка CorviniOS) — движок общий.
- `make lint-l10n`.
- Проверка локальности: при распознавании файла с галочкой и словарём (модели уже скачаны)
  `nettop -p <pid Corvin и corvin-diarize>` не показывает сетевых соединений; то же с выключенным Wi-Fi.
- `scripts/build-dmg.sh` → `codesign --verify --deep --strict`, helper внутри бандла подписан.
- Ручные сценарии на macOS 15 (и проверка неактивной галочки на macOS 11–13, если есть машина/VM):
  1. Встреча 2–4 человека, галочка вкл → `name_roles.txt` с абзацами и таймкодами; без галочки → `name.txt`.
  2. Повторно тот же файл → `name_roles_1.txt`; оба варианта видны в строке после перезапуска приложения.
  3. `touch`/перезапись исходника → строка оранжевая; удаление → серая.
  4. Во время распознавания переключить галочку → «Остановить и перезапустить» → helper завершён, новый результат в нужном режиме.
  5. Словарь с 10 терминами (имена, аббревиатуры) → термины в тексте написаны корректно; тишина не даёт эха словаря.
  6. Параллельно fn-диктовка — очередь уступает движок, как сейчас.
