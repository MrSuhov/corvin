# Словарь диктовки (macOS fn + iOS-клавиатура) — дизайн

## Context

Словари уже есть, но только для файлов:
- `VocabularyStore` и `VocabularyEditorView` живут только в macOS;
- выбранный список терминов идёт в whisper как `initial_prompt` через `TranscriptionEngine.fitPrompt` (до 200 токенов).

Повседневная диктовка подсказок не получает:
- fn на macOS (`WhisperBatchRecognizer` / `WhisperStreamingRecognizer`);
- клавиатура iOS (`TranscriptionService.transcribe(audioData:)`).

Поэтому имена, жаргон и редкие слова в ней распознаются плохо.

Цель — **один** словарь диктовки на устройстве:
- небольшой текстовый редактор, импорт из .txt и экспорт;
- по умолчанию в нём пример: инструкция в строках `#` и три слова.

Решения, принятые в brainstorm:
- **Охват:** macOS fn и iOS-клавиатура. Каждое устройство хранит свой словарь, синхронизации нет, всё локально.
- **Механизм:** только подсказка whisper (`initial_prompt`), без замен. GigaAM подсказку не принимает, для него показываем пометку «модель не использует словарь».
- **Хранение:** один отдельный текст. Файловые словари (`vocabularies.json`) не трогаем.
- **Пример по умолчанию:** «Корвин» (имя), «деплой» (жаргон), «вайбкодинг» (неочевидное написание).

## Дизайн

### 1. Данные — `Shared/Core/DictationDictionary.swift` (новый)
- Сырой текст хранится целиком, вместе с комментариями: что пользователь написал, то он и видит.
  - macOS: `UserDefaults.standard`.
  - iOS: suite App Group, как остальные настройки. Читает его host app, который и транскрибирует.
- Ключи:
  - `dictationDictionary.text`. Нет ключа — используется пример `"dictation.dictionary.example".localized`.
  - `dictationDictionary.enabled`, **по умолчанию false**. Русская подсказка в каждой диктовке сдвигает whisper к русскому, а это ломает англо- и испаноязычную диктовку при автоопределении языка. Пример виден сразу, а включает словарь пользователь.
- `static func terms(from text:) -> [String]`:
  - строки, начинающиеся с `#`, отбрасываются;
  - остальное разбирается правилами `VocabularyStore.parseTerms`: строка, `,` или `;` как разделитель, без пустых и повторов.

  Сам `parseTerms` переносится в Shared как `TermList.parse`, и `VocabularyStore` вызывает его оттуда.
- `var activeTerms: [String]?` возвращает nil, если словарь выключен или пуст. Остальной код только это и читает.
- Пример: строка в en/ru/es, комментарии на языке интерфейса, сами три слова русские во всех трёх языках.
  ```
  # Словарь диктовки — слова, которые распознаватель должен ожидать.
  # Одно слово или фраза на строку, ровно в том написании, как нужно.
  # Важное — выше: длинный список обрезается с конца.
  # Строки с # не учитываются. Работает с моделями Whisper.

  Корвин
  деплой
  вайбкодинг
  ```

### 2. Движок — `Shared/Core/TranscriptionEngine.swift`
- `TranscriptionOptions` получает поле `promptTerms: [String]?`. Подгонка терминов под бюджет идёт **на потоке транскрипции под `whisperLock`**, внутри `run` и `transcribeWindow`. Так вызывающему не нужно отдельно держать замок или грузить модель, как в `FileTranscriptionQueue.fittedPrompt`.
- `fittedPromptLocked(terms:maxTokens:)`:
  - вынесен из `fitPrompt`, и `fitPrompt` вызывает его;
  - кэш по ключу `(terms, maxTokens, generation)`, чтобы стриминг не токенизировал заново каждую секунду;
  - для не-whisper контекста возвращает nil.
- **Бюджет диктовки — 100 токенов**, `DictationDictionary.maxTokens`. В стриминге подсказка = словарь + хвост уже распознанного текста (`prompt(before:)`, ≤200 символов, это ~100 токенов). whisper хранит только последние 224 токена подсказки и отрезает её **начало**, то есть словарь. Поэтому сумма должна укладываться.
- Пакетный режим: `transcribe(samples:options:)` (сейчас всегда `.plain`). `run` уже поддерживает `prompt`, `carry_initial_prompt` и фильтр `isPromptEcho`.
- Стриминг: `transcribeWindow(samples:prompt:promptTerms:language:)` склеивает `словарь + " " + контекст`. На сегменты окна тоже вешается `isPromptEcho`, сравнение со словарной частью, потому что на тишине whisper «распознаёт» саму подсказку.

### 3. macOS
- `DictationCoordinator.makeRecognizer`: на старте сессии читает `DictationDictionary.activeTerms` и передаёт их в оба распознавателя (`init(engine:displayName:promptTerms:)`).
- UI: новая секция «Словарь диктовки» в `ConsolidatedSettingsView`. Это отдельная структура `DictationDictionarySection` в новом файле `macOS/UI/Settings/DictationDictionarySection.swift`. В ней:
  - переключатель «Использовать при диктовке»;
  - `TextEditor`, моноширинный, высота ~180 pt, ширина ≤ 360 pt по правилу окна;
  - сохранение с задержкой 0.5 с после правки;
  - подпись с числом терминов: «N терминов» или «помещается M из N» оранжевым. Логику `scheduleFit` из `VocabularyEditorView` переносим в общий помощник, она считает только при уже загруженной модели. Бюджет — 100 токенов;
  - кнопки:
    - «Загрузить из файла…»: `NSOpenPanel`, `.plainText`, UTF-8. Если текст уже менялся, сначала подтверждение «заменить текущий словарь?»;
    - «Сохранить в файл…»: `NSSavePanel`;
    - «Вернуть пример»: с подтверждением;
  - пометка, если активная модель `!supportsPrompt` (GigaAM): «Текущая модель не использует словарь».

### 4. iOS
- `iOS/Services/TranscriptionService.transcribe(audioData:)` вызывает `engine.transcribeTimed(audioData:options: .init(promptTerms: DictationDictionary.activeTerms))`. Обе точки вызова в `IPCServer` идут через этот метод, так что правка одна.
- UI: в `iOSSettingsView` добавляется `NavigationLink` на `iOS/UI/DictationDictionaryView.swift`. Внутри:
  - `Toggle`, `TextEditor`, подпись с числом терминов;
  - «Импорт» через `.fileImporter([.plainText])` с подтверждением замены;
  - «Экспорт» через `ShareLink` (iOS 16);
  - «Вернуть пример»;
  - пометка про GigaAM.
- Клавиатурное расширение не меняется.

### 5. Локализация
Новые ключи `dictation.dictionary.*` в en/ru/es (`Shared/Resources/*.lproj`). Это заголовок, переключатель, кнопки, подтверждения, подписи с числом терминов (через `.localized(with:)`), пометка про модель и пример. Затем `make lint-l10n`.

### 6. Документация
- Утверждённый дизайн записывается в `docs/plans/2026-10-07-dictation-dictionary-design.md` и коммитится первым.
- В `CLAUDE.md` в разделе Dictation pipeline: словарь диктовки, бюджет 100 токенов и почему (обрезка начала подсказки), выключен по умолчанию и почему, iOS читает его из App Group.

## Критичные файлы
- Новые:
  - `Shared/Core/DictationDictionary.swift`
  - `macOS/UI/Settings/DictationDictionarySection.swift`
  - `iOS/UI/DictationDictionaryView.swift`
- Правки:
  - `Shared/Core/TranscriptionEngine.swift`
  - `Shared/Core/Dictation/WhisperBatchRecognizer.swift`
  - `Shared/Core/Dictation/WhisperStreamingRecognizer.swift`
  - `macOS/App/DictationCoordinator.swift`
  - `macOS/UI/Settings/ConsolidatedSettingsView.swift`
  - `macOS/Services/VocabularyStore.swift` (`parseTerms` → `TermList`)
  - `macOS/UI/Settings/VocabularyEditorView.swift` (общий помощник подсчёта)
  - `iOS/Services/TranscriptionService.swift`
  - `iOS/UI/iOSSettingsView.swift`
  - `Shared/Resources/*/Localizable.strings`
  - `project.yml`, если новые файлы не подхватятся по папкам

## Проверка
- **Юнит-тесты** (`Tests/CorvinTests/DictationDictionaryTests.swift`, чистая логика):
  - `#`-строки отброшены, разделители и дедупликация как у `parseTerms`;
  - пример в каждом из en/ru/es даёт ровно `["Корвин","деплой","вайбкодинг"]`;
  - выключенный или пустой словарь даёт `activeTerms == nil`;
  - `VocabularyStore` после переноса `parseTerms` проходит прежние тесты.
- **Сборка и тесты — только через очередь, в фоне:**
  - `python3 /Users/ss/GenAI/heavy.py run -- swift test`;
  - сборка iOS-симулятора тоже через `heavy.py run --`.
- **Ручная проверка, короткие клипы, с моего согласия.** Установленный Corvin перед этим закрыть, два экземпляра не запускать.
  - macOS: включить словарь, надиктовать «вчера сделали деплой в Корвин» в пакетном и realtime-режимах. В логе `flog` должна быть подсказка, и текст должен совпасть по написанию. С выключенным словарём подсказки нет.
  - Короткое нажатие fn без речи не должно вставлять «Корвин, деплой…» (echo-фильтр).
  - С активной GigaAM видна пометка, диктовка работает как раньше.
  - iOS-симулятор: экран словаря, импорт .txt, сохранение после перезапуска, `activeTerms` в логе host app при IPC-транскрипции.
- **Релиз:** коммит и пуш в main, CI выкладывает iOS в TestFlight. macOS выпускается через `scripts/publish-release.sh` по согласованию.
