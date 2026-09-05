# Omarchy Chime — Implementation Plan

## Goal

Build a small Omarchy shell plugin that adds restrained, configurable sounds to desktop notifications, including coding-agent completion and input requests. Notifications must retain their existing display, history, dismissal, and click-action behavior.

- Project: `/home/nick/Projects/OmarchyChime`
- Display name: **Omarchy Chime**
- Plugin ID: `nick.chime`
- Runtime: Omarchy's Quickshell-based shell and PipeWire
- Status: planning only; no plugin installed or desktop configuration changed by this plan.

## Initial scope

| Event | Sound direction | Default |
| --- | --- | --- |
| Ordinary notification | Soft single chime | Enabled |
| Agent task completed | Gentle ascending two-note chime | Enabled |
| Agent needs input | Distinct soft double tap | Enabled |

All clips should be short, preferably under half a second, with conservative loudness. Each notification selects exactly one sound. Unknown applications use the ordinary notification sound.

Also include a master mute, master volume, per-event enable switches, and explicit sound previews. Default master volume: 0.35. Preview must not change persistent settings.

### Not in the initial scope

Window open/close, workspace changes, screenshot capture, volume feedback, device connection events, dedicated error sounds, downloadable sound packs, a full settings application, and support claims for unverified coding CLIs. These can be separate later decisions, not unfinished initial-release tasks.

The installed `gobijan.ui-sounds` already handles window/workspace feedback. Do not disable, modify, or duplicate its behavior. Chime's mute initially controls Chime only.

## Verified local architecture

The following facts were checked in the installed files:

- `/usr/share/omarchy/shell/plugins/notifications/manifest.json` declares a persistent service plugin, `omarchy.notifications`.
- Its `Service.qml` owns the `NotificationServer`, processes new notifications in `handleNotification(notification)`, and exposes `doNotDisturb`.
- The DND filter runs before `persistPopupFile(snapshot)` and popup insertion. Some notifications bypass visual DND suppression; sound should still remain muted during DND.
- The service does not currently expose a public notification-received signal for another plugin to subscribe to. Its internal `server` QML ID is not a public property.
- Replacement updates can mutate a tracked notification without a second `onNotification` event. History replay and restored popups have separate paths.
- `NotificationLogic.js` snapshots app name, summary, body, urgency, and selected hints, but not the complete hint map. Sound suppression must therefore be checked against the live notification before discarding that information.
- `omarchy plugin clone` copies a built-in plugin into user configuration, records `omarchy.clonedFrom`, and enables the replacement. The script documents routing built-in IPC targets to the clone.
- User plugin files hot-reload. Packaged files under `/usr/share/omarchy/` must remain untouched.
- `pw-play` and freedesktop sound files are installed.
- The installed Oh My Pi binary constructs notifications with a session-name title or `Oh My Pi`, body `Complete` or `Waiting for input`, and internal types `completion` or `ask`. Its native Linux sender uses app name `Oh My Pi`. Whether those internal types survive the active delivery transport as desktop notification metadata has not been verified.

## Architecture decision

For this installed Omarchy version, use a **user-owned replacement of the notification plugin**, branded `nick.chime`, rather than a second notification daemon or a D-Bus monitoring process.

Preserve the upstream notification implementation and add a small, isolated sound controller at the new-notification acceptance point. Preserve `omarchy.clonedFrom: omarchy.notifications` and verify service routing before installation is considered successful. The clone must replace, not run alongside, the original notification server.

This is deliberately a compatibility choice, not a claim that Omarchy exposes a standalone sound-event API. The maintenance cost is that the copied notification implementation does not automatically receive upstream fixes. Record the source package version and retain a clearly identifiable baseline for future comparisons. If Omarchy later exposes an appropriate event signal, migration to a service-only sidecar can be considered separately.

### Planned source layout

```text
OmarchyChime/
  IMPLEMENTATION_PLAN.md
  README.md
  CHANGELOG.md
  manifest.json
  Service.qml                 # notification service with narrow Chime integration
  NotificationLogic.js        # preserved upstream notification behavior
  components/                 # preserved upstream popup components
  ChimeController.qml         # settings, playback gating, and process lifetime
  ChimeLogic.js               # pure event classification and sound policy
  BarWidget.qml               # compact mute toggle
  sounds/                     # three project-owned, license-documented clips
  tests/                      # only behavior regressions justified below
```

Preserve upstream attribution and applicable license requirements when copying source. Do not create unused directories or modules in anticipation of later features.

## Implementation phases

### Phase 1 — Establish the replacement and delivery contract

1. Record installed Omarchy and Quickshell versions and the notification plugin source baseline.
2. Read the current plugin loader, replacement routing, bar widget conventions, and plugin enable/disable commands before choosing final manifest details. Use the existing clone workflow as the reference; avoid inventing manifest fields or changing the plugin ID after activation.
3. Prepare the replacement under the project folder. Set `nick.chime`, preserve the notification service entry point and `clonedFrom` metadata, and add the bar-widget kind using the installed schema.
4. Determine and document a reversible development installation method. Keep the source repository separate from user configuration; use the supported local installation workflow, or a user-owned symlink only if loader discovery and file watching support it.
5. Observe actual notification payloads for a normal send, an Oh My Pi completion, and an Oh My Pi input request. Use temporary, minimal instrumentation; do not persist notification bodies or capture unrelated private notifications.
6. Verify that only one notification server remains active and existing DND/history/dismissal IPC routes resolve to the replacement. Do not continue to sound implementation with a partially working replacement.

**Acceptance:** the local plugin displays ordinary notifications with unchanged actions/history and can be disabled to restore the built-in plugin. The agent-classification contract is based on observed desktop payloads, not the CLI's internal type fields alone.

### Phase 2 — Define classification and mute policy

1. Normalize only fields needed for classification: application identity, event metadata when available, body fallback where verified, urgency, and sound-suppression hint.
2. Classification precedence: explicit supported agent event metadata; then verified application-specific fallback; otherwise generic notification.
3. For native Oh My Pi notifications, use exact app identity plus verified event/body values if structured metadata is absent. Never classify solely from a session title, generic body text, or critical urgency. Document wording-based matching as version-sensitive.
4. Treat unverified terminal-forwarded agent notifications as generic until their payload contract has been observed. Do not advertise distinct completion/input support for a transport that cannot be classified reliably.
5. Apply master mute, event toggle, DND, sender `suppress-sound`, and session-lock gating before playback. Follow installed lock-service access conventions; initialize conservatively until settings and required service state are ready.
6. Choose the specific event once. Disabling its sound means silence, not falling back to the generic chime.
7. Do not execute commands or select arbitrary file paths from notification text, hints, or sender-provided sound paths. Only Chime's trusted configured assets are used.

**Acceptance:** known completion/input events select their specific sound; unrelated apps cannot acquire those sounds merely by using the same body text. Muted or suppressed events produce no playback.

### Phase 3 — Add bounded audio playback

1. Create three distinct short clips with clean starts/ends and consistent perceived loudness. Use project-owned or explicitly redistributable assets; include provenance and licensing.
2. Use `Quickshell.Io.Process` with an argv array to launch `pw-play`. No shell command interpolation and no new audio daemon.
3. Use one active playback process. Drop events while it is busy and apply a short configurable-in-code cooldown, initially 250 ms, to prevent rapid bursts. Do not queue delayed sounds.
4. Hook playback only into newly accepted notifications, after the existing visual DND filter, while independently enforcing sound DND suppression even for visual bypass notifications.
5. Do not hook model row counts, popup restoration, history replay, or property-refresh paths. These must not replay sounds.
6. Stop playback when Chime is muted, DND becomes active, or the session locks. Verify how process ownership behaves on plugin unload and hot reload; explicitly terminate a child if necessary.
7. If audio is unavailable, playback fails, or an asset is missing, leave notifications functional. Emit a concise diagnostic without displaying another notification or retrying indefinitely.

**Acceptance:** each eligible notification starts at most one sound; bursts never create overlapping players or a backlog. Failed audio cannot prevent popup delivery.

### Phase 4 — Add settings and a small control surface

1. Follow an existing Omarchy plugin's settings-loading and persistence conventions. Store user settings separately from plugin source, under a Chime-specific user-config path.
2. Settings: schema version, master enabled flag, volume in the range 0–1, and an enabled flag for each initial event. Use safe defaults on first load; invalid reloads must not unexpectedly unmute an already-muted plugin.
3. Add a bar widget showing muted/unmuted state. Clicking toggles Chime sound; a tooltip describes the current state. Use the current theme's colors and sizing rather than hard-coded styling.
4. Provide a small verified IPC surface for status, mute/unmute, volume, and event preview. Avoid colliding with the inherited notification IPC target. Document command syntax only after runtime verification.
5. Preview explicitly plays the selected clip, including when Chime's own master switch is muted, but still respects DND and session lock. It uses the same bounded player and does not emit a desktop notification.
6. Keep the initial configuration interface small: the mute widget, IPC, and a documented settings file. Do not add a full settings panel solely for three event toggles.

**Acceptance:** settings survive shell restart, controls update without reload loops, preview does not alter saved settings, and the mute state remains visible and accurate.

### Phase 5 — Exercise the real desktop surface

Use the actual Omarchy shell and notification command, not source-text assertions. Preserve the user's current DND and mute state and restore them after verification.

| Scenario | Required observation |
| --- | --- |
| Ordinary notification | One popup and one generic chime |
| Agent completion and input request | Verified real payload selects the appropriate distinct sound |
| Unnamed and named agent sessions | Session title does not affect classification |
| Unrelated app with body `Complete` | Generic sound, not agent completion |
| Master mute or per-event disable | Popup behavior preserved; no sound |
| DND, including a visual bypass notification | No sound |
| Sender sets `suppress-sound` | No sound |
| Reopening history or restoring shell popups | No replayed sound |
| Replacing an existing notification | Existing popup behavior preserved; no update chatter |
| Notification burst | Bounded playback, no overlap or delayed queue |
| Missing asset or unavailable audio | Notifications still arrive; no notification/error loop |
| Lock, mute, or unload during playback | Playback stops as specified |
| Restart and hot reload | Settings retained; no duplicate listener or player |
| Notification click/dismiss and DND/history commands | Original behavior retained |
| Disable Chime | Built-in notification service restored and functional |

Keep focused deterministic regression tests for classification precedence, specific-event disable semantics, suppression, and burst gating where plausible mistakes would change observable behavior. Use the repository's eventual language/tool conventions; do not introduce a framework for source-string or forwarding assertions.

Desktop screenshots confirm widget and popup state, not audible output. Verify playback process behavior and an actual sound observation separately. If physical audibility cannot be observed remotely, state that limitation and distinguish it from PipeWire/process success.

### Phase 6 — Package and document the verified implementation

After smoke verification succeeds:

1. Remove temporary instrumentation and throwaway scripts.
2. Write installation, settings, mute/preview, troubleshooting, and uninstall instructions in `README.md`, using commands actually exercised.
3. Record the initial feature set and compatibility constraints in `CHANGELOG.md`.
4. Document the upstream source baseline, attribution, asset licenses, and clone-update maintenance responsibility.
5. Document coexistence with `gobijan.ui-sounds`: independent mute controls and no duplicated window/workspace listeners.
6. Uninstall must remove only Chime-owned installation artifacts, restore built-in notification routing, and preserve unrelated shell configuration. Preserve user settings unless their deletion is explicitly requested.

## Definition of done

- The plugin runs from the project through a documented, reversible user-owned installation.
- The three initial sounds are implemented with verified classification for the supported local agent delivery path.
- Silence, privacy, process bounds, and existing notification behavior satisfy the verification matrix.
- Mute, volume, per-event settings, and previews work and persist as specified.
- No packaged Omarchy files or existing UI-sounds plugin files are modified.
- Runtime and visual verification results, audio-observation limits, supported versions, and uninstall steps are documented accurately.
