# Third Hand: срез для продолжения в Claude Code

Этот файл — рабочая точка передачи проекта, а не полный transcript. Он фиксирует цель, уже сделанное, важные решения, проверенное состояние, ключевые файлы и ближайшие шаги для среза **Third Hand 0.3.0 (build 3)** от **24 августа 2026 года**.

## Что за продукт

Third Hand — нативное local-first приложение для macOS, в котором пользователь создаёт собственных ИИ-агентов с именами, ролями и initial prompt, подключает установленные CLI или API-модели и продолжает работу между исполнителями без ручного пересказа контекста.

Главная ценность продукта — бесшовно передать текущее состояние задачи следующему CLI или API, если у первого исполнителя закончился лимит либо пользователь решил сменить провайдера. Групповые беседы и споры нескольких агентов — отдельный экспериментальный слой, а не обязательный оркестратор и не набор встроенных персонажей.

## Репозиторий и версия

- Репозиторий: `https://github.com/MoonbayStudio/thirdhand`
- Основная ветка: `main`
- База до этого среза: `9e6eda6` — `Add multi-agent chats and unified CLI/API routing`
- Текущий релизный срез: `0.3.0`
- Bundle build: `3`
- Целевой тег: `v0.3.0`
- Платформа: macOS 14+, SwiftUI, SwiftPM, Swift 6.1+
- Источник версии bundle: `APP_VERSION` и `APP_BUILD` в `script/build_and_run.sh`

Проверить версию без сборки:

```bash
./script/build_and_run.sh --version
```

Ожидаемый вывод:

```text
0.3.0 (3)
```

## История этапов

### 0.1.0 (build 1)

Сформирован базовый нативный продукт: персональные агенты и задачи, локальное состояние, запуск CLI, Git-контекст, инспектор, настройки и базовая проверка проектов.

### 0.2.0 (build 2)

Добавлены групповые чаты, единый маршрут CLI/API, Auto failover при подтверждённом исчерпании лимита, Handoff, API-провайдеры с ключами в Keychain, голосовой ввод и 19 локализаций.

### 0.3.0 (build 3) — этот срез

Добавлены постоянные сессии Codex и Claude Code, переносимый checkpoint, slash-команды с inline-токенами, DeepSeek Harness, обновлённые sidebar и профили агентов, production-иконка и двухшаговый onboarding с бренд-анимацией.

## Что уже реализовано в 0.3.0

### Постоянные CLI-сессии и контекст

- Codex запускается через JSON-режим `codex exec` и продолжает сохранённую сессию через `codex exec resume <session-id>`.
- Claude Code создаёт сессию через `--session-id` и продолжает её через `--resume`.
- Привязки сохраняются отдельно по агенту, режиму `conversation`/`workspace` и рабочей директории.
- Antigravity и DeepSeek Harness пока не имеют совместимого нативного resume-контракта и получают переносимый checkpoint.
- `PortableContextCheckpoint` хранит решения, прогресс, известные проблемы, следующий шаг, границу покрытой истории и оценку исходных токенов.
- Старые JSON-состояния продолжают декодироваться: новые поля модели опциональны.

### Slash-команды и composer

В личном чате работают `/context`, `/compact`, `/handoff`, `/model`, `/session` и `/help`.

- Ввод `/` открывает palette.
- После выбора команда превращается в отдельный inline-токен внутри AppKit-backed composer.
- `/compact` создаёт постоянный checkpoint и отвязывает текущую нативную сессию, чтобы следующий запрос начал чистую.
- `/handoff` создаёт переносимый checkpoint, не разрывая текущую сессию.
- `/session status|new|resume|forget` управляет локальными привязками, не удаляя данные самих CLI.
- `/model` показывает доступные модели и меняет модель текущего агента.

### Исполнители и маршрутизация

- CLI: Codex, Claude Code, Antigravity и DeepSeek Harness (`dsh`).
- API: DeepSeek, OpenAI, Anthropic, Gemini и OpenRouter.
- CLI и API остаются равноправными целями.
- Auto меняет исполнителя только после типизированной/подтверждённой ошибки quota; обычные ошибки не должны маскироваться под исчерпание лимита.
- API-ключи хранятся в macOS Keychain и не попадают в `state.json`.
- API получает подготовленный prompt и контекст, но не получает терминал или прямой доступ к файловой системе.

### Онбординг и бренд

- `AppLaunchView` показывает onboarding, пока `completedOnboardingVersion` меньше `OnboardingFlow.currentVersion`.
- Первый экран позволяет выбрать язык и дополнительные настройки универсального доступа; системные настройки macOS открываются отдельной кнопкой.
- Второй экран показывает alpha-видео Third Hand слева от свободной части окна.
- Анимация запускается один раз, останавливается на 5,5 секунде, выключена по звуку и не зацикливается.
- У слоя проигрывателя прозрачный фон; белая подложка не добавляется.
- При Reduce Motion вместо видео используется poster PNG.
- Кнопка «Продолжить» завершает текущий двухшаговый flow. Следующие экраны пока намеренно не спроектированы.
- Production-ресурсы: `ThirdHand.icns`, `third-hand-logo-transparent.mov`, `third-hand-logo-poster.png`.
- Исходники Remotion и прозрачные PNG-слои находятся в `Design/third-hand-logo-animation`.

### Локализация и доступность

- В bundle входят 19 каталогов: `ru`, `en`, `de`, `fr`, `es`, `it`, `pt-BR`, `pl`, `tr`, `uk`, `be`, `kk`, `uz`, `ky`, `tg`, `tk`, `zh-Hans`, `ja`, `ko`.
- На момент среза каждый каталог содержит 379 ключей.
- Приложение сочетает системные настройки Reduce Motion, Reduce Transparency, Differentiate Without Color и Increased Contrast с дополнительными настройками только внутри Third Hand.

## Карта ключевых файлов

| Область | Файлы |
| --- | --- |
| Запуск приложения | `Sources/ThirdHand/App/ThirdHandApp.swift`, `Sources/ThirdHand/Views/Onboarding/AppLaunchView.swift` |
| Онбординг | `Sources/ThirdHand/Views/Onboarding/OnboardingView.swift`, `Sources/ThirdHand/Views/Onboarding/OnboardingVideoView.swift` |
| Основные модели | `Sources/ThirdHand/Models/AppModels.swift`, `Sources/ThirdHand/Models/AgentExecutionModels.swift`, `Sources/ThirdHand/Models/AIAPIModels.swift` |
| Главный state и workflows | `Sources/ThirdHand/Stores/AppStore.swift` |
| CLI-запуск | `Sources/ThirdHand/Services/AgentCLIInvocationFactory.swift`, `Sources/ThirdHand/Services/TaskOrchestrator.swift` |
| API и маршрутизация | `Sources/ThirdHand/Services/AIAPIService.swift`, `Sources/ThirdHand/Services/AutomaticAgentRouter.swift`, `Sources/ThirdHand/Services/AgentRoutingPreferences.swift` |
| Контекст | `Sources/ThirdHand/Services/ConversationEnvelopeBuilder.swift`, `Sources/ThirdHand/Services/PortableContextBuilder.swift` |
| Slash-команды | `Sources/ThirdHand/Services/ChatSlashCommands.swift`, `Sources/ThirdHand/Views/SlashCommandPalette.swift` |
| Composer | `Sources/ThirdHand/Views/InlineTokenComposer.swift`, `Sources/ThirdHand/Views/TaskDetailView.swift` |
| Sidebar и профиль | `Sources/ThirdHand/Views/SidebarView.swift`, `Sources/ThirdHand/Views/AgentProfileComponents.swift`, `Sources/ThirdHand/Views/AgentProfileInspectorView.swift` |
| Persistence | `Sources/ThirdHand/Services/PersistenceService.swift` |
| Bundle | `script/build_and_run.sh`, `Sources/ThirdHand/Resources` |
| Анимация | `Design/third-hand-logo-animation` |
| Основные новые тесты | `Tests/ThirdHandTests/ChatSlashCommandTests.swift`, `Tests/ThirdHandTests/OnboardingResourceTests.swift`, `Tests/ThirdHandTests/AppStoreWorkflowTests.swift`, `Tests/ThirdHandTests/AgentExecutionTests.swift` |

## Важные инварианты

1. Не превращать Third Hand в обязательный «умный оркестратор». Пользователь создаёт агентов и их initial prompts сам.
2. Для handoff передавать цель, сделанное, решения, текущие файлы/состояние и следующий шаг. Полный raw transcript не является обязательным контрактом.
3. Не отправлять API-моделям локальные пути, содержимое вложений или файловый доступ без отдельного явного дизайна и согласия пользователя.
4. Не записывать API-ключи в состояние приложения или логи; использовать Keychain.
5. Не включать `GIT_DIR=/dev/null` в окружение тестов. Эта переменная допустима только внутри build-шага, иначе ломаются тесты временных Git-репозиториев.
6. Сохранять backward-compatible декодирование состояния при добавлении полей.
7. Не возвращать цикл, белый фон или центрирование onboarding-анимации: текущее требование — один проход, прозрачность и размещение слева.
8. Уважать системные настройки доступности и локальный Reduce Motion poster fallback.

## Проверка этого среза

Проверено 24 августа 2026 года:

- Полный suite: **152 теста, 3 live-теста пропущены ожидаемо, 0 failures**.
- Команда: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path .`.
- `npm run lint` в `Design/third-hand-logo-animation`: ESLint и TypeScript прошли.
- `./script/build_and_run.sh --verify`: приложение собрано и процесс `ThirdHand` успешно запущен.
- В собранном `Info.plist`: `CFBundleShortVersionString = 0.3.0`, `CFBundleVersion = 3`, `CFBundleIconFile = ThirdHand.icns`.
- MOV и reduced-motion poster найдены тестами внутри `Bundle.module`.
- Исходный MOV: 1254 × 1254, 7 секунд; проигрывание в onboarding программно ограничено 5,5 секундами.
- Все 19 файлов `Localizable.strings` содержат одинаковые 379 ключей.

Три пропущенных теста обращаются к реальным CLI и включаются только явными environment flags; обычный suite не расходует пользовательские лимиты.

## Что намеренно не попадает в Git

- `.build/`, `.swiftpm/`, `dist/` и IDE-кэши.
- `Design/third-hand-logo-animation/node_modules/` и `out/`.
- `Design/Icon Exports/`: локальный набор экспортных размеров, из которого уже собран production `ThirdHand.icns`.
- `Design/third-hand-logo-transparent.mov`: локальный дубликат production MOV из `Sources/ThirdHand/Resources`.

Это исключение не удаляет локальные файлы. В Git остаются код анимации, исходные слои и все ресурсы, необходимые приложению и повторной сборке анимации.

## Известные ограничения и долги

- Процесс, который выполнялся непосредственно в момент полного Quit, не восстанавливается. Продолжаются завершённые Codex/Claude-сессии по сохранённому ID.
- Для Antigravity и DeepSeek Harness используется checkpoint, а не native resume.
- Встроенная продолжительная TUI, managed worktrees и независимый background runner ещё не реализованы.
- Онбординг пока состоит только из двух экранов; дальнейший сценарий нужно согласовать с пользователем.
- Production MOV весит около 83 МБ. GitHub принимает этот файл как обычный blob, но для будущей истории стоит отдельно решить, нужен ли Git LFS либо более компактный alpha-кодек.
- Текущий bundle-скрипт кладёт SwiftPM resource bundle в два совместимых места, поэтому локальный `.app` занимает около 200 МБ. Перед оптимизацией обязательно проверить, откуда `Bundle.module` находит ресурсы в реально запущенном приложении.
- Полный автоматизированный UI-walkthrough онбординга отсутствует: build/process и ресурсы проверены, а визуальный flow при изменениях нужно проходить вручную.
- Интерактивная проверка поведения split view на минимальной ширине остаётся отдельным QA-пунктом.

## Как продолжить

Сразу после получения репозитория:

```bash
git switch main
git pull --ff-only origin main
git status --short
./script/build_and_run.sh --version
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path .
./script/build_and_run.sh --verify
```

Ожидается чистое рабочее дерево, версия `0.3.0 (3)`, зелёный suite и запущенное приложение.

Перед следующей реализацией:

1. Прочитать `README.md` и этот файл.
2. Проверить актуальный `git status` и не перезаписывать пользовательские изменения.
3. Уточнить следующий экран/цель онбординга, если пользователь не дал конкретный сценарий.
4. После изменений снова проверить тесты, `.app`, bundle metadata и нужный интерактивный UI-flow.
5. Если меняется распространяемый срез, синхронно обновить `APP_VERSION`, `APP_BUILD`, README и этот handoff.
