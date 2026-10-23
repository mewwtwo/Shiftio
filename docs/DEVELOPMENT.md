# Shiftio: development notes

Menubar-програма для macOS (Swift 6 / SwiftUI, macOS 26+, Liquid Glass, Apple silicon, без sandbox, розповсюдження через Developer ID).
Перетягни файл і натисни Shift: біля курсора відкривається кільце дій. Повторний Shift перемикає кільця. Результат зберігається поруч з оригіналом.
Утримання ⌥⇧ (~0,3 с) відкриває pop-up кільце системних елементів керування.

Автор: Dmytro Demchuk. Версія: `CFBundleShortVersionString` у `project.yml`.

## Вимоги

- macOS 26+, Xcode 26+, Mac на Apple silicon (збірка тільки `arm64`).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
- Python 3 з Pillow (лише для перемальовування фону DMG): `pip3 install pillow`.

## Збірка

Проєкт генерується з `project.yml`. Після додавання чи видалення файлів:

```bash
xcodegen generate
```

Збирати треба **поза `~/Desktop`**, інакше codesign падає на xattrs:

```bash
xcodebuild -scheme Shiftio -derivedDataPath ~/Library/Developer/ShiftioDD build
```

Готовий застосунок: `~/Library/Developer/ShiftioDD/Build/Products/Debug/Shiftio.app`.
Перевірити архітектуру: `lipo -archs …/Shiftio.app/Contents/MacOS/Shiftio` → `arm64`.

Підпис у Debug: Apple Development, команда `3MSL3M4D4A`. Дозволи (Bluetooth, Автоматизація тощо) прив'язані до bundle id і підпису. **Не** збирай і не запускай тести з ad-hoc підписом (`CODE_SIGN_IDENTITY=-`): macOS скине дозволи.

## Запуск і перевірка

З Xcode (Run) або так, щоб TCC працював як у звичайному запуску:

```bash
open -n ~/Library/Developer/ShiftioDD/Build/Products/Debug/Shiftio.app --args <аргументи>
```

Корисні аргументи:

| Аргумент | Що робить |
|---|---|
| `-ShiftioPreview` | показує файлове кільце |
| `-ShiftioPreviewControl` | показує pop-up кільце (`-ShiftioControlTile sys-keyboard` відкриває плитку) |
| `-ShiftioPreviewMenu` | вміст меню в рядку меню в окремій панелі (`-ShiftioDemoData` для демо-даних) |
| `-ShiftioOpenSettings -settingsTab general\|rings\|appearance\|about` | відкриває налаштування |
| `-ShiftioRingsCategory system` | вкладка «Rings» відкривається на цій категорії |
| `-ShiftioEditor edit\|crop\|add-bg\|annotate\|redact\|trim\|compress\|info <файл>` | відкриває редактор для файлу |
| `-ShiftioEditorTool filters\|crop\|markup`, `-ShiftioVideoTab clip\|picture\|sound\|overlay\|save` | вкладка редактора |
| `-ShiftioShowOnboarding` / `-ShiftioOnboardingStep 0-3` | стартовий тур / відкрити з певного кроку |
| `-ShiftioShowSetup` | вікно першого запуску (завантаження компонентів) |
| `-ShiftioRenderTab <tab> <png> <висота>` | малює всю вкладку налаштувань у PNG |
| `-ShiftioForceSolid` | суцільне скло |
| `-AppleLanguages "(uk)"` | запуск в іншій мові |

Правила тестування:
- Не роби `pkill -x Shiftio` і не закривай Xcode: програма користувача працює з Xcode. Тестові копії запускай з `&; PID=$!` і гаси `kill $PID`.
- Скріншоти: `screencapture -x -l<id вікна>` або `-R` лише для власного екземпляра.

## Тести

Тести лежать у `ShiftioTests/`. Перевірити, що вони збираються, без підпису й запуску:

```bash
xcodebuild build-for-testing -scheme Shiftio \
  -derivedDataPath /tmp/shiftio-test CODE_SIGNING_ALLOWED=NO
```

Щоб справді запустити, у Xcode (⌘U). Не запускай через ad-hoc підпис з bundle id `com.playgocorp.shiftio`.

## Випуск (DMG)

```bash
scripts/package-dmg.sh            # dist/Shiftio.zip (ad-hoc підпис, тільки для цього Mac)
scripts/package-dmg.sh --dmg      # + dist/Shiftio.dmg із фоном і стрілкою «в Applications»
```

Для розповсюдження: підпис Developer ID і нотаризація.

```bash
# один раз: зберегти дані нотаризації у keychain
xcrun notarytool store-credentials <ім'я-профілю> --apple-id <email> --team-id 3MSL3M4D4A

SIGN_IDENTITY="Developer ID Application: Dmytro Demchuk (3MSL3M4D4A)" \
NOTARY_PROFILE=<ім'я-профілю> \
scripts/package-dmg.sh --dmg
```

Скрипт збирає Release, перевіряє підпис, пакує, підписує образ, відправляє на нотаризацію й ставить staple.

- Перед запуском **витягни** змонтований `/Volumes/Shiftio`, інакше `make-dmg.sh` зупиниться (Finder визначає диск за назвою).
- Перший запуск може запросити дозвіл терміналу керувати Finder.
- Вигляд інсталятора: `scripts/make-dmg-background.py` (перемальовує `dmg-background.png`), розставлення іконок у `scripts/make-dmg.sh`.
- Окремо: `scripts/make-dmg.sh <Shiftio.app> <вихід.dmg>`; `DMG_VOLUME=Назва` змінює назву тому (для тестів).

## Налаштування, які треба пам'ятати

- Змінюєш стандартні кільця: збільш `RingConfig.defaultsVersion` (`Actions/ActionProfile.swift`) і додай міграцію в `ConfigStore.init`.
- Будь-який TCC-чутливий виклик (Bluetooth, SSID Wi-Fi, Apple Events) потребує usage-рядка в `project.yml`, інакше програму вбиває система. Відкриття кільця саме не повинно викликати запит дозволу.
- До вигляду з `.glassEffect` не застосовуй opacity, rotation і scale (SwiftUI сплющує скло). Один `GlassEffectContainer`, `glassEffectID`, `.glassEffectTransition(.materialize)`.
- Вікно налаштувань зберігає розмір при перемиканні вкладок. Системних сповіщень немає.

## Локалізація

11 мов: en, uk, es, pt, ja, zh-Hans, ko, fr, cs, it, id. Каталоги: `Shiftio/Resources/Localizable.xcstrings` та `InfoPlist.xcstrings` (тексти запитів дозволів). Мову вибирає користувач у Settings → General; якщо мова системи не підтримується, показується англійська.

- Новий текст: літерал SwiftUI (`Text("…")`) або `String(localized: "…")` для звичайних `String` (назви, помилки, підказки панелей). Однакове слово з різним змістом отримує окремий ключ: `String(localized: "compress.light", defaultValue: "Light")`.
- Кожен новий ключ перекласти на всі мови (у Xcode відкрий `Localizable.xcstrings`). Зберігай `%@` і `%lld`, не використовуй множину.
- Перевіряй вигляд у довгих мовах (uk, pt, fr, cs) і CJK, див. аргументи вище.

## Структура (`Shiftio/`)

- `Actions/`: `FileAction`, реєстр, конвертери, `ControlAction` (плитки pop-up кільця), `ActionProfile.swift` (кільця за замовчуванням).
- `Radial/`: панель кільця, геометрія, скло.
- `Settings/`: `ConfigStore` (config.json + міграції), `SettingsView`, `RingEditor`, `AppLanguage`.
- `Apps/`: `AppUsage`, `AppPins`, `FolderPins`, `TelegramChats`, `ToolUsage`.
- `Editors/`, `Converters/`, `Components/` (завантаження LAME і моделі мовлення при першому запуску), `Trigger/`, `TouchBar/`, `NowPlaying/`, `Onboarding/`.

## Де лежать дані

- Конфіг: `~/Library/Application Support/Shiftio/config.json`.
- Історія програм/інструментів, аватарки чатів, завантажені компоненти: поруч, у `Application Support/Shiftio/`.
- Прості налаштування (закріплені програми, папки, чати, мова): UserDefaults `com.playgocorp.shiftio`.
