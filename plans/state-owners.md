# State owners: connection attempt, reply delivery, Live Activity session

Before external beta. Three independent chunks (A, B, C), one agent and worktree each, no shared file.
The app target is MainActor by default; all new types are main-actor types. `bergr/` and `bergrTests/`
are synchronized folders (new files need no project edit). `TerminalScreenModel.automate` stays and is
the only way automated keys are typed. Source: audit /private/tmp/bergr-implicit-state-machines.md.

Decisions (made by the user): outbox keeps the chat view's lifetime (+ `cancelAll` on disappear);
pause is idempotent; DELETE to the relay after an abandoned registration (ordered after its POST);
delivery monitor reads the agent state fresh from the session; one ConnectionAttempt per start/retry
(covering its automatic reconnect rounds).

| Agent | Edits | Creates |
|---|---|---|
| A Connection | `bergr/Terminals/HostSession.swift` | `bergr/Terminals/ConnectionAttempt.swift`, `bergrTests/ConnectionAttemptTests.swift` |
| B Reply | `bergr/Chat/ChatView.swift`, `bergrTests/PendingReplyTests.swift` | `bergr/Chat/ReplyDelivery.swift`, `bergrTests/ReplyDeliveryTests.swift` |
| C Live Activity | `bergr/Background/LiveActivityController.swift` | `bergr/Background/LiveActivitySession.swift`, `bergrTests/LiveActivitySessionTests.swift` |

Frozen contract (A must not change; B and C rely on it): `HostSession.state`, `.terminals`,
`.terminal(_:)`, `.retry(keys:)`, `.start(keys:)`, `.stop(forgetKey:)`, `.isActive`, `.openExec`,
`.exec`, `.canRunCommands`, `.machines`, `.host`, `.uploadImage`, `SessionStore.existing/ids/pauseAll/resumePaused`.
RootView and TerminalScreenModel are not edited.

## A. Connection attempt

```swift
struct HostConnection {            // what one successful connect holds; closed as a unit
    let client: HerdrClient
    let ssh: SSHConnection?        // nil for the demo and in tests
    let coreName: String?
    let coreVersion: String?
    let close: @Sendable () async -> Void   // live: client.close(), then ssh?.close()
}
struct HostConnector {
    struct Context {
        let reconnecting: Bool                                   // snapshot != nil
        let progress: @MainActor (String) -> Void                // gated by the attempt
        let signingKey: @MainActor () async throws -> SigningKey // cached or unlock; throws .noKey
        let askToTrust: @Sendable (HostKey) async -> Bool
    }
    var connect: @MainActor (Context) async throws -> HostConnection
    static func live(host: Host, knownHosts: any KnownHostsStore) -> HostConnector // today's connectOnce (demo path too)
}
struct ConnectionTiming {
    var firstDelay: Duration = .seconds(1); var maxDelay: Duration = .seconds(30)
    var silenceLimit: Duration = .seconds(40); var silenceCheck: Duration = .seconds(5)
}
@MainActor protocol ConnectionAttemptOwner: AnyObject {
    func isCurrent(_ attempt: ConnectionAttempt) -> Bool
    func attempt(_ a: ConnectionAttempt, progress: String)
    func attempt(_ a: ConnectionAttempt, connected c: HostConnection, snapshot: TerminalSnapshot,
                 machines: [MachineView], layout: HerdrAppLayout?)
    func attempt(_ a: ConnectionAttempt, received message: EventMessage) async
    func attempt(_ a: ConnectionAttempt, failed error: Error, retrying: Bool)
    func attemptFinished(_ a: ConnectionAttempt)     // loop ended without cancel
}
final class ConnectionAttempt {
    enum Phase: Equatable { case connecting, live, backingOff, cancelled, finished }
    let generation: UInt64
    private(set) var phase: Phase
    private(set) var connection: HostConnection?
    init(generation:owner:connector:context:isRetryable:timing:)
    func start()
    @discardableResult func cancel() -> Task<Void, Never>   // cancel runner, take connection now, close it; idempotent
}
```
HostSession gains `init(host:knownHosts:connector: HostConnector? = nil, timing: ConnectionTiming = .init())`,
`private var attempt`, `generation`, `private(set) var intent: Intent { stopped, running, paused }`,
`pause()`, `resume(keys:)`.

Moves: `runner/ssh/client` → `attempt` / `attempt.connection` (attach, connectedClient, markLookedAt,
openExec, exec, canRunCommands read it). `run(keys:)` backoff loop → `ConnectionAttempt`. `connectOnce` →
`HostConnector.live`; after `await connector.connect`, if not current: close the result, throw Cancellation.
`followEvents` + `silentTooLong` → attempt. `apply` stays in HostSession as `attempt(_:received:)`, re-checking
`isCurrent` after each await before writing machines/layout. `teardown` deleted. `stop` = stopFeeds;
attempt?.cancel(); attempt = nil; forget key; answerHostKey(false); same state rule. `SessionStore.paused`
→ per-session `intent`; `pauseAll/resumePaused` loop calling `pause()/resume(keys:)`. Signing-key cache
stays on the session, stored only if the attempt is still current.

| From | Event | To | Effects |
|---|---|---|---|
| no attempt | start | connecting | generation += 1, `.connecting` |
| connecting | connect returns, current | live (after subscribe) | publish connection, snapshot, `.connected` |
| connecting | connect returns, not current | cancelled | close it, publish nothing |
| live | stream end / error / silence | backingOff | close, `.failed(retrying: true)`, sleep 1→30 s |
| connecting/live | non-retryable error | finished | close, `.failed(retrying: false)`, isActive false |
| any | cancel (stop, retry, pause) | cancelled | connection taken and closed, no more publishes |

Intent: running -pause→ paused (stop(forgetKey: false)); paused -pause→ paused; paused -resume→ running;
any -retry/start→ running; any -stop→ stopped; stopped -pause/resume→ stopped.

Must not change: State cases and `.connecting` strings; describe/isRetryable; stop keeps `.failed` else
`.idle`; snapshot survives stop ("Reconnecting…"); backoff 1 s ×2 to 30 s, reset on success; 40 s silence
checked every 5 s; isActive false after non-retryable failure; feeds pause on stop; resume skips Face ID; demo.

Tests (fake connector waits on a test-opened gate, returns `HerdrClient.connectDemo()` with a close that
records its index, ignores cancellation; timing in ms; `KeyLibrary()` is constructible):
retryWhileConnectingClosesOnlyTheOldLine; stopDuringConnectPublishesNothing;
lateFailureOfOldAttemptDoesNotFailNewOne; stopThenRetryTeardownOrder; nonRetryableEndsAttempt (then retry
works); backsOffAndReconnects; pauseTwiceStillResumes; resumeDoesNotStartStoppedSessions;
pauseDuringConnectThenResume; eventAfterCancelIsDropped.

## B. Reply delivery

```swift
struct ReplyPayload: Equatable {   // ChatView.Pending's matching, moved
    let text: String; let hasImages: Bool; var known: Set<String>
    func arrived(in items: [ChatFeed.Item]) -> Bool
    func isIn(_ said: Set<String>) -> Bool
    static func onScreen(_ text: String, lines: [String]) -> Bool
}
@MainActor protocol ReplyTerminal: AnyObject {
    var textLines: [String] { get }   // model.textLines
    var frameLines: [String] { get }  // model.frame.textLines (kept separate on purpose)
    func automate(_ steps: @escaping @MainActor () async -> Void) async
    func type(_ text: String); func paste(_ text: String); func press(_ key: TerminalKey)
}
extension TerminalScreenModel: ReplyTerminal {}   // in ReplyDelivery.swift, with frameLines/press shims
struct ReplyTiming { enterDelay 150ms; shellBangDelay 120ms; confirmEnterWait 2500ms; confirmEnterTries 2;
                     firstCheck 10s; recheck 5s; imagesGiveUp 20s; stopWait 3s }
struct ReplyEnvironment {
    var terminal: any ReplyTerminal
    var agentState: @MainActor () -> String?          // fresh from the session
    var feedItems: @MainActor () -> [ChatFeed.Item]
    var upload: @MainActor (Data) async throws -> String   // session.uploadImage + SentImages.store
    var reconnect: @MainActor () async -> Void             // today's retry reconnect dance
    var timing = ReplyTiming()
}
@Observable final class ReplyDelivery: Identifiable {
    enum Phase: Equatable { case sending, queued, pushed, failed, confirmed }
    let id = UUID(); let payload: ReplyPayload
    private(set) var phase: Phase; private(set) var sentAt: Date; private(set) var attempts = 1
    var text: String { payload.text }
}
@Observable final class ReplyOutbox {
    private(set) var replies: [ReplyDelivery]
    var environment: ReplyEnvironment?
    func shown(in items: [ChatFeed.Item], search: String?) -> [ReplyDelivery]
    @discardableResult func send(text: String, images: [ChatAttachment], interrupting: Bool,
                                 onUploadFailure: @escaping @MainActor (Error) -> Void) -> ReplyDelivery?
    func pushNow(); func retry(_ id: ReplyDelivery.ID); func discard(_ id: ReplyDelivery.ID)
    func feedChanged(_ items: [ChatFeed.Item]); func cancelAll()
}
```
Ownership: each delivery has exactly one driver Task and an `epoch`. retry/discard/confirmation bump the
epoch and cancel the driver. `automate` runs steps in an unstructured task, so every step sequence checks
`epoch == mine` after each sleep and before each type/paste/press. pushNow is one outbox-level task; a
second tap while it runs is ignored. Record `wasQueued` at send so pushNow picks targets from data.

Moves out of ChatView: `Pending` → ReplyPayload (keep `typealias Pending = ReplyPayload` if cheaper for
tests); `@State pending` → `@State private var outbox = ReplyOutbox()`; shownPending → outbox.shown;
pushNow + waitForScreen, waitUntilStopped, confirmEnter, the key part of send, confirmPending + 21 s image
task, watchDelivery, retry → outbox/driver. The view keeps: draft trimming, `!` normalisation, canType,
setWatching(false), clearing draft/attachments, sent += 1, demoUserSaid, scroll, upload-failure draft
restore (only if the box is still empty) via onUploadFailure, `pushes += 1`, rendering from `reply.phase`,
`.onChange(of: feed.items)` → `outbox.feedChanged`, `withAnimation(motion)` around outbox calls.

| From | Event | To | Effects |
|---|---|---|---|
| new | send, agent idle | sending | upload → automate(type, Enter) → confirmEnter → monitor |
| new | send, agent working | queued | same driver |
| new | send interrupting, working | pushed | Esc, wait stopped, then type |
| queued | pushNow | pushed | one Esc, at most one Enter for all queued |
| sending/queued/pushed | feed has a new matching user item | confirmed (removed) | driver cancelled |
| … with images | 20 s since sentAt | removed | |
| … no images | 10 s, then every 5 s: agent not working and text not on screen | failed | driver ends |
| sending | upload throws | removed | onUploadFailure; nothing typed |
| failed | retry | sending | epoch += 1, sentAt = now, reconnect; type only if not on screen; Enter; monitor |
| any | discard | removed | epoch += 1, cancel |

Must not change: "2 images" bubble text; `!` shell path (type "!", 120 ms, rest); paste for multi-line or
paths; 150 ms before Enter; confirmEnter 2.5 s × 2 only while probe on last 6 lines and agent not working;
10 s/5 s monitor; 20 s image give-up; known-based confirmation and suffix(20); Retry submits what's in the
prompt without retyping; pushNow skips Enter when no queued text on the last 12 lines; labels,
accessibility labels, animations.

Tests (FakeTerminal logs keys, settable lines, serial automate; ms timing; move existing matching tests):
earlierIdenticalMessageDoesNotConfirm; uploadFailureRemovesOwnBubbleOnly; retryLeavesOneMonitor;
doubleRetryTypesOnce; retryWithTextOnScreenOnlyPressesEnter; discardWhileWaitingInAutomationTypesNothing;
confirmDuringConfirmEnterStopsExtraEnter; pushNowTwiceIsOneEscape; pushNowSkipsEnterWhenAgentDrainedQueue;
pushNowDuringRetryDoesNotDoubleType; imagesConfirmAfterDeadlineWithoutFeedChange; workingAgentNeverFails;
queuedTextOnScreenNeverFails. Check the chat's pending bubble visually (light/dark, narrow phone, Duo) per AGENTS.md.

## C. Live Activity session

```swift
@MainActor protocol ActivityHandle: AnyObject {
    var pushTokens: AsyncStream<Data> { get }
    func update(_ state: BergrActivityAttributes.ContentState) async
    func end() async
}   // live impl wraps Activity<BergrActivityAttributes>, also notes .dismissed/.ended into the history
struct LiveActivityEnvironment {
    var request: @MainActor (_ state: LiveActivitySession.State, _ pushed: Bool) throws -> any ActivityHandle
    var relay: @MainActor (_ method: String, _ body: [String: Any]?) async -> Bool   // today's post()
    var beginBackgroundTime: @MainActor () -> (@MainActor () -> Void)
    var now: @MainActor () -> Date = { .now }
    var sleep: @MainActor (Duration) async -> Void
    var note: (String) -> Void = LiveActivityController.note
    static var live: LiveActivityEnvironment
}
final class LiveActivitySession {
    typealias State = BergrActivityAttributes.ContentState
    enum Push: Equatable { case awaitingToken, registering, registered }
    enum Mode: Equatable { case none, local, push(Push) }
    private(set) var mode: Mode
    var ownedByRelay: Bool
    init(environment: LiveActivityEnvironment = .live, minInterval: TimeInterval = 2,
         registerBackoff: [Duration] = [.zero, .seconds(2), .seconds(5)])
    func show(_ state: State?, pushed: Bool, registration: @MainActor () -> [String: Any])
    func adopt(_ handle: any ActivityHandle, registration: @MainActor () -> [String: Any])
    @discardableResult func end(reason: String) -> Task<Void, Never>
}
```
`registration` builds the POST body lazily (session adds the token): mode, hide_after, seed of connected machines.

Moves: activity, lastSent, lastSentAt, pending, tokenTask, registeredForPush, relaySeed → session.
reconcile shrinks to: prefetch screens; not in background → session.end(reason: "ended: Bergr opened");
else session.show(current(), pushed: byPush, registration:). end/registerForPush/unregisterFromPush →
session; post → environment.live.relay. Launch adoption loop keeps deciding and calls session.adopt.
Controller keeps: content, seed, screenKey, target, note, keys, observe, writeSnapshot, prefetchScreens,
screenAnswered, current, byPush, inBackground, run.

| From | Event | To | Effects |
|---|---|---|---|
| none | show(state, pushed: false) | local | request; lastSent/lastSentAt |
| none | show(state, pushed: true) | push(awaitingToken) | request with token; background time; listen |
| none | show(nil) / request throws | none | nothing |
| local | show(new) ≥ 2 s since last | local | update, in order |
| local | show(new) < 2 s | local | one timer; latest state wins |
| local | show(same) | local | nothing |
| local | show(nil) | none | end "nothing to show" |
| push(any) | show(anything) | unchanged | relay owns it |
| push(awaitingToken) | token | push(registering) | POST, retried after 0, 2, 5 s |
| push(registering) | POST ok | push(registered) | release background time |
| push(registering) | all POSTs fail | local | note "the relay didn't take it: updated by Bergr"; show latest |
| push(registered) | new token | push(registering) | re-POST |
| not none | end | none | cancel timer + registration, end activity; DELETE if any POST was started, after it finished |

Must not change: start/end timing (background with content; foreground ends; push-owned not ended in
background); pushType from byPush; 2 s throttle; relay body keys; seed of connected machines only; history
note wording; adoption only in background with a push token, others end; background time held until first
successful POST or registration end.

Tests (FakeHandle, FakeRelay with scripted results + optional gate, manual clock and sleep):
relayFailureFallsBackToLocal; endWhileAwaitingTokenLeavesNothingBehind; endWhileRegisteringSendsDeleteAfterPost;
tokenAfterEndIsNotPosted; endBeforeAnyPostSendsNoDelete; endWhenRegisteredSendsDelete; pushModeIgnoresShowAndNil;
throttleCoalesces; endCancelsDeferredUpdate; rotatedTokenReRegisters; rotationFailureFallsBackAndStillDeletesOnEnd;
replacementRegistrationCancelsOld; adoptStartsInAwaitingToken.
