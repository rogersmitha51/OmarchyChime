#!/usr/bin/env python3
"""Passive typed D-Bus observer for the Omarchy Chime notification cue.

Runs as a child of the Quickshell plugin (NotificationEvents.qml). It
eavesdrops on the session bus with org.freedesktop.DBus.Monitoring
BecomeMonitor, using narrow match rules for org.freedesktop.Notifications
Notify calls (well-known and unique destinations) and the notification
server's successful/error replies. Each Notify call is correlated with its
reply by (caller unique name, serial) through a bounded, expiring pending
table; a notificationReceived event is emitted only for a fresh accepted
notification — a successful reply confirms the server actually accepted
it, and the notification's contents (app, title, body) are never consulted.

Privacy: notification contents are not used; only the suppress-sound hint
is classified. Nothing is logged or persisted. The output protocol is
newline-delimited JSON on stdout:

  {"type":"ready"}
  {"type":"event","event":"notificationReceived","timeMs":<epoch-ms>}
  {"type":"error","code":<fixed-token>}

The observer never owns org.freedesktop.Notifications, never sends
messages after BecomeMonitor, and exits fail-closed on owner change, bus
disconnect, or any internal failure. The QML adapter restarts it with a
bounded delay while active.

Freshness policy (approved in issue #4): a successful reply is eligible
only when replaces_id == 0 or the returned id differs from replaces_id.
Equal-ID cases (valid updates and stale-ID collisions alike) stay silent.
"""

import json
import os
import signal
import sys
import time

import dbus
import dbus.lowlevel

from gi.repository import GLib

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

NOTIFY_NAME = "org.freedesktop.Notifications"
NOTIFY_PATH = "/org/freedesktop/Notifications"
NOTIFY_IFACE = "org.freedesktop.Notifications"
NOTIFY_MEMBER = "Notify"
NOTIFY_SIGNATURE = "susssasa{sv}i"
REPLY_SIGNATURE = "u"

# Notification contents (app, title, body) are never used to classify; only
# the typed suppress-sound hint is.
SUPPRESS_HINT = "suppress-sound"

# Bounded pending correlation table: entries expire after this many seconds
# and the table is capped at this many entries (oldest evicted first).
PENDING_TTL_SECONDS = 10.0
MAX_PENDING = 256

BECOME_TIMEOUT_SECONDS = 10.0

# Fixed error tokens (no private data).
ERROR_OWNER_UNAVAILABLE = "owner-unavailable"
ERROR_BECOME_MONITOR_FAILED = "become-monitor-failed"
ERROR_OWNER_CHANGED = "owner-changed"
ERROR_DISCONNECTED = "disconnected"
ERROR_INTERNAL = "internal"


# --------------------------------------------------------------------------
# Observer
# --------------------------------------------------------------------------

class Observer:
    """Correlation and classification state for the monitor connection.

    The bus-facing parts (connections, BecomeMonitor, main loop) live in
    main(); this class is pure enough to be exercised without any bus, so
    the regression tests import the module without connecting.
    """

    def __init__(self, emit=None, now=time.monotonic):
        # `emit` is a callable taking a JSON-serializable dict; the default
        # writes newline-delimited JSON to stdout (nonblocking, fail closed).
        self._emit_fn = emit if emit is not None else self._emit_stdout
        self._now = now
        self._pending = {}
        self._owner = None
        self._loop = None
        self._exited = False
        self._exit_code = 0
        self._out_fd = None

    # -- output -----------------------------------------------------------

    def emit(self, obj):
        self._emit_fn(obj)

    def _emit_stdout(self, obj):
        line = (json.dumps(obj, separators=(",", ":")) + "\n").encode("utf-8")
        self._write(line)

    def _write(self, data):
        fd = self._out_fd
        if fd is None:
            return
        try:
            while data:
                written = os.write(fd, data)
                if written <= 0:
                    self._exit(1)
                    return
                data = data[written:]
        except BlockingIOError:
            # Backpressure on stdout: fail closed rather than queue output.
            self._exit(1)
        except BrokenPipeError:
            # Parent is gone; nothing left to tell.
            self._exit(0)
        except OSError:
            self._exit(1)

    def _emit_event(self):
        self.emit({
            "type": "event",
            "event": "notificationReceived",
            "timeMs": int(time.time() * 1000),
        })

    def _fail(self, code):
        if self._exited:
            return
        # Fail closed: drop all correlation state on any fatal error.
        self._pending.clear()
        self.emit({"type": "error", "code": code})
        self._exit(1)

    def _exit(self, code):
        if self._exited:
            return
        self._exited = True
        self._exit_code = code
        if self._loop is not None:
            self._loop.quit()

    # -- lifecycle callbacks ----------------------------------------------

    def on_disconnect(self, connection):
        self._fail(ERROR_DISCONNECTED)

    def on_signal(self, signum):
        self._exit(0)
        return GLib.SOURCE_REMOVE

    def expire_tick(self):
        self.expire()
        return GLib.SOURCE_CONTINUE

    # -- message filters ---------------------------------------------------

    def _on_owner_changed(self, name, new_owner):
        """Fail closed when the notification name's owner changes or is lost."""
        if self._exited:
            return
        if name == NOTIFY_NAME and new_owner != self._owner:
            self._fail(ERROR_OWNER_CHANGED)

    def on_control_message(self, connection, message):
        """Filter for the read-only control connection.

        Watches NameOwnerChanged for the notification name so an owner
        change (including loss of the name) is detected from before the
        monitor is installed, closing the startup race.
        """
        if message.get_type() == dbus.lowlevel.MESSAGE_TYPE_SIGNAL:
            if (message.get_interface() == "org.freedesktop.DBus"
                    and message.get_member() == "NameOwnerChanged"):
                args = message.get_args_list()
                if len(args) == 3:
                    self._on_owner_changed(str(args[0]), str(args[2]))
                return dbus.lowlevel.HANDLER_RESULT_HANDLED
        return dbus.lowlevel.HANDLER_RESULT_NOT_YET_HANDLED

    def on_message(self, connection, message):
        """Filter for the monitor connection: Notify calls, replies, and
        owner-change signals.

        The monitor connection observes the authenticated
        org.freedesktop.DBus NameOwnerChanged signal too, ordered with
        Notify calls and replies in this single filter, so an owner change
        can never race a delayed control dispatch: the change is processed
        in arrival order and fails the observer closed.
        """
        mtype = message.get_type()
        if mtype == dbus.lowlevel.MESSAGE_TYPE_SIGNAL:
            if (message.get_sender() == "org.freedesktop.DBus"
                    and message.get_path() == "/org/freedesktop/DBus"
                    and message.get_interface() == "org.freedesktop.DBus"
                    and message.get_member() == "NameOwnerChanged"
                    and message.get_signature() == "sss"):
                args = message.get_args_list()
                if len(args) == 3:
                    self._on_owner_changed(str(args[0]), str(args[2]))
                return dbus.lowlevel.HANDLER_RESULT_HANDLED
            return dbus.lowlevel.HANDLER_RESULT_NOT_YET_HANDLED
        if mtype == dbus.lowlevel.MESSAGE_TYPE_METHOD_CALL:
            if (message.get_interface() == NOTIFY_IFACE
                    and message.get_member() == NOTIFY_MEMBER):
                self._on_notify_call(message)
                return dbus.lowlevel.HANDLER_RESULT_HANDLED
            return dbus.lowlevel.HANDLER_RESULT_NOT_YET_HANDLED
        if mtype == dbus.lowlevel.MESSAGE_TYPE_METHOD_RETURN:
            self._on_reply(message)
            return dbus.lowlevel.HANDLER_RESULT_HANDLED
        if mtype == dbus.lowlevel.MESSAGE_TYPE_ERROR:
            self._on_error(message)
            return dbus.lowlevel.HANDLER_RESULT_HANDLED
        return dbus.lowlevel.HANDLER_RESULT_NOT_YET_HANDLED

    # -- correlation -------------------------------------------------------

    def _on_notify_call(self, message):
        if self._exited:
            return
        if message.get_signature() != NOTIFY_SIGNATURE:
            return
        # Exact path and destination validation: only the canonical
        # notification object and the well-known name (or the resolved
        # owner's unique name) are in scope.
        if message.get_path() != NOTIFY_PATH:
            return
        destination = message.get_destination()
        if destination not in (NOTIFY_NAME, self._owner):
            return
        args = message.get_args_list()
        if len(args) != 8:
            return
        sender = message.get_sender()
        serial = message.get_serial()
        if not sender or not serial:
            return
        if not self.isNotificationEvent(args[6]):
            # Suppressed (or a malformed suppression hint that fails closed):
            # never record it, so a later reply can never turn it into an
            # event.
            return
        self._store_pending(sender, serial, int(args[1]))

    def _on_reply(self, message):
        if self._exited:
            return
        caller = message.get_destination()
        reply_serial = message.get_reply_serial()
        if not caller or not reply_serial:
            return
        if message.get_sender() != self._owner:
            return
        # The correlation is resolved by the reply itself: consume the entry
        # even when the payload is malformed, so a bad reply can never leave
        # a stale entry behind.
        entry = self._pending.pop((caller, reply_serial), None)
        if entry is None:
            return
        # Freshness is decided by the stored deadline against the current
        # clock, not by the 1s expire timer: a reply that arrives after the
        # entry expired must never emit, even between sweeps.
        if entry["deadline"] <= self._now():
            return
        if message.get_signature() != REPLY_SIGNATURE:
            return
        args = message.get_args_list()
        if len(args) != 1:
            return
        nid = int(args[0])
        if nid == 0:
            # A zero id is not a valid notification id; never emit for it.
            return
        replaces = entry["replaces"]
        if replaces == 0:
            self._emit_event()
        elif nid != replaces:
            # Genuinely new accepted notification (e.g. a stale-ID collision
            # that allocated a fresh id): eligible.
            self._emit_event()
        # else: reply_id == replaces_id != 0. Ambiguous between a valid
        # update and a stale-ID collision; stays silent per the approved
        # fail-closed policy (issue #4).

    def _on_error(self, message):
        if self._exited:
            return
        caller = message.get_destination()
        reply_serial = message.get_reply_serial()
        if not caller or not reply_serial:
            return
        if message.get_sender() != self._owner:
            return
        self._pending.pop((caller, reply_serial), None)

    def _store_pending(self, sender, serial, replaces):
        key = (sender, serial)
        self._pending[key] = {
            "replaces": replaces,
            "deadline": self._now() + PENDING_TTL_SECONDS,
        }
        while len(self._pending) > MAX_PENDING:
            self._pending.pop(next(iter(self._pending)))

    def expire(self, now=None):
        if now is None:
            now = self._now()
        stale = [key for key, entry in self._pending.items()
                 if entry["deadline"] <= now]
        for key in stale:
            del self._pending[key]

    def pending_count(self):
        return len(self._pending)

    # -- classification ----------------------------------------------------

    def isNotificationEvent(self, hints):
        """True for a well-formed, non-suppressed Notify call.

        Notification contents are never used to classify: any well-formed
        canonical Notify call is eligible regardless of app title or body. A
        boolean true suppress-sound hint (or any malformed suppression hint
        type) fails closed to not-eligible. Unknown hints are ignored. A
        non-dict hints value is itself malformed and fails closed.
        """
        try:
            if hints is not None:
                if SUPPRESS_HINT in hints:
                    value = hints[SUPPRESS_HINT]
                    if isinstance(value, (bool, dbus.Boolean)):
                        if bool(value):
                            return False
                    else:
                        # Malformed suppression hint: fail closed.
                        return False
        except Exception:
            return False
        return True


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def _install_signal_handlers(observer):
    # GLib invokes the callback with no arguments (user_data is optional);
    # accept and ignore any extras so SIGTERM/SIGINT cannot raise TypeError.
    def handler(*unused):
        observer._exit(0)
        return GLib.SOURCE_REMOVE

    try:
        from gi.repository import GLibUnix
        add = GLibUnix.signal_add
    except Exception:
        add = GLib.unix_signal_add
    for sig in (signal.SIGTERM, signal.SIGINT):
        # A failure here must propagate: an observer that cannot be signalled
        # cleanly is unkillable, so fail closed instead of running on.
        add(GLib.PRIORITY_DEFAULT, sig, handler)


def main(argv=None):
    from dbus.mainloop.glib import DBusGMainLoop

    loop = GLib.MainLoop()
    observer = Observer()
    observer._loop = loop

    try:
        fd = sys.stdout.fileno()
        os.set_blocking(fd, False)
        observer._out_fd = fd
    except (OSError, AttributeError, ValueError):
        observer._out_fd = None

    control = None
    monitor = None
    try:
        # Signal-handler setup failure must fail closed (token, clean exit),
        # never leave an unkillable process and never print a traceback.
        _install_signal_handlers(observer)

        control = dbus.bus.BusConnection(dbus.bus.BUS_SESSION, mainloop=DBusGMainLoop())
        # dbus-python exits the process on disconnect by default; disable that
        # so the fail-closed on_disconnect path (error token + clean exit) runs.
        control.set_exit_on_disconnect(False)
        control.call_on_disconnection(observer.on_disconnect)
        control.add_match_string(
            "type='signal',sender='org.freedesktop.DBus',"
            "interface='org.freedesktop.DBus',member='NameOwnerChanged',"
            "arg0='org.freedesktop.Notifications'"
        )
        control.add_message_filter(observer.on_control_message)

        # Resolve the current owner before installing the monitor so the
        # unique-name filter is correct from the start.
        owner = control.get_name_owner(NOTIFY_NAME)
        if not owner or not str(owner).startswith(":"):
            observer._fail(ERROR_OWNER_UNAVAILABLE)
            return 1
        observer._owner = str(owner)

        # Monitor connection: becomes a monitor and can no longer send.
        monitor = dbus.bus.BusConnection(dbus.bus.BUS_SESSION, mainloop=DBusGMainLoop())
        monitor.set_exit_on_disconnect(False)
        monitor.call_on_disconnection(observer.on_disconnect)
        monitor.add_message_filter(observer.on_message)

        rules = [
            "type='method_call',interface='org.freedesktop.Notifications',"
            "member='Notify',path='%s',destination='org.freedesktop.Notifications'"
            % NOTIFY_PATH,
            "type='method_call',interface='org.freedesktop.Notifications',"
            "member='Notify',path='%s',destination='%s'"
            % (NOTIFY_PATH, observer._owner),
            "type='method_return',sender='%s'" % observer._owner,
            "type='error',sender='%s'" % observer._owner,
            # Owner-change signals on the monitor connection too, so the
            # change is processed in arrival order with Notify/replies.
            "type='signal',sender='org.freedesktop.DBus',"
            "path='/org/freedesktop/DBus',"
            "interface='org.freedesktop.DBus',member='NameOwnerChanged',"
            "arg0='org.freedesktop.Notifications'",
        ]
        become = dbus.lowlevel.MethodCallMessage(
            dbus.bus.BUS_DAEMON_NAME, dbus.bus.BUS_DAEMON_PATH,
            "org.freedesktop.DBus.Monitoring", "BecomeMonitor"
        )
        become.append(rules, dbus.UInt32(0), signature="asu")
        # Positional timeout: the installed dbus-python rejects the
        # timeout_s= keyword.
        reply = monitor.send_message_with_reply_and_block(
            become, BECOME_TIMEOUT_SECONDS)
        if reply.get_type() == dbus.lowlevel.MESSAGE_TYPE_ERROR:
            observer._fail(ERROR_BECOME_MONITOR_FAILED)
            return 1

        # Close the owner-change startup race: the owner must still be the
        # one the filters were installed for. Any change during BecomeMonitor
        # is caught here (before ready) and by the queued NameOwnerChanged
        # signal.
        current = control.get_name_owner(NOTIFY_NAME)
        if current != observer._owner:
            observer._fail(ERROR_OWNER_CHANGED)
            return 1

        # Backpressure on stdout may have already failed the observer closed
        # (e.g. the ready line could not be written); never start the loop for
        # an exited observer.
        if observer._exited:
            return observer._exit_code

        GLib.timeout_add_seconds(1, observer.expire_tick)

        observer.emit({"type": "ready"})

        # The ready line itself can hit stdout backpressure and fail the
        # observer closed; never enter the loop for an exited observer.
        if observer._exited:
            return observer._exit_code

        loop.run()
        return observer._exit_code
    except dbus.DBusException as exc:
        # Fixed internal token only: never leak the bus error details.
        if exc.get_dbus_name() == "org.freedesktop.DBus.Error.NameHasNoOwner":
            observer._fail(ERROR_OWNER_UNAVAILABLE)
        else:
            observer._fail(ERROR_INTERNAL)
        return 1
    except Exception:
        observer._fail(ERROR_INTERNAL)
        return 1
    finally:
        # Intentional shutdown (or a fatal path that already failed closed):
        # mark the observer exited before closing the connections so the
        # resulting disconnection callbacks cannot emit a spurious
        # "disconnected" error. The monitor connection is read-only after
        # BecomeMonitor, so closing is safe.
        observer._exit(0)
        for conn in (monitor, control):
            if conn is not None:
                try:
                    conn.close()
                except Exception:
                    pass

    return observer._exit_code


if __name__ == "__main__":
    sys.exit(main())
