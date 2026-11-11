Found six code-backed hazards. This was a static audit of `335c7ae..HEAD`; no files were edited and no runtime reproduction was attempted.

**Confirmed from code**

1. **High — Separate windows have separate input FIFOs for the same terminal.**  
   Location: [ChatWindow.swift:30](/Users/redacted/src/bergr/bergrMac/App/ChatWindow.swift:30), with `ChatView.swift:25`, `TerminalScreenModel.swift:233`, and `ReplyDelivery.swift:259`.  
   **State/mutators:** Each window owns a model and outbox; each model owns its own `automationTail`. Reply drivers advance independently despite targeting the same host/address.  
   **Interleaving:** Main-window reply A types its text and sleeps before Enter. A detached window sends B during that sleep. B’s text reaches the same prompt before A’s Enter, submitting combined text; B’s later Enter acts on the subsequent prompt. Shell-mode and interrupt sequences can overlap similarly.  
   **Smallest fix:** Share the automation owner per `(HostSession, address)`. Reuse the existing FIFO behind a session-owned terminal input owner; all windows’ `ReplyEnvironment`s must use that owner.

2. **High — Host replacement preserves a model bound to the removed session.**  
   Location: [ChatWindow.swift:43](/Users/redacted/src/bergr/bergrMac/App/ChatWindow.swift:43), [MenuBar.swift:34](/Users/redacted/src/bergr/bergrMac/MenuBar/MenuBar.swift:34), and `MacRootView.swift:24`.  
   **State/mutators:** Host edits replace the `HostSession`; SwiftUI retains `ChatWindow`’s model/feed state. `model.started` remains true because the model retains its original session. The task key contains only agent type and connected status.  
   **Interleaving:** Open a chat, edit its machine, and let the replacement session connect. The retained model skips `start()` because `started` is true. Subsequent input still attaches through the stopped, removed session, while uploads/feed acquisition can use the replacement session.  
   **Smallest fix:** Key the chat lifecycle by session object identity as well as address, recreating its state on replacement. Ensure disappearance cancels the old outbox/model. Both main and detached windows need this.

3. **Medium — Window visibility and “read” ownership diverge.**  
   Location: [ChatWindow.swift:63](/Users/redacted/src/bergr/bergrMac/App/ChatWindow.swift:63), with `HostSession.swift:124–146` and `MacNotifications.swift:35`.  
   **State/mutators:** Appearance callbacks acquire/release `looking[address]`; activation callbacks separately update notification focus. App resignation clears notification focus but leaves `looking` registered.  
   **Interleaving:** Open a chat, switch to another app, and let the agent finish. The window remains mounted and the Mac connection stays alive. `markLookedAt()` writes the new turn as seen although the user never saw it. Unread state is lost and finished-alert eligibility can be affected.  
   **Smallest fix:** Own a read lease for the window’s active viewing state. Acquire/release it on activation and disappearance, using the existing reference-counted `startLooking`/`stopLooking` methods.

4. **Medium — A later terminal launch deletes an earlier launch’s pending script.**  
   Location: [TerminalLauncher.swift:34](/Users/redacted/src/bergr/bergrMac/Terminal/TerminalLauncher.swift:34) and [TerminalLauncher.swift:60](/Users/redacted/src/bergr/bergrMac/Terminal/TerminalLauncher.swift:60).  
   **State/mutators:** Script existence lives in a shared directory; `open()` starts a process and returns without tracking consumption. Every `writeScript()` deletes every previous script.  
   **Interleaving:** Launch A writes its script and starts `/usr/bin/open`. Before the terminal opens that file, launch B deletes it. A’s terminal cannot execute the requested attach. Main-actor serialization does not serialize the external consumer.  
   **Smallest fix:** Stop deleting scripts on each launch. Keep unique scripts and prune only sufficiently old files; launch-process completion alone does not prove the terminal has consumed the script.

5. **Medium — System SSH test results have no attempt or target identity.**  
   Location: [HostEditor.swift:280](/Users/redacted/src/bergr/bergr/Hosts/HostEditor.swift:280), [SystemSSHTest.swift:47](/Users/redacted/src/bergr/bergr/Hosts/SystemSSHTest.swift:47).  
   **State/mutators:** The button mutates `testingSystemSSH`/`systemSSH`; an untracked task publishes completion; editable fields independently mutate the target. The process is hidden inside a continuation and has no cancellation path.  
   **Interleaving:** Start testing machine A, edit the hostname/user to B while SSH waits, then receive A’s success. The editor displays “ssh works” beside B’s configuration. Dismissing the editor also leaves the process running.  
   **Smallest fix:** Introduce a small test-attempt owner containing target, process, task and result. Invalidate it on target changes/disappearance and publish only for the current attempt. Follow `ConnectionAttempt`’s identity-gating pattern.

6. **Medium — Concurrent release runs share and destroy each other’s pipeline state.**  
   Location: [mac-release.sh:19](/Users/redacted/src/bergr/scripts/mac-release.sh:19), [mac-release.sh:76](/Users/redacted/src/bergr/scripts/mac-release.sh:76), and `mac-release.sh:107`.  
   **State/mutators:** Pipeline phase is represented by files under fixed `.build/mac` paths plus external notarization/release state. Each invocation independently deletes and rewrites those paths.  
   **Interleaving:** Run A finishes notarization or signature checks. Run B clears/recreates `.build/mac`. A resumes and generates metadata or uploads using B’s files—or fails after partially completing external work. The prerequisite release check is also not a lock.  
   **Smallest fix:** Acquire an exclusive release lock before checking release existence or modifying output, and hold it through upload. Alternatively use isolated run directories plus a publication lock.

**Unconfirmed risks / design concerns**

- **Low — Composer submission depends on responder-chain state.**  
  Location: [ComposerField.swift:110](/Users/redacted/src/bergr/bergrMac/Chat/ComposerField.swift:110), with `ChatView.swift:840` and `ChatView.swift:516`.  
  **State/mutators:** NSTextView/coordinator holds text and an optional callback; SwiftUI owns draft/readiness and installs the shortcut; AppKit resolves the key equivalent. `ChatView` leaves `onSubmit` nil.  
  **Possible failure:** Return arrives during shortcut registration/removal and is swallowed because the ignored `performKeyEquivalent` result is false. That timing needs UI reproduction. The call is synchronous: I found no queued-event or stale-task race here.  
  **Smallest fix:** Pass `onSubmit: { send() }` directly. The existing guarded send/outbox remains the owner.

- **Low — Attachment selection has no cancellation or draft generation.**  
  Location: [AttachmentPicker.swift:72](/Users/redacted/src/bergr/bergrMac/Chat/AttachmentPicker.swift:72).  
  **State/mutators:** An untracked task captures available room, awaits a panel, then mutates an attachment binding; paste/send/disappearance can independently change draft state.  
  **Possible failure:** If the draft changes during selection, completion can append stale selections or use obsolete capacity. Ordinary interaction is constrained by the modal sheet, so a harmful reachable sequence needs reproduction.  
  **Smallest fix:** Own one picker task per draft, invalidate it on disappearance/replacement, and recompute capacity after awaiting.

`Platform.swift` and `TerminalLaunch.swift` contain synchronous transformations, not additional lifecycle owners. The Delivery/PushRegistration changes gate the Mac away from helper registration; existing iOS push-task races are not newly introduced Mac findings.

**Ranked:** 1. Cross-window input overlap; 2. Replaced-session binding; 3. Background read ownership; 4. Launch-script deletion; 5. SSH-test identity; 6. Release overlap; 7. Composer routing concern; 8. Attachment-picker concern.