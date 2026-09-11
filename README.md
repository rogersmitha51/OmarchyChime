# Omarchy Chime

Independent Omarchy shell plugin (`nick.chime`) that plays short desktop
sounds, system volume/power cues, and an agent needs-input cue. It owns no
notification daemon, popup, history, or DND state — the built-in
`omarchy.notifications` service keeps all of that.

## Status

- **0.1.0 (alpha 1)** — implemented and runtime-verified on the installed
  shell: window open/close and workspace-switch sounds, mute, volume,
  desktop activation, previews, DND/lock/idle gating.
- **0.2.0 (alpha 2)** — published upstream. Adds the `agentNeedsInput` cue,
  the `agentInput on|off` switch, the `preview agentNeedsInput` command,
  and a passive session D-Bus observer. The alpha 2 candidate was verified
  on the live desktop on 2026-09-10 (see the historical Alpha 2 summary
  below).
- **0.3.0 (alpha 3 candidate)** — implemented in this working tree on top
  of published 0.2.0, but **not committed, pushed, or published**. Adds
  volume up/down and power connection/disconnection cues, the latest-only
  rapid-cue replacement rule, and new preview event names.

### Current 0.3.0 candidate verification

Current-source gates: **38 Node tests**
(`node --test tests/controller.test.mjs tests/desktop.test.mjs
tests/system.test.mjs`) and **36 Python unittest tests**
(`python -m unittest discover -s tests -p observer_test.py`) pass; plugin
validation is green and qmllint is clean across product QML/JS and the
test harness. The isolated service harness passed: it exercises the real
product service's safety-gated playback with injected DND/lock/idle
objects. A live volume-up/down probe attached a source-loaded
`SystemEvents.qml` adapter to the live default PipeWire sink: raising the
output volume 0.65→0.66 emitted event ID `volumeUp`, restoring it
0.66→0.65 emitted `volumeDown`, and `wpctl get-volume` confirmed the
output volume back at 0.65. The candidate was not installed into the
shell; that probe did not invoke ChimeController, play or audibly verify
a cue, or change the plugin volume.

Issue #2 is addressed in this candidate but the fix is only source-level
so far: after the earlier busy-only fix landed, a second workspace switch
commonly arrives after the previous cue's child process exits and during
the 250 ms post-exit cooldown — both transitions share the event name
`workspaceSwitched`, so a distinct-event-name cooldown policy still
dropped it. The completed fix exempts automatic non-agent desktop and
volume/power cues from the post-exit cooldown entirely (their source state
machines already deduplicate non-transitions and the controller preempts a
running voice); the cooldown still governs agent-input cues and previews.
The live rapid-switch race has **not** been re-tested on the desktop yet —
no redeployment or user confirmation has happened, and the orchestrator
performs those.

**Not yet performed (current candidate):** physical power plug/unplug
transition (a real UPower on-battery change) and audible verification of
the power cue. Multi-monitor audibility has not been re-exercised for this
candidate either; coverage there remains deterministic tests only.

### Alpha 2 verification summary (historical, published 0.2.0)

Verified on the live desktop (2026-09-10): plugin validation green;
qmllint clean across product QML/JS and the test harness; 24 Node tests
(`node --test tests/controller.test.mjs tests/desktop.test.mjs`) and 36
Python unittest tests (`python -m unittest discover -s tests -p
observer_test.py`) pass; the installed candidate actually loaded; v1
settings migrated preserving `enabled`/`volume`/`desktopEnabled` with the
new agent switch off; the real Oh My Pi 18.1.16 ask triggered the local
WAV cue; native process sampling, preview bypass, overlap, mute, DND,
reload, and helper-lifecycle scenarios behaved as specified; plugin
disable/reenable and same-version file touch preserved settings with no
cue burst; desktop open/close and workspace round-trip mapped correctly;
the standalone observer smoke suite passed; the owner-change fixture
(private bus) produced the expected error and clean exit without touching
the real notification owner.

**User-confirmed audibility** — the only physically audible confirmation
is the user's own native ask: the cue played and the user confirmed
"Yes, heard it" (listening at volume 0.35; the original volume 1 was
restored afterward). Everything else above is automated/process-level
verification.

**Simulated limits** — lock/idle/DND and helper-lifecycle transitions
were exercised through the isolated QML harness with a pre-created
isolated XDG parent, not a physical lock/unlock. Multi-monitor behavior
was verified only through deterministic tests; physical audibility was
not confirmed on multiple screens. The owner-change test ran on a private
D-Bus session, not the real desktop bus.

## Install / update (omarchy plugin CLI)

The published remote is https://github.com/rogersmitha51/OmarchyChime.git.
The remote currently tracks **0.2.0 (alpha 2)**; the 0.3.0 candidate
changes in this working tree are **uncommitted**, so a fresh clone
installs 0.2.0 until they are committed and pushed.

A plugin installed via `omarchy plugin add` lives as a git checkout under
`~/.config/omarchy/plugins/nick.chime` and is managed with the standard
`omarchy plugin` commands:

```sh
# From the published git URL:
omarchy plugin add https://github.com/rogersmitha51/OmarchyChime.git --enable

# From local source (git clone accepts a local path; the CLI's URL check
# allows bare paths). The clone captures the source repo's committed state.
omarchy plugin add /path/to/OmarchyChime --enable

# Update an installed git-managed plugin (fast-forwards the installed
# checkout to the source repo's committed HEAD):
omarchy plugin update nick.chime

# Enable / disable / remove:
omarchy plugin enable nick.chime
omarchy plugin disable nick.chime
omarchy plugin remove nick.chime --yes

# Validate a plugin folder against the manifest schema:
omarchy plugin validate .
```

`omarchy plugin add` runs `omarchy plugin validate` before installing and
refuses a plugin whose id is already installed. `omarchy plugin update`
rolls back if the update fails validation. No other plugin or bar layout is
ever modified by Chime.

> **Candidate note.** The 0.3.0 candidate changes in this working tree are
> not yet committed, and `git clone` only copies committed content.
> Installing from a local path therefore installs the committed 0.2.0
> state until the 0.3.0 changes are committed and pushed. The installed
> plugin on this machine is a plain copy, not a git checkout, so
> `omarchy plugin update` does not apply to it.

### Trying the uncommitted 0.3.0 candidate (maintainer-only)

The 0.3.0 candidate is not a published install, so there is no
supported end-user update path for it yet. A maintainer who wants to
exercise the uncommitted working tree on a live shell can do so by
swapping the installed plugin for the candidate in place:

```sh
# 1. Disable the installed plugin first. The shell hot-reloads files saved
#    under the plugins dir, so swapping the directory while the plugin is
#    loaded would race a half-removed plugin; disabling unloads it cleanly.
omarchy plugin disable nick.chime

# 2. Stage the candidate outside the plugin discovery directory
#    (~/.config/omarchy/plugins), e.g. /tmp/chime-candidate, and validate
#    it there. The discovery scan only reads top-level subdirectories of
#    the plugins dir, so a staging copy outside it is never picked up.
omarchy plugin validate /tmp/chime-candidate

# 3. Keep the installed plugin as a backup. The name must start with a
#    dot: the discovery scan and file watcher treat dot-prefixed entries
#    under the plugins dir as non-plugins, so a plain name like
#    nick.chime.bak would be scanned as a second copy of the same id.
mv ~/.config/omarchy/plugins/nick.chime ~/.config/omarchy/plugins/.nick.chime.bak

# 4. Move the staged candidate into place. The staging dir is on the same
#    filesystem as the plugins dir, so mv is atomic — the shell never
#    observes a half-written plugin.
mv /tmp/chime-candidate ~/.config/omarchy/plugins/nick.chime

# 5. Re-enable the candidate.
omarchy plugin enable nick.chime
```

**Loading the new files requires a user-authorized normal shell restart,
not a rescan.** The installed host keeps a cached copy of the plugin, so
`omarchy-shell shell rescanPlugins` (or disable/rescan/re-enable) does
**not** reliably load changed QML — in practice it can keep serving the
previously cached version. After swapping the files, check the loaded
version with `omarchy-shell chime status`; if it still reports the old
version, the host cache is stale. To pick up the new files, the user must
**unlock the desktop and authorize a normal Omarchy shell restart** (a
plain restart of the shell, not a host/system-config change). Never
restart a locked desktop, and never attempt to force the reload while the
session is locked.

To revert, disable the candidate, remove it, restore the backup, and
restart the shell as above. This is a manual, maintainer-only deployment:
it is not a runnable published install, and the shell hot-reloads files
saved under `~/.config/omarchy/plugins/`, so never copy files into a live
plugin directory while the shell is running — disable first, then swap.

## Controls (IPC)

The shell must be running; commands are forwarded with `omarchy-shell`:

```sh
omarchy-shell chime status
omarchy-shell chime mute
omarchy-shell chime unmute
omarchy-shell chime volume 0.35
omarchy-shell chime desktop on|off
omarchy-shell chime agentInput on|off
omarchy-shell chime preview agentNeedsInput
omarchy-shell chime preview windowOpened
omarchy-shell chime preview windowClosed
omarchy-shell chime preview workspaceSwitched
omarchy-shell chime preview volumeUp
omarchy-shell chime preview volumeDown
omarchy-shell chime preview powerConnected
omarchy-shell chime preview powerDisconnected
omarchy-shell chime help
```

- `status` reports safety gates, controller state, the desktop adapter,
  the volume/power (system) adapter (`active`, `ready`, source readiness,
  current sink and readings), and the notification observer (`active`,
  `ready`) — never notification contents.
- `preview` plays the cue immediately, bypassing mute, event switches,
  overlap, and observer readiness, but always obeying DND/lock/idle
  safety, the single voice, and the cooldown.
- `agentInput on|off` is the persistent per-event switch. It **defaults to
  off**; the observer child only runs while it is on (and the session is
  safe, settings are decided, and the master switch is on). The default is
  off, but the current installed state on this machine has it **on** — the
  owner explicitly chose to keep `agentInputEnabled: true` after the v1→v2
  migration. A fresh install starts with the default (off).

## Volume semantics

Chime's `volume` setting is a **per-stream relative alert gain**: it
multiplies Chime's own output relative to the system's output volume. It
does not set, bypass, or fight the system volume — the global PipeWire
output volume (and its mute state) remains authoritative. This matches
Apple/macOS guidance (the alert-relative volume is a multiplier on top of
the system output volume) and normal desktop audio practice: system
output volume governs overall loudness, and per-app/per-alert gain only
scales the cue relative to the rest of the session. Muting or lowering
the system output mutes or lowers Chime like any other audio; Chime's
mute is its own master switch on top of that. Volume events are detected
from the **default PipeWire sink**, so changing the output device simply
switches which sink volume changes are watched.

## Events and playback

Automatic events: `windowOpened`, `windowClosed`, `workspaceSwitched`
(desktop), `volumeUp`, `volumeDown` (default PipeWire sink volume
changes), `powerConnected`, `powerDisconnected` (UPower AC/battery
state), and `agentNeedsInput` (the passive observer). Desktop and system
cues use stock freedesktop theme sounds (see `UPSTREAM.json` for the
mappings); the agent-input cue is a local plugin asset.

## Settings and migration

Settings live in `$XDG_CONFIG_HOME/omarchy/chime.json` (default
`~/.config/omarchy/chime.json`). Alpha 2 and later use schema **v2**:

```json
{
  "version": 2,
  "enabled": true,
  "volume": 1,
  "desktopEnabled": true,
  "agentInputEnabled": true
}
```

A complete alpha-1 (v1) file is accepted and migrated with
`agentInputEnabled: false`, preserving `enabled`, `volume`, and
`desktopEnabled`. The values above are the current installed state on
this machine: the owner explicitly chose to keep `agentInputEnabled: true`
(and the migrated `enabled`/`volume`/`desktopEnabled` values) after the
migration. Invalid or incomplete files are never overwritten: the
last valid settings are preserved and the error is reported in `status`.
Missing required state means silence — a malformed reload can never unmute
or flip the agent switch on.

## Behavior and fail-closed policy

- **Single voice, no queue.** All cues share one `pw-play` voice. A cue
  arriving while another cue is playing is dropped, never queued or
  replayed — a busy agent cue can be missed by design. After a cue exits, a
  250 ms cooldown governs agent-input cues and previews; automatic
  non-agent events ignore it entirely (see below).
- **Cooldown scope.** The post-exit cooldown applies only to agent-input
  cues and previews. Automatic desktop and volume/power cues ignore it: a
  second workspace switch, volume change, or power change arriving after
  the previous cue's child process exited but while the cooldown window is
  still open plays normally. Their source state machines already
  deduplicate non-transitions, and the controller preempts a running voice,
  so a rapid same-name repeat cannot sound twice — it is only the post-exit
  gap that is no longer blocked.
- **Latest-only rapid replacement.** Rapid, otherwise-eligible **automatic
  non-agent** events (desktop and volume/power cues) preempt the current
  cue: the current cue is cut and the newest event is retained as a single
  latest-only pending replacement, which starts only after the old process
  has actually exited — never overlapping it. A further automatic event
  replaces that intent, so a burst of changes yields at most one final cue.
  A **preview** or an **agent cue** is never preempted (and never preempts
  another cue): the single voice stays strictly non-overlapping at all
  times. A deliberately cut cue's release does not arm the cooldown, so the
  cut cannot stall the agent-input cues and previews that still obey it.
- **Agent-input gating.** Automatic agent cues require: settings decided,
  master unmuted, `agentInputEnabled`, session safe (no DND, unlocked,
  non-idle, real screen, settled startup), observer ready, cooldown
  elapsed, voice free. They do **not** depend on desktop activation,
  ui-sounds overlap, or desktop adapter readiness.
- **Desktop gating.** Desktop cues additionally require `desktopEnabled`,
  no ui-sounds overlap, and desktop adapter readiness.
- **System gating.** Volume/power cues use the same base policy (including
  `desktopEnabled` and no ui-sounds overlap) plus `systemReady`, the
  volume/power adapter's readiness. The adapter's two sources are
  independent: the volume source needs the default PipeWire sink baseline,
  the power source needs a UPower on-battery baseline, and each starts
  silently so the first settling/current state never sounds.
- **DND / lock / idle.** Any of these stops all playback and deactivates
  the adapters and observer; nothing that happened while inactive sounds on
  recovery.
- **Observer failure.** If the observer child fails, is missing, or hits
  backpressure, the adapter fails closed: no agent cue plays, and
  notification delivery, history, actions, and DND are untouched. The
  observer is restarted with a bounded delay while active; readiness is
  cleared before any stop/restart. Unload, disable, or hot reload stops
  the child; it also exits on owner changes or disconnect.
- **Freshness and ambiguity.** Only successful typed `Notify` replies are
  eligible. Valid replacements, failed/unmatched/stale calls, and events
  older than 250 ms stay silent. Per the approved issue #4 policy, an
  accepted notification whose reply id equals its `replaces_id` (a valid
  update or a genuinely new stale-id collision) stays silent — a genuinely
  new cue can be missed in that ambiguous case, by design.

## Agent classification (version-sensitive)

The supported agent contract is the installed Oh My Pi desktop fallback:
app label `Oh My Pi` with body `Waiting for input`, as of `omp/18.1.16`.
This is a version-sensitive wording match, not an authenticated identity —
app labels are classification hints only. Session titles are never used to
classify. Unrelated apps using the same wording, agent completion
notifications, ordinary notifications, and unknown payloads do not
trigger the cue. Typed sender sound-suppression hints are honored before
an eligible cue is emitted; an invalid suppression state fails closed
(silence). No notification contents are logged or persisted — only
normalized events cross into the controller.

## Dependencies

- `pipewire-audio` (`pw-play`) and the freedesktop sound theme
  (`sound-theme-freedesktop`) for desktop and system events.
- `python-dbus` and `python-gobject` for the observer child (installed
  versions 1.4.0-2 / 3.56.3-1; ordinary-user session monitoring needs no
  elevation or policy changes).
- The agent-input cue is a local plugin asset
  (`assets/agent-needs-input.wav`); see `UPSTREAM.json` for provenance and
  the full event-to-asset mapping.

## Verification prerequisites (maintainer-only)

`tests/service-safety.qml` is an **optional real-desktop integration
harness**, not a hermetic Node/unittest case. It exercises the real product
service with injected DND/lock/idle objects and the real notification bus —
not live host safety services — so it requires:

- a running Wayland session under **Hyprland**;
- the original **Omarchy notification service** (`omarchy.notifications`)
  present as the notification owner;
- the observer's **python-dbus** and **python-gobject** dependencies
  installed.

The harness is loaded by a thin wrapper `shell.qml` that launches
`qs -p <configdir>` with an isolated `XDG_CONFIG_HOME`. The parent launcher
**must create the isolated `XDG_CONFIG_HOME/omarchy` directory (seeding
settings is allowed) BEFORE loading the product**, because the service's
FileView cannot watch a missing parent. Never launch the harness against
the real user's XDG config. The harness drives the agent-input gate through
the isolated config's settings file and never touches the real desktop
state.

The harness is not a substitute for live-desktop verification of the 0.3.0
candidate: it exercises service-state safety transitions, not real-agent
playback, freshness, suppression, or observer lifecycle. Passing it does
not prove the v1→v2 migration (the harness seeds a complete v2 fixture).
For the current candidate, live default-sink volume changes were probed
via a source-loaded adapter (not an installed candidate) — see the
candidate verification summary above — while the physical power
plug/unplug transition and audible power-cue verification have **not**
been performed yet.

## Uninstall

`omarchy plugin remove nick.chime --yes` removes the plugin checkout and
disables it. Chime never edits other plugins, the bar layout, or the
notification service; disabling or removing it leaves Omarchy
notifications exactly as they were.
