# RFC-001: архитектура Third Hand

- **Статус:** Draft
- **Тип:** архитектурный RFC
- **Целевая платформа:** macOS
- **Основной UI:** SwiftUI
- **Язык реализации:** Swift 6
- **Дата:** 2026-07-22
- **Авторская роль документа:** lead architecture proposal

## 0. Резюме

Third Hand — нативное macOS-приложение для управления продолжительными задачами программирования, которые выполняются официальными CLI-агентами пользователя: Codex CLI, Claude Code, Antigravity CLI и будущими адаптерами.

Приложение не является AI-чатом, терминальным мультиплексором или прокси к закрытым API. Оно управляет жизненным циклом задач, запускает официальные CLI в PTY, наблюдает за Git-репозиториями, хранит минимальное состояние оркестрации, запускает проверочные команды и безопасно передаёт незавершённую задачу другому агенту без передачи истории диалога.

Главное архитектурное правило:

> Код и фактическое состояние результата восстанавливаются из Git и рабочей директории. Локальная база Third Hand хранит только состояние оркестрации, доказательства проверок, компактный handoff и журнал событий.

Второе обязательное правило:

> В один writable worktree одновременно пишет только один агент. Параллельная работа в одном репозитории выполняется через отдельные worktree и ветки, а затем проходит явную интеграцию.

Третье обязательное правило:

> После переключения новый агент сначала проводит аудит текущего состояния и только затем получает право продолжить реализацию. Handoff не является доказательством корректности.

## 1. Цели и не-цели

### 1.1. Цели

Third Hand должен:

1. Представлять работу через Task, а не через conversation.
2. Продолжать Task после исчерпания лимита, сбоя или недоступности конкретного агента.
3. Не зависеть от истории терминальной сессии для восстановления контекста.
4. Использовать официальный CLI и существующую подписку пользователя.
5. Поддерживать несколько репозиториев, задач и одновременно запущенных агентов.
6. Обеспечивать наблюдаемость: что выполняется, кем, в каком worktree, с каким Git-состоянием и результатами проверок.
7. Не скрывать сомнительные состояния под видом успешного завершения.
8. Быть полноценным desktop-приложением: sidebar, detail, inspector, toolbar, команды, уведомления и клавиатурные действия.
9. Переживать закрытие окна; по выбранной политике — продолжать фоновые сессии, пока приложение не завершено.
10. Иметь расширяемую адаптерную архитектуру без привязки доменной модели к конкретному CLI.

### 1.2. Не-цели первой версии

1. Собственный LLM API-клиент.
2. Обход лимитов или правил провайдеров.
3. Эмуляция приватных API официальных клиентов.
4. Полноценная IDE или замена Xcode, VS Code и JetBrains.
5. Автоматическое объединение произвольных конфликтующих изменений без проверки.
6. Гарантия безопасности кода, запущенного агентом с правами пользователя.
7. Распределённая оркестрация между несколькими компьютерами.
8. Облачная синхронизация терминальных журналов и репозиториев.
9. Автоматический push, merge или публикация без явно заданной пользовательской политики.

## 2. Архитектурные решения верхнего уровня

### 2.1. Не один источник истины, а два разных класса истины

Фраза «Git — единственный источник истины» полезна как продуктовый принцип, но технически недостаточна. Git не знает:

- какой агент сейчас владеет Task;
- почему остановилась PTY-сессия;
- ждёт ли CLI подтверждения;
- какой build был запущен и на каком diff;
- когда обновлялся handoff;
- почему маршрутизатор выбрал другого агента;
- какие уведомления уже показаны.

Поэтому RFC вводит разделение:

| Область | Источник истины |
| --- | --- |
| Файлы, HEAD, index, ветка, diff, untracked-состояние | Git и рабочий каталог |
| Жизненный цикл Task, попытки, leases, approvals, routing | локальный event journal |
| Текущая UI-проекция | материализованные представления из event journal и Git snapshots |
| Build/test evidence | сохранённый результат команды, привязанный к Git fingerprint |
| Semantic handoff | компактная версионируемая запись, привязанная к checkpoint |
| Терминальный вывод | диагностический поток, не доменная истина |

Это лучше, чем пытаться записать всё в Git или восстанавливать всё из чата: данные имеют разную природу, срок жизни и требования к транзакционности.

### 2.2. Task, Attempt и Session — разные сущности

- **Task** — пользовательская цель, живущая дольше любого агента.
- **Attempt** — период, когда конкретный Agent Installation исполняет Task.
- **PTY Session** — конкретный OS-процесс и терминальный канал внутри Attempt.

Один Task может иметь много последовательных Attempt. Один Attempt обычно имеет одну основную PTY Session, но может создавать дочерние процессы. Разделение не позволяет ошибочно считать завершение процесса завершением задачи.

### 2.3. Один writer на worktree

Несколько агентов могут работать одновременно:

- в разных репозиториях;
- в разных worktree одного репозитория;
- в read-only роли над одним состоянием;
- в отдельных подзадачах с последующей интеграцией.

Два агента не должны одновременно писать в один worktree. Для каждого writable Task создаётся <code>WorktreeLease</code>. Нарушение lease переводит Task в <code>conflictRisk</code> и останавливает автоматическую маршрутизацию.

### 2.4. Event-driven core, а не UI-driven scripts

SwiftUI не запускает процессы напрямую. UI отправляет команды в application layer, а core публикует типизированные события. Это позволяет:

- восстановить состояние после перезапуска UI;
- тестировать state machines без настоящих CLI;
- не связывать PTY callbacks с view lifecycle;
- сериализовать опасные операции;
- строить аудит решений маршрутизатора.

### 2.5. Adapter + capability model вместо общего знаменателя CLI

Каждый CLI отличается:

- способом запуска и продолжения;
- наличием JSON/JSONL режима;
- форматом запросов подтверждения;
- кодами выхода;
- поведением при лимите;
- поддержкой sandbox/approval modes;
- возможностью отправить checkpoint-команду.

Поэтому Agent — не один Process с названием executable. Используется versioned adapter с capability negotiation. Core спрашивает «что эта установка умеет», а не предполагает одинаковое поведение.

### 2.6. Двухфазный handoff: Audit Gate → Execution

После переключения новый агент не получает статус <code>runningImplementation</code> сразу. Он проходит:

1. <code>auditPending</code>;
2. <code>auditingRepository</code>;
3. формирует <code>DiffAssessment</code>;
4. только затем переходит в <code>executing</code>.

Если CLI поддерживает read-only/plan mode, Audit Gate технически ограничивает запись. Если не поддерживает, ограничение остаётся наблюдаемой политикой: Git monitor фиксирует преждевременные изменения, Task ставится на паузу, но приложение ничего автоматически не откатывает.

### 2.7. Distribution-first ограничение

Для запуска произвольных пользовательских CLI, доступа к их конфигурации и работы с произвольными репозиториями наиболее реалистичная первая поставка — подписанное и notarized Developer ID приложение вне Mac App Store, с Hardened Runtime, но без App Sandbox.

Sandbox-вариант требует security-scoped bookmarks, передачи доступа helper-процессам и сталкивается с доступом CLI к пользовательским конфигурациям, toolchains и дочерним процессам. Это нужно отдельно исследовать, но не делать скрытым допущением MVP.

## 3. Общая архитектура

~~~mermaid
flowchart TB
    UI["SwiftUI App Shell"]
    APP["Application Services"]
    ORCH["Task Orchestrator"]
    ROUTER["Agent Router"]
    POLICY["Policy and Approval Engine"]
    STORE["Event Store and Projections"]
    GIT["Git Service"]
    VALID["Validation Service"]
    ADAPTER["Agent Adapter Registry"]
    RUNNER["Runner Service"]
    PTY["PTY Sessions"]
    CLI["Official CLI Processes"]
    REPO["Repositories and Worktrees"]
    NOTIFY["Notification Service"]

    UI --> APP
    APP --> ORCH
    ORCH --> ROUTER
    ORCH --> POLICY
    ORCH --> GIT
    ORCH --> VALID
    ORCH --> ADAPTER
    ORCH --> RUNNER
    ORCH --> STORE
    RUNNER --> PTY
    PTY --> CLI
    CLI --> REPO
    GIT --> REPO
    VALID --> REPO
    RUNNER --> ORCH
    GIT --> ORCH
    VALID --> ORCH
    ORCH --> NOTIFY
    STORE --> UI
~~~

### 3.1. Процессы

#### ThirdHand.app

Содержит:

- SwiftUI scenes;
- presentation stores;
- application services;
- Task Orchestrator;
- persistence;
- Git coordinator;
- routing и policy engine;
- notifications.

#### ThirdHandRunner

Отдельный bundled helper/XPC service:

- создаёт и держит PTY;
- запускает CLI;
- управляет process group;
- передаёт вход/выход;
- сообщает exit status и сигналы;
- ограничивает память output buffer;
- изолирует UI от падений terminal emulator или subprocess glue.

Для MVP Runner живёт как XPC service внутри app bundle. Если требуется продолжение после полного завершения UI-процесса или повышенная crash-resilience, следующая итерация заменяет lifecycle на background agent через поддерживаемый macOS-механизм, сохраняя тот же IPC-контракт.

#### CLI process tree

Каждый Attempt получает:

- абсолютный путь к executable;
- аргументы как массив, без shell-конкатенации;
- cwd конкретного worktree;
- контролируемое окружение;
- PTY slave как stdin/stdout/stderr;
- отдельную session/process group;
- terminal size;
- уникальный correlation ID.

### 3.2. Слои

| Слой | Ответственность | Не должен знать |
| --- | --- | --- |
| Presentation | отображение и intents | детали PTY, SQL, конкретные CLI |
| Application | use cases и команды | ANSI-парсинг, Git plumbing |
| Domain | state machines и инварианты | SwiftUI, Foundation Process |
| Infrastructure | Git, DB, PTY, notifications | продуктовые решения без policy |
| Adapters | особенности конкретных CLI | UI layout и persistence schema |

## 4. Основные модули

### 4.1. AppShell

Формирует нативную macOS-модель сцен:

- основной <code>WindowGroup</code>;
- отдельный <code>Settings</code>;
- опциональный singleton Agent Monitor;
- опциональный <code>MenuBarExtra</code> для фоновых задач и approvals.

Основная компоновка:

- sidebar: репозитории, smart filters, задачи;
- content/detail: выбранная Task;
- inspector: активный Attempt, agent, Git snapshot, ресурсы;
- toolbar: Start, Pause, Stop, Switch Agent, Checkpoint, Validate;
- нижняя раскрываемая Agent Console как диагностическая поверхность.

Terminal не является центральным экраном. По умолчанию пользователь видит цель, этапы, diff summary, проверки, blockers и approvals.

### 4.2. TaskOrchestrator

Единственный компонент, меняющий доменное состояние Task. Реализуется как Swift actor и:

- принимает команды;
- проверяет допустимость перехода;
- создаёт domain events;
- координирует саги start, stop, checkpoint, switch, validate;
- обеспечивает idempotency;
- восстанавливает незавершённые операции после запуска.

### 4.3. RepositoryRegistry

Отвечает за:

- добавление и удаление ссылок на репозитории;
- канонизацию пути;
- persistent bookmark, если понадобится sandbox;
- обнаружение перемещения/недоступности;
- определение Git root и common dir;
- хранение trust-настроек;
- связь репозитория с worktree.

### 4.4. GitService

Предоставляет типизированные операции:

- inspect repository;
- capture snapshot;
- create/list/lock/remove worktree;
- compute diff and stat;
- enumerate changed files;
- detect merge/rebase/cherry-pick/bisect;
- calculate diff fingerprint;
- create optional recovery checkpoint ref;
- compare two checkpoints.

Все команды выполняются с фиксированным cwd, массивом argv, locale-stable настройками и machine-readable форматами, где они есть.

### 4.5. WorktreeManager

Управляет физической изоляцией задач:

- создаёт ветку вида <code>third-hand/task-shortID</code>;
- создаёт linked worktree в Application Support или выбранном пользователем каталоге;
- ставит Git worktree lock с причиной;
- выдаёт и освобождает <code>WorktreeLease</code>;
- не удаляет dirty worktree автоматически;
- поддерживает repair flow для перемещённых репозиториев;
- отслеживает submodule/LFS ограничения.

### 4.6. AgentRegistry

Хранит:

- известные типы агентов;
- найденные installations;
- абсолютные executable paths;
- версии;
- availability;
- auth readiness;
- capabilities;
- пользовательский приоритет;
- cooldown и health history.

### 4.7. AgentAdapterRegistry

Выбирает адаптер по agent kind и version range. Адаптер:

- строит launch specification;
- формирует стартовый Task Envelope;
- интерпретирует structured events или terminal observations;
- классифицирует stop reason;
- распознаёт approval request;
- поддерживает checkpoint handshake;
- сообщает confidence каждой классификации.

### 4.8. RunnerClient и RunnerService

RunnerClient — инфраструктурный клиент приложения. RunnerService — отдельный процесс. IPC-сообщения типизированы и versioned:

- create session;
- write bytes;
- resize;
- send interrupt;
- terminate;
- subscribe;
- query sessions;
- acknowledge event.

### 4.9. TerminalPipeline

Содержит независимые компоненты:

- byte stream;
- incremental UTF-8 decoder;
- ANSI/VT parser;
- screen buffer для визуализации;
- semantic observer для адаптеров;
- bounded scrollback;
- optional raw log sink;
- redaction stage.

Доменный слой не читает SwiftUI terminal view напрямую.

### 4.10. CheckpointService

Создаёт логический checkpoint, запрашивает handoff, привязывает проверки к Git fingerprint и при включённой политике создаёт recovery ref.

### 4.11. ValidationService

Запускает доверенные build/test recipes отдельно от агента. Это принципиально: фраза агента «tests pass» не считается последним достоверным результатом.

### 4.12. AgentRouter

Фильтрует неподходящих кандидатов, рассчитывает score, учитывает cooldown, нагрузку, требования Task и user policy. Каждое решение сохраняется как <code>RoutingDecision</code> с объяснением.

### 4.13. ApprovalCenter

Нормализует неодинаковые prompts CLI в общую модель:

- что запрошено;
- инициатор;
- риск;
- scope;
- возможные ответы;
- timeout;
- исходный terminal excerpt.

Не подтверждает опасные действия автоматически.

### 4.14. EventStore

Append-only журнал доменных событий плюс материализованные projections. Рекомендуемая реализация — SQLite с явными миграциями и транзакциями. Доступ скрывается за протоколом, чтобы UI и domain не зависели от выбранной библиотеки.

Большие terminal/build logs хранятся отдельными сжатыми файлами, а DB содержит ссылки, checksum и retention metadata.

### 4.15. NotificationService

Отправляет локальные macOS notifications:

- требуется подтверждение;
- все подходящие агенты недоступны;
- Task завершена;
- проверка упала;
- обнаружен конфликт;
- репозиторий стал недоступен.

Безопасный default action — открыть Task. Опасные подтверждения не выполняются одним нажатием из баннера без контекста.

## 5. Поток данных

### 5.1. Создание и запуск Task

~~~mermaid
sequenceDiagram
    actor User
    participant UI
    participant O as Orchestrator
    participant G as GitService
    participant W as WorktreeManager
    participant R as AgentRouter
    participant A as AgentAdapter
    participant X as Runner
    participant DB as EventStore

    User->>UI: Создать Task
    UI->>O: CreateTask command
    O->>G: Inspect repository
    G-->>O: RepositorySnapshot
    O->>W: Allocate writable worktree
    W-->>O: WorktreeLease
    O->>DB: TaskCreated and WorktreeAllocated
    O->>R: Select candidate
    R-->>O: RoutingDecision
    O->>A: Build audit envelope
    A-->>O: LaunchSpec and prompt
    O->>X: Start PTY session
    X-->>O: SessionStarted
    O->>DB: AttemptStarted
    O-->>UI: Updated projection
~~~

### 5.2. Runtime feedback loop

1. Runner получает bytes от PTY.
2. TerminalPipeline обновляет screen buffer.
3. Adapter анализирует только необходимые признаки и structured frames.
4. Orchestrator получает observations с confidence.
5. Git watcher debounce-сигнализирует об изменениях; GitService делает новый snapshot.
6. Domain events транзакционно обновляют projections.
7. SwiftUI подписан на projections, а не на бесконечный stdout.
8. При значимом этапе CheckpointService запускает checkpoint saga.

### 5.3. Проверка

1. Пользователь, policy или агент отмечает этап готовым.
2. Orchestrator фиксирует Git fingerprint.
3. ValidationService запускает recipe на том же worktree.
4. Результат получает exit code, duration, bounded log, parser summary.
5. После завершения повторно снимается fingerprint.
6. Если код изменился во время проверки, результат помечается <code>stale</code>.
7. Только non-stale success может считаться актуальным доказательством.

## 6. Доменная модель данных

### 6.1. Идентификаторы

Все сущности используют стабильные UUID:

- <code>RepositoryID</code>;
- <code>WorktreeID</code>;
- <code>TaskID</code>;
- <code>StepID</code>;
- <code>AttemptID</code>;
- <code>SessionID</code>;
- <code>CheckpointID</code>;
- <code>HandoffRevisionID</code>;
- <code>ValidationRunID</code>;
- <code>ApprovalRequestID</code>;
- <code>AgentInstallationID</code>.

Пути, названия веток и PID не используются как идентичность.

### 6.2. Repository

| Поле | Назначение |
| --- | --- |
| id | стабильный ID |
| displayName | имя для UI |
| rootLocator | bookmark или canonical URL |
| gitCommonDir | диагностический cache |
| trustState | unknown, trusted, revoked |
| availability | available, moved, unmounted, permissionDenied |
| defaultBranch | обнаруженное значение |
| remoteSummary | имена remotes без credentials |
| createdAt, lastSeenAt | lifecycle |

Remote URL должен проходить redaction: userinfo и потенциальные tokens не сохраняются.

### 6.3. Worktree

| Поле | Назначение |
| --- | --- |
| id | WorktreeID |
| repositoryID | родительский репозиторий |
| pathLocator | путь/bookmark |
| branchRef | выделенная ветка |
| baseRevision | SHA старта |
| gitWorktreeName | техническое имя |
| ownership | managed или external |
| leaseTaskID | текущий writer |
| lockState | Git lock и app lease |
| cleanupState | active, retainedDirty, removable, missing |

### 6.4. GitSnapshot

Это immutable cache наблюдения:

- capturedAt;
- worktreeID;
- headOID;
- branch;
- upstream;
- ahead/behind;
- porcelain-v2 status;
- changed file summaries;
- diffStat;
- diffDigest;
- indexDigest;
- untracked manifest digest;
- repository operation state;
- isDirty;
- isTruncated;
- capture errors.

Snapshot не заменяет Git. UI всегда показывает время снимка и умеет обновить его.

### 6.5. TaskStep

Содержит:

- id;
- title;
- optional description;
- ordinal;
- status: planned, active, blocked, completed, skipped, invalidated;
- acceptance criteria;
- createdBy: user, agent, app;
- completedAt;
- checkpointID;
- invalidation reason.

Step не должен автоматически становиться completed только по тексту терминала. Нужен checkpoint marker, действие пользователя или явное структурированное событие с подходящим confidence.

### 6.6. Attempt

| Поле | Назначение |
| --- | --- |
| taskID | родительская Task |
| agentInstallationID | конкретный CLI |
| adapterVersion | версия интерпретации |
| role | auditor, implementer, reviewer, integrator |
| state | lifecycle попытки |
| startedAt, endedAt | время |
| startCheckpointID | точка входа |
| endCheckpointID | точка выхода |
| terminationReason | нормализованная причина |
| rawExit | exit code/signal |
| classificationConfidence | уверенность |
| sessionIDs | связанные PTY |

### 6.7. VerificationRun

- kind: build, test, lint, custom;
- recipeID и recipeRevision;
- argv display с redaction;
- cwd relative to worktree;
- startedAt, endedAt;
- exit code;
- outcome: passed, failed, cancelled, timedOut, infrastructureError;
- gitFingerprintBefore/After;
- freshness: current или stale;
- summary;
- log artifact reference;
- parsed diagnostics;
- attemptID, checkpointID.

### 6.8. Event

Каждое событие имеет:

- monotonically increasing local sequence;
- event UUID;
- entity ID;
- type;
- schema version;
- timestamp;
- causation ID;
- correlation ID;
- actor: user, system, agent, recovery;
- payload;
- optional idempotency key.

Примеры: <code>TaskCreated</code>, <code>AttemptStarted</code>, <code>GitSnapshotCaptured</code>, <code>ApprovalRequested</code>, <code>CheckpointCommitted</code>, <code>AgentQuotaDetected</code>, <code>SwitchCompleted</code>.

## 7. Модель Task

### 7.1. Task как aggregate root

Task объединяет цель и оркестрацию, но не копирует содержимое репозитория.

~~~text
Task
├── identity and immutable original request
├── repository and worktree binding
├── execution policy
├── plan and step projection
├── current lifecycle state
├── current attempt reference
├── current checkpoint reference
├── current semantic handoff reference
├── latest fresh validation references
└── event stream
~~~

### 7.2. Рекомендуемые поля Task

| Группа | Поля |
| --- | --- |
| Identity | id, title, createdAt, updatedAt |
| Intent | originalRequest, optional userConstraints, acceptanceCriteria |
| Repository | repositoryID, worktreeID, baseRevision, targetBranchPolicy |
| State | lifecycleState, attentionState, completionAssessment |
| Plan | ordered step IDs, currentStepID |
| Runtime | activeAttemptID, preferredAgents, routingPolicy |
| Recovery | latestCheckpointID, latestHandoffID |
| Evidence | latestBuildRunID, latestTestRunID, latestGitSnapshotID |
| Policy | approvalPolicy, concurrencyPolicy, checkpointPolicy, retentionPolicy |

<code>originalRequest</code> immutable. Если пользователь уточняет задачу, создаётся <code>TaskRequirementAmended</code> с новой ревизией требований; исходная формулировка не теряется.

### 7.3. Task state machine

~~~mermaid
stateDiagram-v2
    [*] --> Draft
    Draft --> Ready
    Ready --> Preparing
    Preparing --> Auditing
    Auditing --> Executing
    Executing --> AwaitingApproval
    AwaitingApproval --> Executing
    Executing --> Checkpointing
    Checkpointing --> Executing
    Executing --> Validating
    Validating --> Executing
    Validating --> Completed
    Executing --> Switching
    Auditing --> Switching
    Switching --> Auditing
    Preparing --> Blocked
    Auditing --> Blocked
    Executing --> Blocked
    Validating --> Blocked
    Blocked --> Preparing
    Executing --> Paused
    AwaitingApproval --> Paused
    Paused --> Preparing
    Draft --> Cancelled
    Ready --> Cancelled
    Preparing --> Cancelled
    Auditing --> Cancelled
    Executing --> Cancelled
    Paused --> Cancelled
    Blocked --> Cancelled
    Completed --> [*]
    Cancelled --> [*]
~~~

Task lifecycle и Attempt lifecycle хранятся раздельно. Например, Attempt может быть <code>quotaBlocked</code>, а Task уже <code>switching</code>.

### 7.4. Завершение Task

Task не завершается только потому, что CLI завершился с кодом 0 или написал «done». Completion policy проверяет:

1. нет активной PTY;
2. Git snapshot получен после последнего изменения;
3. обязательные steps завершены;
4. обязательные validation recipes имеют fresh success;
5. нет unresolved approval/blocker;
6. финальный handoff сформирован;
7. completion assessment содержит основания и остаточные риски.

Если проверки не настроены, UI показывает <code>Completed — unverified</code>, а не зелёный проверенный успех.

### 7.5. Progress

Progress — не произвольный процент агента. Варианты:

- доля завершённых взвешенных steps;
- состояние текущего этапа;
- отдельный indeterminate режим, если план ещё не сформирован.

Процент всегда сопровождается текстом: <code>3 из 5 этапов, тесты не запускались</code>.

## 8. Абстракция Agent

### 8.1. Термины

- **AgentKind:** Codex, ClaudeCode, Antigravity, future.
- **AgentInstallation:** конкретный executable на Mac пользователя.
- **AgentAdapter:** код интеграции с семейством версий CLI.
- **AgentCapabilitySet:** обнаруженные возможности.
- **AgentHealth:** операционная готовность сейчас.
- **AgentProfile:** предпочтения пользователя и routing metadata.

### 8.2. Концептуальный контракт

~~~swift
protocol AgentAdapter {
    var kind: AgentKind { get }
    func supports(version: SemanticVersion) -> Bool
    func probe(installation: AgentInstallation) async -> ProbeResult
    func capabilities(for probe: ProbeResult) -> AgentCapabilitySet
    func makeAuditLaunch(context: TaskContext) throws -> LaunchSpecification
    func makeExecutionLaunch(context: TaskContext) throws -> LaunchSpecification
    func consume(event: TerminalEvent, state: AdapterState) -> [AgentObservation]
    func makeCheckpointRequest(policy: CheckpointPolicy) -> AgentInput?
    func classifyTermination(_ evidence: TerminationEvidence) -> StopClassification
}
~~~

Это иллюстрация контракта, не готовый API.

### 8.3. Capability flags

Минимальный набор:

- interactivePTY;
- structuredOutput;
- resumableSession;
- readOnlyMode;
- planMode;
- explicitApprovalEvents;
- documentedNonInteractiveInput;
- checkpointPrompt;
- usageLimitSignal;
- authProbe;
- modelSelection;
- workspaceTrustMode.

Нельзя считать capability существующей только потому, что она была в прошлой версии CLI. Probe сохраняет version и дату.

### 8.4. LaunchSpecification

Содержит:

- resolved executable URL;
- argv;
- cwd;
- sanitized environment;
- terminal type и size;
- input mode;
- adapter protocol version;
- required file access;
- expected structured channel;
- timeout только для startup handshake;
- redaction rules.

Никаких строк вида <code>shell -c "..."</code> для обычного запуска. Shell допускается только как явно доверенный пользовательский recipe.

### 8.5. Поиск executable

XPC и GUI-приложение не должны полагаться на интерактивный <code>PATH</code>. Алгоритм:

1. пользователь может выбрать executable вручную;
2. приложение проверяет известные безопасные каталоги;
3. однократный Environment Resolver может спросить login shell о PATH;
4. путь канонизируется с разрешением symlink;
5. сохраняются path, version, file identity и optional code-signing metadata;
6. перед запуском выполняется дешёвая revalidation.

Startup scripts пользователя не исполняются для каждого Attempt.

### 8.6. Auth и подписка

Third Hand:

- не читает и не переносит токены;
- не логирует содержимое credential files;
- не выполняет вход от имени пользователя;
- запускает официальный auth flow CLI в PTY, если пользователь выбрал его;
- различает <code>installed</code>, <code>authUnknown</code>, <code>authRequired</code>, <code>ready</code>.

### 8.7. AgentObservation

Observation не равен domain event. Возможные наблюдения:

- ready;
- meaningfulProgress;
- checkpointSuggested;
- approvalPrompt;
- idlePrompt;
- limitLikely;
- authRequired;
- transientNetworkFailure;
- taskClaimedComplete;
- processExited;
- protocolDesynchronized.

Каждое содержит evidence, confidence и adapter rule version. Orchestrator решает, что делать.

### 8.8. Классификация лимита

Автопереключение разрешено только при высокой уверенности:

- документированный structured event;
- известный exit code плюс сигнатура;
- version-scoped terminal pattern;
- повторная согласованная диагностика.

При средней уверенности приложение предлагает переключение. При низкой — показывает ошибку и сохраняет сессию. Обычный timeout, потеря сети и долгий build не считаются лимитом.

### 8.9. Расширяемость

Адаптеры первой стороны компилируются вместе с приложением. Динамические сторонние plugins не входят в MVP, потому что это увеличивает поверхность выполнения произвольного кода. Позже возможен declarative adapter manifest для простых CLI и подписанные adapter bundles для сложных интеграций.

## 9. Архитектура PTY

### 9.1. Почему PTY обязателен

Официальные coding CLI могут:

- менять поведение, когда stdout не TTY;
- использовать ANSI, alternate screen и cursor movement;
- запрашивать ввод без newline;
- реагировать на размер терминала;
- запускать дочерние интерактивные команды.

Обычных Pipe недостаточно.

### 9.2. PTY ownership

PTY master принадлежит RunnerService. Child получает slave как stdin/stdout/stderr и становится владельцем controlling terminal. Runner не смешивает доменную логику с байтами терминала.

~~~mermaid
flowchart LR
    APP["RunnerClient"]
    IPC["Versioned IPC"]
    SM["SessionManager actor"]
    MASTER["PTY master fd"]
    SLAVE["PTY slave fd"]
    PG["CLI process group"]
    DEC["Decoder and VT parser"]

    APP <--> IPC
    IPC <--> SM
    SM <--> MASTER
    MASTER <--> SLAVE
    SLAVE <--> PG
    SM --> DEC
    DEC --> IPC
~~~

### 9.3. Low-level implementation

Рекомендуется небольшой C system shim для:

- <code>openpty</code> или тщательно проверенного spawn path;
- termios;
- <code>TIOCSWINSZ</code>;
- session/process group setup;
- signal forwarding;
- nonblocking fd configuration.

Не следует размещать небезопасную fork-логику в многопоточном UI-процессе. Отдельный Runner уменьшает риск. Точный выбор между <code>forkpty</code> и <code>openpty + spawn</code> должен быть подтверждён прототипом на поддерживаемых macOS и выбран с учётом поведения после fork.

### 9.4. SessionManager

SessionManager actor хранит:

- sessionID;
- master fd;
- child PID;
- process group ID;
- lifecycle;
- pending writes;
- last output time;
- terminal size;
- adapter correlation metadata;
- bounded ring buffers.

На один fd — один сериализованный reader. UI никогда не пишет напрямую.

### 9.5. Backpressure

Output может быть огромным. Правила:

- bounded in-memory scrollback;
- batching событий UI по времени/размеру;
- отдельный bounded semantic stream;
- опциональный compressed raw log;
- dropped-byte counters;
- UI terminal обновляется с ограниченной частотой;
- domain events не создаются на каждый byte chunk.

При переполнении визуального buffer процесс не блокируется; сохраняется marker об усечении.

### 9.6. Ввод

Типы ввода:

- raw user keystrokes из console;
- orchestrator prompt;
- structured answer на approval;
- control sequence;
- paste с bracketed paste при поддержке;
- EOF.

Все автоматические inputs записываются как audit event. Secrets, введённые пользователем, не должны попадать в обычный event payload.

### 9.7. Resize

Изменение размера console:

1. SwiftUI/AppKit bridge вычисляет rows/columns;
2. Runner получает resize command;
3. применяет <code>TIOCSWINSZ</code>;
4. сигнализирует process group через <code>SIGWINCH</code>, если требуется.

### 9.8. Stop semantics

Отдельные действия:

- **Pause orchestration:** не давать новых инструкций, процесс может продолжать текущую команду;
- **Interrupt:** отправить Ctrl-C/SIGINT process group;
- **Graceful stop:** adapter-specific exit, затем SIGTERM;
- **Force stop:** SIGKILL process group после предупреждения;
- **Detach UI:** не останавливать Runner.

SIGSTOP не используется как обычная pause: он может заморозить процесс с lock, сетевым соединением или дочерним процессом в неудобном состоянии.

### 9.9. Crash recovery

При восстановлении соединения App спрашивает Runner о живых sessions. Возможны состояния:

- DB и Runner согласованы — reattach;
- Runner жив, DB не знает session — quarantined orphan, показать пользователю;
- DB считает session живой, Runner её не знает — attempt lost, checkpoint and route;
- PID существует, но identity не совпадает — никогда не посылать сигнал.

PID всегда проверяется вместе с session token и process identity, чтобы не убить переиспользованный PID.

### 9.10. Terminal UI

Полноценная VT-эмуляция остаётся инфраструктурной зависимостью. Перед выбором готовой библиотеки нужен spike:

- alternate screen;
- Unicode и wide glyphs;
- mouse events;
- paste;
- resize;
- accessibility;
- performance;
- лицензия;
- отделимость PTY core от view.

Даже при использовании готового terminal view доменная логика не должна зависеть от его screen model.

## 10. Интеграция с Git

### 10.1. Git CLI как контракт

Использовать установленный <code>/usr/bin/git</code> или явно выбранный Git. Не читать внутренние файлы <code>.git</code> напрямую, если Git предоставляет plumbing/porcelain команду.

Machine-readable операции:

- status: <code>git status --porcelain=v2 -z --branch</code>;
- changed paths: NUL-delimited output;
- worktrees: <code>git worktree list --porcelain -z</code>;
- diffs: explicit refs, binary-safe capture, size limits;
- paths: <code>git rev-parse --path-format=absolute</code>.

Human-readable <code>git status</code>, <code>git diff</code> и <code>git diff --stat</code> всё равно включаются в Task Envelope для агента, но UI и core не парсят их как API.

### 10.2. RepositoryActor

На каждый Git common dir создаётся RepositoryActor:

- сериализует операции, меняющие refs/worktrees;
- допускает ограниченный параллелизм read-only commands;
- координирует app leases;
- следит за lock errors;
- выполняет debounce после filesystem events;
- не блокирует MainActor.

### 10.3. Task worktree

Default flow:

1. проверить репозиторий и текущие операции;
2. получить base revision;
3. создать task branch;
4. создать linked worktree;
5. lock worktree с task ID;
6. выдать lease;
7. запускать CLI только с cwd этого worktree.

Если пользователь сознательно выбирает existing worktree, UI показывает повышенный риск и запрещает второй writer.

### 10.4. Dirty исходный репозиторий

Приложение не stash и не commit пользовательские изменения автоматически.

Варианты:

- создать новый worktree от чистого HEAD, оставив исходную грязную директорию нетронутой;
- создать Task поверх existing dirty state после явного подтверждения;
- заблокировать запуск, если изменения должны быть включены, но их происхождение неясно.

### 10.5. Git fingerprint

Fingerprint должен связывать evidence с точным состоянием:

- HEAD OID;
- branch/ref;
- digest staged diff;
- digest unstaged diff;
- digest manifest безопасных untracked files;
- repository operation state.

Он не обязан быть Git commit ID. Нельзя хешировать только <code>git diff</code>, потому что staged и untracked данные иначе теряются.

### 10.6. Изменённые файлы

Task не хранит ручной список как истину. UI строит его из GitSnapshot:

- added, modified, deleted, renamed, copied, type changed;
- staged/unstaged;
- untracked;
- submodule state;
- binary marker;
- conflict stages.

Сохранённый список — cache конкретного checkpoint.

### 10.7. Внешние изменения

FSEvents/DispatchSource служит только триггером. После него всегда выполняется Git inspection. Если fingerprint меняется без ожидаемого orchestration command:

- событие <code>ExternalRepositoryMutationDetected</code>;
- текущая проверка становится stale;
- adapter получает обновлённый контекст только в безопасной точке;
- при конфликте Task ставится на паузу.

Определить автора каждого изменения надёжно невозможно; UI не должен притворяться, что знает, агент это или человек.

### 10.8. Merge, rebase и конфликты

Перед start/switch/checkpoint GitService определяет:

- merge in progress;
- rebase;
- cherry-pick;
- revert;
- bisect;
- unresolved index entries.

Автоматический failover разрешён, но новый агент получает явный blocker и сначала аудит. Автоматический merge конфликтующих веток не выполняется.

### 10.9. Submodules, LFS, sparse checkout

- submodule status входит в snapshot;
- worktree операции с submodules требуют отдельного compatibility test;
- LFS availability проверяется до тяжёлых checkout;
- sparse config не меняется автоматически;
- partial clone/network fetch не запускается без policy.

### 10.10. Git не должен быть испорчен приложением

Запрещены без явного действия пользователя:

- reset hard;
- clean;
- force checkout;
- force push;
- удаление dirty worktree;
- переписывание пользовательской ветки;
- изменение global Git config.

## 11. Система checkpoint

### 11.1. Назначение

Checkpoint — атомарная логическая точка, позволяющая ответить:

- какое состояние Git наблюдалось;
- какой этап считался достигнутым;
- какие проверки были актуальны;
- какой handoff действовал;
- кто и почему создал точку;
- можно ли безопасно продолжать или восстанавливать.

Checkpoint не равен commit пользователя и не обязан менять branch history.

### 11.2. Два уровня checkpoint

#### Logical checkpoint — обязательный

Содержит metadata и ссылки:

- checkpointID;
- taskID;
- sequence;
- reason;
- createdAt;
- GitSnapshotID и fingerprint;
- AttemptID;
- completed/remaining step projections;
- HandoffRevisionID;
- fresh ValidationRun IDs;
- active blockers;
- integrity status.

#### Recovery checkpoint — опциональный, но рекомендуемый

Для восстановления грязного состояния можно создать внутренний Git object без изменения пользовательских HEAD и index:

1. подготовить временный index через <code>GIT_INDEX_FILE</code>;
2. наполнить его tracked и разрешёнными non-ignored untracked файлами;
3. создать tree;
4. создать synthetic commit с parent текущего HEAD;
5. обновить локальный ref пространства Third Hand;
6. записать OID в checkpoint.

Пример namespace: <code>refs/third-hand/tasks/task-id/checkpoints/sequence</code>.

Такое решение лучше автоматических обычных commits:

- не загрязняет историю ветки;
- не меняет staging пользователя;
- позволяет восстановить полное состояние через Git objects;
- даёт content-addressed integrity.

Но у него есть риски:

- секреты в non-ignored файлах попадут в object database;
- большие файлы увеличат репозиторий;
- mirror push нестандартных refs теоретически может их отправить;
- garbage collection и cleanup требуют ясной политики.

Поэтому recovery checkpoint проходит size, ignore и secret policy. При сомнении приложение создаёт только logical checkpoint и сообщает, что грязное состояние не имеет полной recovery-копии.

### 11.3. Что не включается автоматически

- ignored files;
- credential paths;
- файлы больше configured limit;
- sockets, devices и специальные файлы;
- внешние symlink targets;
- build artifacts, исключённые policy;
- данные вне worktree.

### 11.4. Триггеры

Checkpoint создаётся:

- после завершения значимого TaskStep;
- перед переключением Agent;
- перед запрошенной пользователем остановкой;
- перед потенциально рискованной интеграцией;
- после успешной обязательной проверки;
- периодически, если есть meaningful Git change и прошёл minimum interval;
- при обнаружении вероятного лимита, если Runner ещё отвечает;
- перед завершением Task.

Не нужно создавать checkpoint на каждую строку вывода или каждый save.

### 11.5. Checkpoint saga

~~~mermaid
sequenceDiagram
    participant O as Orchestrator
    participant P as PTY/Adapter
    participant G as GitService
    participant V as ValidationService
    participant C as CheckpointService
    participant DB as EventStore

    O->>P: Request safe point and compact handoff
    P-->>O: Handoff candidate or unavailable
    O->>G: Capture snapshot A
    G-->>O: Git fingerprint A
    O->>V: Collect latest fresh evidence
    V-->>O: Validation references
    O->>C: Validate handoff and policy
    C->>G: Optional recovery ref
    G-->>C: OID or recoverable failure
    C->>G: Capture snapshot B
    G-->>C: Git fingerprint B
    C->>DB: Commit checkpoint transaction
    DB-->>O: Checkpoint committed
~~~

Если fingerprint A и B различаются во время checkpoint, saga повторяется ограниченное число раз или создаёт checkpoint с <code>unstable</code>, после чего Task приостанавливается.

### 11.6. Atomicity

SQLite transaction атомарно связывает:

- checkpoint record;
- handoff revision;
- step transitions;
- validation references;
- recovery ref OID;
- resulting domain event.

Git object/ref и DB не поддерживают общую транзакцию, поэтому применяется saga:

- ref создан, DB commit упал → recovery scan на следующем запуске предлагает adopt/delete;
- DB записан, ref отсутствует → checkpoint остаётся logical и помечается degraded;
- повтор команды использует idempotency key.

### 11.7. Retention

- logical checkpoints сохраняются до удаления Task;
- raw logs имеют time/size retention;
- recovery refs сохраняются для последних N точек и milestones;
- удаление recovery refs требует reflog/GC-aware policy;
- dirty или blocked Task никогда не очищается автоматически.

## 12. Semantic handoff

### 12.1. Принцип

Handoff — навигационная записка, а не краткое изложение чата, не доказательство корректности и не копия diff.

Он содержит только четыре раздела:

1. принятые архитектурные решения;
2. текущий прогресс;
3. известные проблемы;
4. следующий рекомендуемый шаг.

### 12.2. Строгая схема

~~~json
{
  "schemaVersion": 1,
  "decisions": [
    {
      "statement": "Краткое решение",
      "rationale": "Только если без него решение непонятно"
    }
  ],
  "progress": [
    "Завершённый или частично завершённый результат"
  ],
  "knownIssues": [
    {
      "issue": "Краткая проблема",
      "severity": "blocking|important|minor"
    }
  ],
  "nextStep": "Один конкретный рекомендуемый следующий шаг"
}
~~~

Дополнительная metadata хранится рядом, но не передаётся как текст handoff:

- revision ID;
- checkpoint ID;
- author attempt;
- createdAt;
- source: agent, user, deterministicFallback;
- validation status;
- byte/token estimate.

### 12.3. Бюджет

Рекомендуемый предел:

- до 2 KiB UTF-8;
- decisions: до 5;
- progress: до 5;
- known issues: до 5;
- nextStep: ровно один;
- без длинных code snippets;
- без полного списка файлов;
- без терминального transcript.

Если ответ больше, CheckpointService запрашивает сокращение. Если агент недоступен, используется последняя валидная ревизия плюс deterministic fallback.

### 12.4. Обновление

Предпочтительный protocol:

1. приложение просит агента закончить текущую атомарную операцию;
2. отправляет adapter-specific checkpoint request;
3. агент отвечает framed structured payload;
4. adapter извлекает payload;
5. schema validator проверяет размер и поля;
6. handoff привязывается к свежему Git fingerprint.

Terminal sentinel нельзя считать абсолютной security boundary: текст может появиться в выводе команды. Adapter принимает framed payload только в ожидаемом состоянии checkpoint handshake.

### 12.5. Fallback без агента

Если лимит наступил раньше ответа, приложение не генерирует выдуманное резюме. Оно строит минимальный fallback:

- decisions: последняя подтверждённая ревизия;
- progress: изменения TaskStep после прошлого checkpoint;
- knownIssues: текущие blockers, failed validations, unstable Git;
- nextStep: «провести аудит diff и продолжить с активного этапа».

### 12.6. Качество handoff

Handoff помечается:

- <code>agentReported</code>;
- <code>userEdited</code>;
- <code>systemDerived</code>;
- <code>stale</code>, если fingerprint изменился;
- <code>unverified</code>, если утверждения не подтверждены evidence.

Новый агент видит эти labels. Даже свежий handoff не отменяет аудит.

### 12.7. Где хранить

Default — локальная DB Third Hand. Не создавать файл в пользовательском репозитории без opt-in.

Опциональная командная политика может экспортировать handoff в репозиторий, но это уже отдельный продуктовый режим с вопросами review, merge conflicts и приватности.

## 13. Task Envelope для нового агента

### 13.1. Состав

Envelope создаётся заново при каждом Attempt:

1. исходная задача и последние пользовательские amendments;
2. acceptance criteria;
3. canonical repository/worktree path;
4. base revision, текущий HEAD и branch;
5. machine summary текущей Git operation;
6. human-readable <code>git status</code>;
7. <code>git diff</code> для unstaged;
8. staged diff отдельно;
9. <code>git diff --stat</code>;
10. untracked file manifest;
11. последние fresh build/test results;
12. последние failed/stale checks с labels;
13. текущий semantic handoff;
14. completed и remaining steps;
15. Audit Gate instructions;
16. ограничения пользователя и approval policy.

Для больших diff Envelope содержит stat, список файлов, digest и инструкцию читать diff из репозитория. Нельзя обрезать diff молча.

### 13.2. Обязательная инструкция

Смысл системной инструкции адаптера:

> Не считай существующие изменения правильными. До новых изменений изучи репозиторий, staged/unstaged/untracked состояние и diff; определи уже реализованное, незавершённое и потенциально ошибочное; оцени соответствие архитектуре и проверкам; затем выдай краткий DiffAssessment. Только после этого продолжай.

### 13.3. DiffAssessment

Новый агент должен зафиксировать:

- understoodIntent;
- implemented;
- incomplete;
- suspiciousOrIncorrect;
- architectureRisks;
- validationGaps;
- proposedNextAction;
- mayProceed: yes/no.

Это не добавляется в semantic handoff целиком. Оно хранится как audit artifact и отображается пользователю.

### 13.4. Audit Gate enforcement

Уровни:

1. **Strong:** документированный CLI read-only/plan mode.
2. **Moderate:** отдельная read-only audit worktree/snapshot, затем новый execution launch.
3. **Observed:** actual worktree, prompt policy и Git mutation monitor.

Third Hand показывает фактический уровень, не обещая защиты, которой нет.

## 14. Алгоритм переключения между агентами

### 14.1. Причины

- usage/quota limit;
- authentication expired;
- CLI crash;
- protocol incompatibility;
- repeated transient failure;
- user-requested switch;
- agent unavailable after sleep/restart;
- policy preference;
- quality escalation после failed validation.

Не каждая причина допускает автоматический switch. Например, неоднозначное подтверждение или Git conflict требует пользователя.

### 14.2. State machine Attempt

~~~mermaid
stateDiagram-v2
    [*] --> Starting
    Starting --> Auditing
    Auditing --> Active
    Active --> AwaitingApproval
    AwaitingApproval --> Active
    Active --> Checkpointing
    Checkpointing --> Active
    Active --> QuotaBlocked
    Active --> AuthBlocked
    Active --> Failed
    Active --> CompletedClaimed
    Active --> Stopping
    Auditing --> Failed
    QuotaBlocked --> HandedOff
    AuthBlocked --> HandedOff
    Failed --> HandedOff
    CompletedClaimed --> Verifying
    Verifying --> Succeeded
    Verifying --> Active
    Stopping --> Stopped
~~~

### 14.3. Failover saga

1. **Detect.** Adapter создаёт observation с evidence/confidence.
2. **Classify.** Policy решает automatic, suggested или blocked.
3. **Fence.** Orchestrator запрещает новые automatic inputs старой session.
4. **Quiesce.** Попытаться дождаться safe point; при лимите CLI часто уже idle.
5. **Checkpoint.** Снять Git snapshot, сохранить fallback handoff и recovery ref по policy.
6. **Stop/retain.** Завершить или оставить старую session read-only по user policy.
7. **Release attempt, not worktree.** Writer lease остаётся у Task, а не у агента.
8. **Route.** Построить candidate set и выбрать нового агента.
9. **Build envelope.** Сформировать контекст из актуального Git, не из старого transcript.
10. **Start audit attempt.** Запустить новую PTY.
11. **Audit.** Получить DiffAssessment.
12. **Reconcile.** Снова снять Git snapshot; при расхождении повторить аудит.
13. **Authorize execution.** Перевести Attempt в active.
14. **Observe first mutation.** Создать early checkpoint после первого значимого изменения.
15. **Complete switch.** Записать <code>SwitchCompleted</code>.

### 14.4. Routing candidate filter

Кандидат исключается, если:

- executable отсутствует или изменился;
- authRequired;
- active cooldown;
- версия не поддерживается адаптером;
- нет обязательной capability;
- достигнут user concurrency limit;
- provider запрещён для этой Task;
- агент уже несколько раз дал ту же классифицированную ошибку;
- architecture/task policy требует иной роли.

### 14.5. Scoring

Пример score:

~~~text
score =
  userPreference
  + taskCapabilityFit
  + historicalSuccessForRepoType
  + warmAvailability
  - currentLoad
  - recentFailurePenalty
  - switchBackPenalty
  - estimatedCooldownPenalty
~~~

Стоимость и качество можно добавить только из явных пользовательских настроек. Приложение не должно выдумывать тарифы провайдера.

### 14.6. Anti-thrashing

- exponential cooldown для одинаковой причины;
- не возвращаться немедленно к только что упавшему агенту;
- ограничение switches за окно времени;
- circuit breaker на installation;
- один recovery retry для transient startup;
- после N неудач Task → blocked и уведомление.

### 14.7. Нет доступных агентов

Task остаётся восстановимой:

- state <code>blocked.noEligibleAgent</code>;
- worktree lock/lease сохранён;
- checkpoint создан;
- пользователь получает notification;
- router может проснуться по cooldown timer или изменению installation health.

### 14.8. Возврат старого агента

Старый агент не возобновляет запись автоматически, даже если лимит сбросился. Он становится candidate для следующего routing decision. Одновременное возобновление старой PTY нарушило бы single-writer invariant.

## 15. Параллельность и несколько репозиториев

### 15.1. Уровни concurrency

| Сценарий | Разрешение |
| --- | --- |
| Разные repos, разные agents | да |
| Один repo, разные task worktrees | да |
| Один Task, implementer + read-only reviewer | да |
| Один Task, два writer в одном worktree | нет |
| Один Task, два writer в отдельных subtask worktrees | только с integration plan |
| Validation параллельно с записью | можно, но результат станет stale при изменении fingerprint |

### 15.2. ResourceScheduler

Ограничивает:

- число active CLI;
- число тяжёлых builds;
- CPU-intensive validations;
- memory pressure;
- output bandwidth;
- количество background tasks на батарее.

Scheduler учитывает thermal state, low power mode и пользовательские лимиты, но не прерывает процесс без policy.

### 15.3. Subtask decomposition

Продвинутый режим:

1. родительская Task фиксирует integration base;
2. создаются независимые Subtask и worktree;
3. каждый writer работает изолированно;
4. результаты проверяются;
5. отдельный Integrator Attempt анализирует ветки;
6. merge/cherry-pick выполняется с preview и approval;
7. родительский checkpoint фиксирует интеграцию.

Это лучше совместной записи нескольких агентов в одну директорию.

## 16. Ошибки и нестандартные ситуации

### 16.1. Таксономия

Каждая ошибка имеет:

- domain;
- code;
- severity;
- recoverability;
- retry policy;
- user action;
- underlying evidence;
- redacted diagnostic context.

Категории:

- agent;
- PTY/process;
- Git/worktree;
- validation;
- persistence;
- filesystem/permissions;
- policy/approval;
- system resource;
- adapter protocol.

### 16.2. CLI не найден

- installation становится unavailable;
- попытка не запускается;
- UI показывает сохранённый путь и шаг выбора нового executable;
- auto-route ищет другой eligible installation;
- никакой автоматической установки CLI без запроса пользователя.

### 16.3. Auth expired

- отличать от quota;
- сохранить checkpoint;
- автоматически переключать только если policy это разрешает;
- дать действие «Открыть auth session»;
- не показывать credential content в notification/log.

### 16.4. Неоднозначный prompt

Если adapter не уверен, что CLI ждёт подтверждение:

- не отправлять <code>y</code> автоматически;
- создать attention item с terminal excerpt;
- оставить PTY живой;
- дать открыть console;
- после timeout не считать Task failed, пока process жив.

### 16.5. Runner crash

- XPC connection invalidation;
- Attempt → unknown;
- проверить Git;
- попытаться восстановить список sessions;
- если session потеряна — checkpoint degraded и route;
- crash loop открывает circuit breaker;
- UI остаётся работоспособным.

### 16.6. App crash или перезапуск

Startup reconciler:

1. открыть DB и применить миграции;
2. проверить незавершённые sagas;
3. запросить Runner sessions;
4. проверить worktree paths и leases;
5. снять Git snapshots;
6. сопоставить sessions, attempts и PIDs;
7. пометить stale validations;
8. восстановить notifications/attention;
9. не запускать новые agents до завершения reconciliation.

### 16.7. Mac sleep/wake

- записать sleep marker;
- не считать отсутствие output timeout во время sleep;
- после wake проверить child processes, network, mounts и Git;
- resync terminal state, если возможно;
- builds, завершившиеся во сне, всё равно валидировать по exit и fingerprint.

### 16.8. Репозиторий на внешнем диске

- Repository availability → unmounted;
- не удалять linked worktree metadata;
- Git worktree lock особенно важен;
- процессы получают graceful interrupt, если cwd исчез;
- после возврата диска выполнить repair/inspection;
- не route в новый path без подтверждения идентичности repo.

### 16.9. Git index lock

- проверить возраст и owning process, насколько возможно;
- повторить read с backoff;
- не удалять <code>index.lock</code> автоматически;
- показать конфликтующий процесс;
- Task → blocked при длительной блокировке.

### 16.10. Конфликт или незавершённый rebase

- snapshot явно показывает operation state;
- новый агент получает его в Envelope;
- auto-checkpoint возможен;
- auto-completion запрещён;
- destructive abort/continue требует user policy/approval.

### 16.11. Огромный diff

- не грузить весь diff в память;
- stream в файл;
- хранить stat и digest;
- ограничить UI rendering;
- Envelope сообщает truncation и команды для локального чтения;
- binary blobs не вставляются в prompt.

### 16.12. Untracked и ignored

Untracked входит в manifest и, по policy, recovery checkpoint. Ignored не считается частью результата по умолчанию. Если build зависит от ignored generated file, ValidationRecipe должен явно это декларировать.

### 16.13. Disk full

- прекратить raw logging;
- checkpoint отмечается failed/degraded;
- не объявлять switch безопасным без сохранённой точки;
- сохранить процессы, если это безопаснее остановки;
- notification с точным требуемым действием;
- cleanup только для разрешённых retention artifacts.

### 16.14. Output flood или malformed ANSI

- bounded buffers;
- parser isolation;
- raw byte counters;
- замена invalid UTF-8 без падения;
- circuit breaker UI rendering;
- CLI продолжает работать;
- semantic observation может перейти в degraded.

### 16.15. Build/test завис

- recipe timeout;
- сначала interrupt, затем terminate process group;
- outcome timedOut;
- partial log сохранён;
- агент не переключается автоматически, если CLI не причина зависания;
- пользователь может увеличить timeout.

### 16.16. Flaky tests

- результаты неизменяемы;
- повтор не стирает первый failure;
- policy может требовать K успехов;
- UI показывает последовательность;
- router не интерпретирует один flaky failure как дефект агента без правил.

### 16.17. Agent сообщил неверный успех

- completion claim запускает verification gate;
- failed checks возвращают Task в executing или blocked;
- handoff получает known issue;
- можно route reviewer/другого агента;
- история claim остаётся в events.

### 16.18. Пользователь изменил файлы во время работы

- обнаружить fingerprint drift;
- пометить evidence stale;
- не откатывать;
- уведомить активного агента на safe point;
- при затронутых тех же файлах pause и user reconciliation.

### 16.19. Adapter сломался после обновления CLI

- version re-probe;
- adapter compatibility mismatch;
- disable high-risk automation;
- сохранить raw console mode;
- предложить pin executable или обновить adapter;
- не применять старые regex без version boundary.

### 16.20. База повреждена

- SQLite integrity check;
- backup перед migration;
- event log и projections разделены логически;
- rebuild projections из events;
- экспорт diagnostic bundle с redaction;
- Git/worktrees не удалять;
- Task можно повторно импортировать из repository state, потеряв только orchestration history.

### 16.21. Частичная saga переключения

Каждый шаг имеет idempotency key и persisted phase. Recovery продолжает с последней подтверждённой фазы, а не запускает второго writer.

## 17. Безопасность, приватность и trust

### 17.1. Честная граница безопасности

CLI-агент с правами пользователя может изменять доступные ему файлы и запускать процессы. PTY-оркестратор сам по себе не является sandbox. Third Hand может дать approvals, worktrees, checkpoints и аудит, но не может гарантировать отсутствие вредоносных действий.

Для строгой изоляции потребуется отдельный режим контейнера/VM или документированный sandbox конкретного CLI. Это отдельный проектный трек.

### 17.2. Repository trust

До первого запуска агента в repo:

- пользователь явно добавляет каталог;
- UI сообщает, что repo и его инструкции могут влиять на агента;
- project-local Third Hand config не исполняется автоматически;
- build/test recipes из repo требуют trust;
- смена identity repo может сбросить trust.

### 17.3. Command construction

- executable и argv раздельно;
- cwd — URL, не shell fragment;
- environment values не интерполируются в команды;
- custom shell recipe визуально отличается и требует trust;
- display command redacts secrets;
- абсолютный executable revalidated.

### 17.4. Environment

Окружение строится по policy:

- минимальные системные переменные;
- user-approved PATH;
- HOME нужен официальным CLI для собственной подписки;
- denylist для очевидных secrets в logs;
- explicit per-repo additions;
- terminal type;
- Third Hand correlation vars без чувствительных данных.

Нельзя обещать полную redaction произвольного terminal output. Поэтому raw transcript retention выключается или ограничивается по умолчанию.

### 17.5. IPC

- versioned Codable/XPC messages;
- проверка peer identity/signing;
- size limits;
- session capability token;
- никакой передачи произвольных selector names;
- helper принимает только узкий набор команд;
- никакого privileged helper в MVP.

### 17.6. Filesystem access

Если появится sandbox build:

- пользователь выбирает repo через NSOpenPanel;
- persistent security-scoped bookmark;
- access scope удерживается только необходимое время;
- bookmark передаётся Runner корректным способом;
- stale bookmarks обновляются;
- helper отдельно проверяется на доступ к CLI config/toolchains.

### 17.7. Логи

- structured events — по умолчанию;
- raw PTY logs — opt-in или короткий retention;
- automatic secret pattern redaction как best effort;
- diagnostic export показывает preview;
- remote URLs очищаются;
- auth prompts имеют privacy marker;
- приложение не синхронизирует логи в облако в MVP.

### 17.8. Destructive actions

Third Hand не может перехватить каждый syscall дочернего CLI. Используются:

- официальные approval/sandbox modes CLI, если они документированы;
- app-level approvals для собственных Git/validation actions;
- worktree isolation;
- recovery checkpoints;
- запрет автоматического force push/reset/clean;
- ясный risk indicator.

## 18. Validation architecture

### 18.1. ValidationRecipe

Поля:

- id и revision;
- name;
- kind;
- executable;
- argv;
- cwd relative path;
- environment policy;
- timeout;
- success exit codes;
- parser;
- resource class;
- trust origin;
- requiredForCompletion.

### 18.2. Discovery

Источники:

- пользовательская настройка Task;
- локальная настройка Repository в DB;
- opt-in declarative file в repo;
- suggested recipes от adapter/agent, требующие подтверждения.

Приложение не должно угадывать и запускать произвольный script только по имени.

### 18.3. Execution

Validation process не обязан использовать PTY. По умолчанию применяется pipe-based Process Runner с отдельной process group; PTY включается только для tools, которым он действительно нужен.

### 18.4. Evidence freshness

Результат current только если:

- fingerprint before == fingerprint after;
- он равен текущему Task fingerprint;
- recipe revision не изменилась;
- необходимое окружение не помечено изменившимся.

### 18.5. Parser

Парсеры — отдельные плагины первой стороны:

- generic exit code;
- XCTest;
- Swift Testing;
- SwiftPM;
- Xcode build diagnostics;
- JUnit;
- generic JSON report.

Parser failure не меняет exit code, но outcome может быть <code>passedWithUnparsedOutput</code>.

## 19. UX и информационная архитектура

### 19.1. Главный экран

<code>NavigationSplitView</code>:

#### Sidebar

- All Tasks;
- Running;
- Needs Attention;
- Blocked;
- Completed;
- repositories;
- компактные native rows: статус, title, agent.

#### Detail

- Task title и original request;
- state banner;
- plan/steps;
- current progress;
- changed files и diff summary;
- build/test evidence;
- latest handoff;
- activity timeline;
- primary actions.

#### Inspector

- active agent/attempt;
- worktree/branch/HEAD;
- routing explanation;
- resource status;
- checkpoint metadata;
- console toggle.

### 19.2. Agent Console

Console:

- раскрывается по запросу;
- имеет raw/screen режимы;
- показывает, когда ввод идёт напрямую в CLI;
- визуально отделяет user input, app input и agent output;
- предупреждает, что transcript не является Task history;
- не занимает основную навигацию.

### 19.3. Approvals

Approval card показывает:

- человеческое описание;
- точный scope;
- risk level;
- запрашивающего агента;
- repository/worktree;
- relevant terminal excerpt;
- Allow once, Deny, Always allow для узко определённой безопасной категории.

Global «always yes» отсутствует.

### 19.4. Notifications

Категории:

- approval required;
- task blocked;
- task completed;
- validation failed.

Основные actions:

- Open Task;
- Pause Task для безопасных случаев;
- Dismiss.

### 19.5. Desktop conventions

- Commands menu и keyboard shortcuts;
- context menus;
- toolbar actions;
- searchable tasks;
- multiple windows для отдельных Task при необходимости;
- Settings как отдельная scene;
- state per window через scene-scoped selection;
- system materials и semantic colors;
- accessibility labels и VoiceOver для статусов.

### 19.6. Menu bar

MenuBarExtra опционален и показывает:

- число running;
- число needs attention;
- краткие Task labels;
- Open Third Hand;
- Pause All;
- Quit с предупреждением об active tasks.

Длинные prompts не отображаются в меню.

## 20. Persistence и проекции

### 20.1. Почему SQLite

Требуются:

- транзакции;
- append-only events;
- deterministic migrations;
- выборки timeline;
- связи evidence/checkpoints;
- crash recovery;
- возможность пересобрать projections.

SwiftData удобен для простого UI CRUD, но здесь важнее явный контроль схемы, транзакций и журнала. Поэтому рекомендуется persistence protocol с SQLite implementation. Конкретную библиотеку нужно утвердить ADR после prototype.

### 20.2. Таблицы

Минимум:

- repositories;
- worktrees;
- tasks;
- task_requirement_revisions;
- task_steps;
- agent_installations;
- agent_capability_snapshots;
- attempts;
- pty_sessions;
- git_snapshots;
- checkpoints;
- handoff_revisions;
- validation_recipes;
- validation_runs;
- approval_requests;
- routing_decisions;
- worktree_leases;
- events;
- artifacts;
- sagas;

### 20.3. Single writer

Только Persistence actor приложения пишет DB. Runner передаёт события по IPC и не открывает базу. Это уменьшает multi-process locking и упрощает миграции.

### 20.4. Проекции

- TaskListProjection;
- TaskDetailProjection;
- AgentAvailabilityProjection;
- AttentionProjection;
- RepositoryHealthProjection;
- ActivityTimelineProjection.

Если projection повреждена, она пересобирается из events и immutable records.

### 20.5. Artifacts

В Application Support:

~~~text
Third Hand/
├── Database/
├── Logs/
│   ├── PTY/
│   └── Validation/
├── Artifacts/
│   ├── Diffs/
│   ├── Diagnostics/
│   └── Exports/
├── Worktrees/
└── Backups/
~~~

Каждый artifact имеет checksum, size, media type, sensitivity и retention class.

## 21. Предлагаемая структура Xcode-проекта

~~~text
ThirdHand/
├── App/
│   ├── ThirdHandApp.swift
│   ├── AppDelegate.swift
│   ├── AppCommands.swift
│   └── DependencyContainer.swift
├── Features/
│   ├── TaskList/
│   ├── TaskDetail/
│   ├── TaskCreation/
│   ├── AgentMonitor/
│   ├── ApprovalCenter/
│   ├── RepositoryLibrary/
│   ├── CheckpointHistory/
│   ├── ValidationResults/
│   ├── AgentConsole/
│   └── Settings/
├── Domain/
│   ├── Models/
│   ├── StateMachines/
│   ├── Events/
│   ├── Commands/
│   ├── Policies/
│   └── Errors/
├── Application/
│   ├── TaskOrchestrator/
│   ├── UseCases/
│   ├── Sagas/
│   ├── Recovery/
│   └── Projections/
├── AgentKit/
│   ├── AgentAdapter.swift
│   ├── AgentRegistry.swift
│   ├── CapabilityModel.swift
│   ├── Routing/
│   ├── Codex/
│   ├── ClaudeCode/
│   ├── Antigravity/
│   └── Testing/
├── RepositoryKit/
│   ├── GitService.swift
│   ├── RepositoryActor.swift
│   ├── WorktreeManager.swift
│   ├── Snapshot/
│   ├── Checkpoint/
│   └── Validation/
├── RunnerClient/
│   ├── RunnerProtocol.swift
│   ├── RunnerConnection.swift
│   └── SessionClient.swift
├── Persistence/
│   ├── EventStore.swift
│   ├── Database/
│   ├── Migrations/
│   ├── Repositories/
│   └── ArtifactStore/
├── Platform/
│   ├── Notifications/
│   ├── FileAccess/
│   ├── PowerState/
│   ├── AppKitBridges/
│   └── Logging/
├── Shared/
│   ├── Identifiers/
│   ├── Clocks/
│   ├── Collections/
│   └── Redaction/
├── ThirdHandRunner/
│   ├── main.swift
│   ├── IPC/
│   ├── SessionManager.swift
│   ├── PTY/
│   ├── ProcessControl/
│   └── TerminalPipeline/
├── SystemShim/
│   ├── include/
│   └── PTYShim.c
├── ThirdHandTests/
│   ├── Domain/
│   ├── Application/
│   ├── AgentAdapters/
│   ├── RepositoryKit/
│   ├── Persistence/
│   └── Fixtures/
├── ThirdHandIntegrationTests/
│   ├── FakeCLI/
│   ├── PTY/
│   ├── GitRepositories/
│   └── Recovery/
└── ThirdHandUITests/
~~~

### 21.1. Package boundaries

Рекомендуется начать с одного Xcode workspace и нескольких internal Swift packages:

- ThirdHandDomain;
- ThirdHandAgentKit;
- ThirdHandRepositoryKit;
- ThirdHandRunnerProtocol;
- ThirdHandPersistence.

Не дробить каждый feature в package. Граница нужна там, где есть отдельный процесс, platform-independent тесты или строгая зависимость.

### 21.2. Dependency direction

~~~text
Features → Application → Domain
Application → AgentKit interfaces
Application → RepositoryKit interfaces
Infrastructure implements Domain/Application ports
RunnerClient → RunnerProtocol
ThirdHandRunner → RunnerProtocol + SystemShim
Domain → no SwiftUI, no AppKit, no SQL, no CLI-specific code
~~~

## 22. Последовательность реализации

### Phase 0. Риск-прототипы и ADR

Цель: закрыть неизвестные до большого UI.

Spikes:

1. PTY: два fake CLI, resize, ANSI, prompt, child process, process-group stop.
2. XPC: reconnect, Runner crash, large output.
3. Git worktree: dirty base, linked worktree, submodule, external volume.
4. Synthetic recovery ref с временным index.
5. Один реальный официальный CLI без hardcoded private protocol.
6. Sandbox feasibility против Developer ID non-sandboxed build.
7. Terminal view library evaluation.

Exit criteria:

- записаны ADR;
- PTY не блокирует UI;
- process tree корректно останавливается;
- Git checkpoint не меняет branch/index;
- понятна distribution model.

### Phase 1. Domain core и persistence

Реализовать:

- IDs и модели;
- Task/Attempt state machines;
- commands/events;
- SQLite schema;
- projections;
- migration/backup;
- FakeClock и deterministic tests.

Exit criteria:

- Task lifecycle полностью тестируется без UI и CLI;
- crash между фазами saga восстанавливается;
- projections rebuild.

### Phase 2. Нативный Task-centered UI

Реализовать:

- main WindowGroup;
- repository sidebar;
- Task creation/detail;
- steps;
- inspector;
- Settings;
- mock activity/evidence.

Exit criteria:

- UX не требует terminal;
- клавиатура, menus, VoiceOver basics;
- несколько окон не смешивают selection.

### Phase 3. Runner и PTY

Реализовать:

- RunnerProtocol;
- XPC service;
- PTY system shim;
- SessionManager;
- terminal pipeline;
- collapsible console;
- FakeCLI integration suite.

Exit criteria:

- interactive input;
- resize;
- graceful/force stop;
- output flood;
- reconnect;
- no MainActor I/O.

### Phase 4. Git и worktree

Реализовать:

- repository inspection;
- porcelain parsers;
- RepositoryActor;
- WorktreeManager;
- lease;
- fingerprints;
- file change UI;
- external mutation detection.

Exit criteria:

- single-writer invariant;
- dirty repo не повреждается;
- paths с Unicode/newline корректно обрабатываются;
- external drive recovery.

### Phase 5. Checkpoint, handoff и validation

Реализовать:

- logical checkpoint;
- handoff schema/validator;
- fallback handoff;
- recovery ref behind feature flag;
- ValidationRecipe/Run;
- freshness model;
- checkpoint UI.

Exit criteria:

- Task восстанавливается без transcript;
- stale test никогда не показывается current;
- checkpoint failure не теряет repo.

### Phase 6. Первый AgentAdapter

Начать с одного CLI, лучше всего документированного и доступного в тестовой среде.

Реализовать:

- installation discovery;
- probe;
- launch spec;
- audit envelope;
- conservative observations;
- approval path;
- quota fixtures;
- adapter contract tests.

Exit criteria:

- реальная Task от запуска до verified completion;
- version mismatch безопасно деградирует;
- auth и quota различаются.

### Phase 7. Failover между двумя агентами

Реализовать:

- AgentRouter;
- cooldown/circuit breaker;
- switch saga;
- Audit Gate;
- DiffAssessment;
- notifications;
- recovery после crash в каждой фазе.

Exit criteria:

- тестовая Task продолжена вторым fake/real agent без transcript;
- новый agent не получает execution state до audit;
- отсутствует double writer.

### Phase 8. Параллельность

Реализовать:

- ResourceScheduler;
- multi-repo;
- multi-worktree;
- background behavior;
- Agent Monitor;
- reviewer role;
- integration flow prototype.

Exit criteria:

- несколько Tasks не блокируют UI;
- нагрузка ограничена;
- один repo корректно сериализует ref operations.

### Phase 9. Дополнительные адаптеры

Для каждого:

- public behavior research;
- version matrix;
- fixtures;
- launch and approval;
- quota/auth classification;
- degradation strategy.

Не копировать regex одного CLI в другой.

### Phase 10. Hardening и release

- logging/privacy audit;
- notarization;
- hardened runtime;
- updater strategy;
- database migration rehearsal;
- crash reporting opt-in;
- accessibility;
- localization;
- performance/energy;
- compatibility matrix;
- threat model;
- beta feedback.

## 23. Стратегия тестирования

### 23.1. FakeCLI — обязательный test asset

Маленький executable с сценариями:

- normal completion;
- approval prompt;
- quota message;
- auth error;
- network retry;
- ANSI/TUI;
- huge output;
- malformed UTF-8;
- child process;
- ignore SIGINT;
- delayed output;
- checkpoint response;
- crash.

Так можно воспроизводимо тестировать PTY и adapters без расхода подписок.

### 23.2. Domain tests

- каждый допустимый/недопустимый transition;
- idempotency;
- routing score;
- cooldown;
- stale validation;
- handoff size/schema;
- saga recovery.

### 23.3. Git fixture matrix

- clean;
- staged;
- unstaged;
- untracked;
- rename;
- binary;
- conflicts;
- merge/rebase;
- submodule;
- LFS pointer;
- worktree;
- Unicode and whitespace paths;
- external mutation;
- lock file;
- detached HEAD.

### 23.4. Integration tests

- App ↔ Runner reconnect;
- kill Runner;
- kill UI process;
- sleep/wake simulation where possible;
- disk unavailable;
- DB write failure;
- checkpoint ref/DB split-brain;
- agent switch at every saga phase.

### 23.5. UI tests

- create/start/pause/switch;
- approval notification to Task;
- multiwindow selection;
- Needs Attention filter;
- no-terminal happy path;
- accessibility traversal.

## 24. Наблюдаемость

### 24.1. Structured logging

Использовать Apple unified logging с категориями:

- orchestration;
- runner;
- pty;
- git;
- routing;
- adapter;
- validation;
- persistence;
- privacy.

Sensitive значения помечаются private. Raw prompts/diffs не пишутся в system log.

### 24.2. Metrics

Локальные, opt-in для отправки:

- Task completion duration;
- switches per Task;
- checkpoint duration/failure;
- Runner crash count;
- output dropped;
- validation freshness invalidations;
- adapter unknown-pattern rate;
- time awaiting user.

### 24.3. Diagnostic bundle

Содержит:

- app/build versions;
- adapter/version matrix;
- redacted events;
- crash logs;
- Git summaries без diff content по умолчанию;
- user-selected logs;
- integrity results.

Перед экспортом пользователь видит состав.

## 25. Потенциальные проблемы и решения

| Проблема | Риск | Решение |
| --- | --- | --- |
| CLI output меняется | ложный quota/approval | versioned adapters, structured mode, confidence, safe degradation |
| Несколько writers | повреждение/перетирание | worktree per Task, lease, RepositoryActor |
| Агент ошибочно объявляет успех | незавершённый код | verification gate и fresh evidence |
| Handoff становится длинным чатом | дорогой и шумный switch | строгая 4-полевая схема и лимит |
| Handoff врёт или устарел | новый агент наследует ошибку | Git anchor, stale label, mandatory audit |
| Git не содержит untracked content | неполное восстановление | manifest + policy-controlled synthetic recovery ref |
| Synthetic ref сохраняет secret | утечка | ignore/size/secret policy, opt-out, visible warning |
| App Sandbox мешает CLI | CLI не работает как у пользователя | Developer ID non-sandboxed MVP; sandbox feasibility отдельно |
| GUI PATH отличается от shell | executable не найден | Environment Resolver и сохранённый absolute path |
| Закрытие UI рвёт Task | потеря continuity | Runner process, background app lifecycle, persisted reconciliation |
| XPC service перезапущен | потеря PTY | checkpoint, query sessions, route; persistent runner later |
| PTY output слишком большой | memory/UI freeze | bounded buffers, batching, compressed retention |
| Regex принял текст repo за prompt | опасный auto-input | expected-state framing, confidence, no dangerous auto-approve |
| Build result устарел | ложный green state | fingerprint before/after |
| Пользователь меняет repo | race | mutation detection, stale evidence, pause on overlap |
| Repo перемещён/диск отключён | broken worktree | bookmarks/identity, Git worktree lock, repair flow |
| Git операция уже идёт | конфликт | explicit operation state, block destructive automation |
| Agent process порождает детей | orphan processes | controlling session/process group, identity-checked signaling |
| SIGKILL оставил lock | repo blocked | graceful escalation, no automatic lock deletion |
| Неясно, исчерпан ли лимит | бесконечные switches | confidence thresholds, cooldown, user decision |
| Нет агентов | Task зависла | durable blocked state, notification, cooldown wake |
| DB и Git ref разошлись | неполный checkpoint | idempotent saga и startup reconciliation |
| Raw logs содержат секреты | privacy incident | minimal retention, best-effort redaction, preview export |
| Repo instructions prompt-inject agent | нежелательные действия | trust warning, CLI sandbox/approval, worktree recovery; честно не считать это полной защитой |
| Авто-route выбирает «не того» | потеря контроля | explainable decision, pin/preference, manual override |
| API конкретного CLI исчез | интеграция ломается | только public CLI surface, adapter capability probe |

## 26. Решения, которые лучше исходной формулировки

### 26.1. Git + orchestration journal вместо буквального «только Git»

Git остаётся истиной результата, но event journal нужен для атомарности и восстановления процессов. Это не ослабляет принцип, а делает его реализуемым.

### 26.2. Worktree per writable Task

Простая работа нескольких PTY в одном repo опасна. Worktree делает границу физической и понятной пользователю.

### 26.3. Validation вне agent transcript

Последние результаты build/test должны исходить из управляемых recipes, а не из пересказа агента. Иначе handoff передаст недостоверное «всё зелёное».

### 26.4. Audit Gate как отдельная стадия

Одной фразы в prompt недостаточно. Отдельное состояние, artifact и проверка отсутствия ранних изменений делают требование наблюдаемым и тестируемым.

### 26.5. Logical checkpoint + optional Git recovery ref

Обычные auto-commits загрязняют историю, а одна DB не сохраняет dirty content. Synthetic local ref с временным index даёт восстановление без изменения ветки, но включается только при безопасной policy.

### 26.6. Capability negotiation

Не строить архитектуру вокруг сегодняшних флагов Codex/Claude/Antigravity. Возможности определяются probe и versioned adapter, поэтому будущий CLI не ломает domain.

### 26.7. Runner process

PTY и process control не должны жить в SwiftUI lifecycle. Отдельный Runner повышает стабильность и позволяет развить фоновое выполнение без переписывания core.

### 26.8. Conservative automation

Автоматически переключать при высокой уверенности, но не автоматически подтверждать опасные действия и не интерпретировать любой timeout как quota. Continuity не должна создавать неконтролируемую активность.

## 27. Открытые вопросы для ADR

1. Минимальная поддерживаемая версия macOS.
2. XPC service достаточно или нужен persistent background agent уже в v1.
3. Конкретная SQLite library.
4. Конкретный terminal emulator component.
5. Default location managed worktrees.
6. Recovery refs включены по умолчанию или opt-in.
7. Политика хранения raw PTY logs.
8. Формат repository-local declarative config.
9. Какие validations обязательны для <code>verified completion</code>.
10. Какие CLI дают документированный read-only Audit Gate.
11. Нужен ли режим reviewer до multi-writer subtasks.
12. Как обрабатывать repos, где пользователь требует работу прямо в main worktree.
13. Поддерживать ли продолжение после полного Quit или только после закрытия окна.
14. Updater и release channel.
15. Нужно ли шифровать локальные artifacts дополнительно к FileVault.

## 28. Критерии архитектурной готовности v1

V1 готова к beta, если:

1. Task переживает смену двух агентов без передачи transcript.
2. Новый агент всегда создаёт DiffAssessment до execution.
3. Ни один test не показывает current после изменения fingerprint.
4. Один worktree не получает двух writer leases.
5. App/Runner crash не приводит к автоматическому destructive Git action.
6. Dirty state имеет явный recovery status.
7. Quota/auth/network классифицируются раздельно.
8. UI позволяет выполнить happy path без открытия console.
9. Все approvals имеют контекст и аудит.
10. CLI update безопасно переводит adapter в degraded mode.
11. Несколько repos работают параллельно без shared-state races.
12. Пользователь может экспортировать диагностический bundle без скрытой отправки данных.

## 29. Рекомендуемый первый вертикальный срез

Не начинать сразу с трёх CLI и сложного dashboard. Первый end-to-end slice:

1. создать Task;
2. выбрать clean Git repo;
3. создать managed worktree;
4. запустить FakeCLI через PTY;
5. увидеть Task progress без terminal;
6. получить approval;
7. изменить fixture repo;
8. создать checkpoint и handoff;
9. симулировать quota;
10. переключить на второй FakeCLI;
11. получить DiffAssessment;
12. продолжить;
13. запустить deterministic test recipe;
14. завершить Task как verified.

После этого заменить FakeCLI одним реальным адаптером. Такой порядок проверяет уникальную ценность Third Hand раньше визуальной полировки и широкого набора интеграций.

## 30. Источники и платформенные основания

- Apple: [openpty, login_tty и forkpty](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/openpty.3.html).
- Apple: [Creating XPC services](https://developer.apple.com/documentation/xpc/creating-xpc-services).
- Apple: [Foundation Process](https://developer.apple.com/documentation/foundation/process).
- Apple: [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox).
- Apple: [доступ к файлам из macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox).
- Apple: [security-scoped URL и bookmark data](https://developer.apple.com/documentation/foundation/nsurl).
- Apple: [User Notifications и действия](https://developer.apple.com/documentation/usernotifications/handling-notifications-and-notification-related-actions).
- Apple: [Swift 6 strict concurrency](https://developer.apple.com/documentation/swift/adoptingswift6).
- Git: [git-worktree documentation](https://git-scm.com/docs/git-worktree.html).

## 31. Итоговая рекомендация

Third Hand следует проектировать как локальный durable workflow engine для software tasks с нативным macOS UI, а не как terminal multiplexer с дополнительной панелью.

Его конкурентное ядро состоит из пяти частей:

1. Task живёт дольше агента.
2. Git/worktree восстанавливает фактический контекст.
3. Маленький handoff переносит только смысловую дельту.
4. Audit Gate не позволяет слепо наследовать решения.
5. Проверки и checkpoints делают переключение доказуемо безопаснее.

Если эти инварианты реализованы в domain core и проверены FakeCLI-интеграционными тестами, добавление новых официальных CLI становится расширением через adapter, а не переписыванием приложения.
