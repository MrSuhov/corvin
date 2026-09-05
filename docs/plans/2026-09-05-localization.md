# Trilingual Corvin: ru + en + es

Record of what was decided and, more usefully, what was decided *against*.

## The bug underneath all of it

`Bundle.setLanguage` installed the chosen `.lproj` bundle and then a `defer`
block cleared it. `defer` runs on the success path too, one instruction later, so
`localizedBundle` always returned `Bundle.main` and every `.localized` lookup
resolved against the system language. **The in-app language picker had never
worked**, on either platform, since the initial commit.

The "restart required" caption in macOS settings was the fossil of someone
noticing the symptom and not finding the cause. It has been deleted along with
its key.

Corollary worth remembering: the 222 en/ru pairs that predate this were never
seen rendered through the picker. Treat them as unverified — the format-specifier
check in the linter exists partly for them.

## Deliberate non-decisions

**No String Catalogs (`.xcstrings`).** Their one real advantage is automatic key
extraction, and it does not apply: Xcode extracts from `Text("literal")`,
`String(localized:)` and `NSLocalizedString`, not from this codebase's
`"key".localized`. Rewriting ~330 call sites to earn it would also break the
picker, because `Text("literal")` looks up in `Bundle.main` and takes no bundle
argument. Separately, SPM 5.9 cannot compile `.xcstrings` at all, and the macOS
release path is `swift build` plus `scripts/build-dmg.sh`. The IDE affordance
catalogues would have given — "this key is missing in es" — is what
`scripts/check-localization.py` gives, in CI, where it can block a release.

**No SPM `resources:` for the strings.** That would move them into
`Bundle.module` and break `Bundle.main.path(forResource:ofType:"lproj")`, which
the picker depends on. `build-dmg.sh` copies `*.lproj` into the app bundle by
glob, so Spanish needed no script change.

**The keyboard extension has its own catalogue, not a copy of the app's.** Inside
an app extension `Bundle.main` is the appex, so it cannot read the host app's
strings; and XcodeGen assigns each path to exactly one target, so pointing both
at `Shared/Resources` silently yields no resources for the second. The extension
carries only the six keys it renders. `common.duration.seconds` is in both
catalogues on purpose.

**`SessionState.error(String)` keeps a resolved string.** Its payload crosses the
IPC boundary between the app and a separately-installed keyboard extension and
feeds `Equatable`. Making it a `LocalizedMessage` would mean versioning that
protocol for a string that is on screen for two seconds during dictation. The
stale-language window is accepted; do not "fix" it.

**App Intents, Siri phrases and permission dialogs follow the system language.**
`LocalizedStringResource` resolves against `Bundle.main`'s preferred localization
and cannot see the swapped bundle. This is correct for system surfaces and is not
a bug.

**`CFBundleDisplayName` is not localized.** "Corvin" is a brand and reads the same
in all three languages.

## Mechanism, in one paragraph

`LocalizedBundle` holds the bundle and the matching `Locale`; `String.localized`
resolves against it, `.localized(with:)` formats with that locale — required, or
`.stringsdict` plural templates come back unexpanded and `%f` uses a POSIX
decimal point. One `.id(localization.currentLanguage)` at the iOS root rebuilds
everything, so no individual view needs to know localization exists. macOS does
the same per window, plus a notification for the AppKit menu. Text held in
view-model state uses `LocalizedMessage`, which stores a key.

## Adding a fourth language

1. `Shared/Resources/<lang>.lproj/` — `Localizable.strings`, `Localizable.stringsdict`,
   `InfoPlist.strings`, `AppShortcuts.strings`.
2. `CorvinKeyboard/Resources/<lang>.lproj/Localizable.strings` — six keys.
3. One case in `AppLanguage`, one entry in `CFBundleLocalizations` in all three
   Info.plists, one entry in the `LANGS` list in `scripts/screenshots-appstore.sh`.
4. `make lint-l10n` names anything missed.

## Что съёмка скриншотов на трёх языках вскрыла

Ни одно из этого не видно, пока снимаешь один язык.

**Раскладку клавиатуры держит KeyboardKit в настройках расширения**, а не в App
Group, — и переустановка оставляет рядом с живым контейнером мёртвый, снаружи
неотличимый. Поэтому скрипт засеивает
`com.keyboardkit.settings.keyboard.localeIdentifier` во *все* контейнеры
расширения, а не в первый попавшийся.

**Тапы теряются примерно раз из четырёх.** Молча: следующий кадр просто повторял
предыдущий экран, и один прогон дал побайтово одинаковую пару
`03-history`/`04-settings`. И вкладки, и поле поиска теперь жмутся с проверкой
результата, а не «на веру».

**Идентификатор с `Image` внутри `tabItem` до кнопки таб-бара не доходит**
(iOS 26.1 — у всех кнопок он пустой), а подписи локализованы. Вкладки выбираются
по позиции — по порядку объявления в `MainView`.

**`app.keyboards` не видит клавиатуру расширения** — она в другом процессе.
Её клавиши в дереве запросов есть, поэтому «клавиатура поднялась» проверяется
через `app.keys`, а «это именно Corvin» — по клавише push-to-talk.

**iOS открывает ту клавиатуру, что использовалась последней**, и это переживает
перезагрузку симулятора, так что один тап по «глобусу» с равной вероятностью
уводит *с* Corvin.
