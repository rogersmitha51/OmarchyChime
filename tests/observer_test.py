"""Regression tests for notification_observer.py.

The observer is exercised without any real bus: the message filters are
driven directly with constructed dbus.lowlevel messages (FakeCall
subclasses for Notify calls, duck-typed fakes for replies, real
SignalMessages with an authenticated sender for owner-change). No bus
connection is ever opened.

Runner: python3 -m unittest discover -s tests -p 'observer_test.py'
"""

import os
import sys
import unittest

import dbus
import dbus.lowlevel

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import notification_observer as obs  # noqa: E402

NOTIFY_SIG = "susssasa{sv}i"


class FakeCall(dbus.lowlevel.MethodCallMessage):
    """A Notify method call with a controllable serial and sender.

    The C-level serial of a never-sent message is 0, so the Python
    get_serial()/get_sender() overrides are what the observer sees.
    """

    def __init__(self, serial, sender=":1.5", app="Oh My Pi", title="Waiting for input",
                 body="Waiting for input",
                 replaces=0, hints=None, timeout=-1, destination=None, path=None):
        # app/body defaults are arbitrary: the observer never classifies
        # notification contents.
        super().__init__("org.freedesktop.Notifications",
                         "/org/freedesktop/Notifications",
                         "org.freedesktop.Notifications", "Notify")
        self._serial = serial
        self._sender = sender
        if destination is not None:
            self.set_destination(destination)
        if path is not None:
            self.set_path(path)
        self.append(app, replaces, title, "s", body, [], hints or {}, timeout,
                    signature=NOTIFY_SIG)

    def get_serial(self):
        return self._serial

    def get_sender(self):
        return self._sender


class FakeReply:
    """Duck-typed method-return / error message for the observer filter."""

    def __init__(self, mtype, caller, reply_serial, sender=":1.1",
                 signature="u", args=None, error_name=None):
        self._type = mtype
        self._caller = caller
        self._reply_serial = reply_serial
        self._sender = sender
        self._signature = signature
        self._args = args if args is not None else []
        self._error_name = error_name

    def get_type(self):
        return self._type

    def get_destination(self):
        return self._caller

    def get_reply_serial(self):
        return self._reply_serial

    def get_sender(self):
        return self._sender

    def get_signature(self):
        return self._signature

    def get_args_list(self):
        return list(self._args)

    def get_error_name(self):
        return self._error_name


class ObserverTestBase(unittest.TestCase):
    def setUp(self):
        self.events = []
        self.errors = []
        self.observer = obs.Observer(
            emit=lambda obj: self.events.append(obj) if obj.get("type") == "event"
            else self.errors.append(obj) if obj.get("type") == "error"
            else self.events.append(obj))
        self.observer._owner = ":1.1"

    def notify(self, serial=10, sender=":1.5", **kwargs):
        call = FakeCall(serial, sender=sender, **kwargs)
        self.observer.on_message(None, call)
        return call

    def reply(self, call, nid, sender=":1.1"):
        self.observer.on_message(None, FakeReply(
            dbus.lowlevel.MESSAGE_TYPE_METHOD_RETURN, call.get_sender(),
            call.get_serial(), sender=sender, args=[dbus.UInt32(nid)]))

    def error_reply(self, call, sender=":1.1"):
        self.observer.on_message(None, FakeReply(
            dbus.lowlevel.MESSAGE_TYPE_ERROR, call.get_sender(),
            call.get_serial(), sender=sender,
            signature="s", args=["boom"],
            error_name="org.freedesktop.Notifications.Error.Failed"))

    def owner_change(self, new_owner, sender="org.freedesktop.DBus"):
        """A real NameOwnerChanged signal with an authenticated sender."""
        signal = dbus.lowlevel.SignalMessage(
            "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameOwnerChanged")
        signal.set_sender(sender)
        signal.append("org.freedesktop.Notifications", ":1.1", new_owner,
                      signature="sss")
        return signal

    def event_types(self):
        return [e.get("event") for e in self.events if e.get("type") == "event"]


class ClassificationTests(ObserverTestBase):
    def test_exact_match_emits(self):
        call = self.notify()
        self.reply(call, 42)
        self.assertEqual(self.event_types(), ["notificationReceived"])

    def test_unrelated_app_emits(self):
        call = self.notify(app="Other App")
        self.reply(call, 42)
        self.assertEqual(self.event_types(), ["notificationReceived"])

    def test_unrelated_body_emits(self):
        call = self.notify(body="Different body")
        self.reply(call, 42)
        self.assertEqual(self.event_types(), ["notificationReceived"])

    def test_empty_and_arbitrary_contents_emit(self):
        # The cue is universal: arbitrary app/title/body never disqualify.
        for app, title, body in [("", "", ""), ("Web Browser", "Inbox", "You have mail")]:
            call = self.notify(app=app, title=title, body=body)
            self.reply(call, 42)
        self.assertEqual(self.event_types(), ["notificationReceived", "notificationReceived"])

    def test_wrong_signature_ignored(self):
        msg = dbus.lowlevel.MethodCallMessage(
            "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
            "org.freedesktop.Notifications", "Notify")
        msg.append("Oh My Pi", 0, "", "s", "Waiting for input", [], {},
                   signature="susssasa{sv}")
        self.observer.on_message(None, msg)
        self.assertEqual(self.observer.pending_count(), 0)

    def test_wrong_path_ignored(self):
        msg = dbus.lowlevel.MethodCallMessage(
            "org.freedesktop.Notifications", "/org/freedesktop/Other",
            "org.freedesktop.Notifications", "Notify")
        msg.append("Oh My Pi", 0, "", "s", "Waiting for input", [], {}, -1,
                   signature=NOTIFY_SIG)
        self.observer.on_message(None, msg)
        self.assertEqual(self.observer.pending_count(), 0)

    def test_wrong_destination_ignored(self):
        call = self.notify(destination=":1.77")
        self.reply(call, 42)
        self.assertEqual(self.event_types(), [])
        self.assertEqual(self.observer.pending_count(), 0)


class SuppressionTests(ObserverTestBase):
    def test_boolean_true_suppresses(self):
        call = self.notify(hints={"suppress-sound": dbus.Boolean(True)})
        self.reply(call, 42)
        self.assertEqual(self.event_types(), [])

    def test_boolean_false_emits(self):
        call = self.notify(hints={"suppress-sound": dbus.Boolean(False)})
        self.reply(call, 42)
        self.assertEqual(self.event_types(), ["notificationReceived"])

    def test_python_bool_true_suppresses(self):
        call = self.notify(hints={"suppress-sound": True})
        self.reply(call, 42)
        self.assertEqual(self.event_types(), [])

    def test_string_hint_fails_closed(self):
        call = self.notify(hints={"suppress-sound": "true"})
        self.reply(call, 42)
        self.assertEqual(self.event_types(), [])

    def test_int_hint_fails_closed(self):
        call = self.notify(hints={"suppress-sound": 1})
        self.reply(call, 42)
        self.assertEqual(self.event_types(), [])

    def test_absent_hint_emits(self):
        call = self.notify(hints={})
        self.reply(call, 42)
        self.assertEqual(self.event_types(), ["notificationReceived"])

    def test_unknown_hint_ignored(self):
        call = self.notify(hints={"urgency": dbus.Byte(1)})
        self.reply(call, 42)
        self.assertEqual(self.event_types(), ["notificationReceived"])


class ReplyPolicyTests(ObserverTestBase):
    def test_replaces_zero_emits(self):
        call = self.notify(replaces=0)
        self.reply(call, 42)
        self.assertEqual(self.event_types(), ["notificationReceived"])

    def test_id_differs_from_replaces_emits(self):
        call = self.notify(replaces=7)
        self.reply(call, 42)
        self.assertEqual(self.event_types(), ["notificationReceived"])

    def test_id_equals_replaces_silent(self):
        call = self.notify(replaces=42)
        self.reply(call, 42)
        self.assertEqual(self.event_types(), [])

    def test_zero_id_reply_silent(self):
        call = self.notify()
        self.reply(call, 0)
        self.assertEqual(self.event_types(), [])
        self.assertEqual(self.observer.pending_count(), 0)

    def test_error_reply_silent_and_clears(self):
        call = self.notify()
        self.error_reply(call)
        self.assertEqual(self.event_types(), [])
        self.assertEqual(self.observer.pending_count(), 0)

    def test_unmatched_reply_silent(self):
        self.observer.on_message(None, FakeReply(
            dbus.lowlevel.MESSAGE_TYPE_METHOD_RETURN, ":1.99", 999,
            args=[dbus.UInt32(1)]))
        self.assertEqual(self.event_types(), [])

    def test_wrong_reply_signature_silent(self):
        call = self.notify()
        self.observer.on_message(None, FakeReply(
            dbus.lowlevel.MESSAGE_TYPE_METHOD_RETURN, call.get_sender(),
            call.get_serial(), signature="s", args=["x"]))
        self.assertEqual(self.event_types(), [])
        self.assertEqual(self.observer.pending_count(), 0)

    def test_reply_from_wrong_sender_silent(self):
        call = self.notify()
        self.reply(call, 42, sender=":1.77")
        self.assertEqual(self.event_types(), [])

    def test_suppressed_call_not_recorded(self):
        call = self.notify(hints={"suppress-sound": True})
        self.assertEqual(self.observer.pending_count(), 0)

    def test_caller_serial_isolation(self):
        # The same serial from two callers: each reply resolves only its own
        # caller's entry.
        first = self.notify(serial=10, sender=":1.5")
        second = self.notify(serial=10, sender=":1.6")
        self.assertEqual(self.observer.pending_count(), 2)
        self.reply(first, 42)
        self.assertEqual(self.event_types(), ["notificationReceived"])
        self.assertEqual(self.observer.pending_count(), 1)
        self.reply(second, 43)
        self.assertEqual(self.event_types(), ["notificationReceived", "notificationReceived"])
        self.assertEqual(self.observer.pending_count(), 0)


class ExpiryTests(ObserverTestBase):
    def test_expired_reply_before_tick_silent(self):
        # The entry is past its deadline but no expire() sweep has run; the
        # reply itself must reject it (freshness is not left to the 1s tick).
        self.observer._now = lambda: 1000.0
        call = self.notify()
        self.observer._now = lambda: 1000.0 + obs.PENDING_TTL_SECONDS + 0.1
        self.reply(call, 42)
        self.assertEqual(self.event_types(), [])
        self.assertEqual(self.observer.pending_count(), 0)

    def test_expire_sweep_removes_stale(self):
        self.observer._now = lambda: 1000.0
        call = self.notify()
        self.assertEqual(self.observer.pending_count(), 1)
        self.observer._now = lambda: 1000.0 + obs.PENDING_TTL_SECONDS + 0.1
        self.observer.expire()
        self.assertEqual(self.observer.pending_count(), 0)
        self.reply(call, 42)
        self.assertEqual(self.event_types(), [])

    def test_bounds_eviction(self):
        for i in range(obs.MAX_PENDING + 10):
            self.notify(serial=1000 + i, sender=":1.%d" % (i + 1))
        self.assertEqual(self.observer.pending_count(), obs.MAX_PENDING)

    def test_evicted_entry_cannot_emit(self):
        first = self.notify(serial=1000, sender=":1.5")
        for i in range(obs.MAX_PENDING):
            self.notify(serial=2000 + i, sender=":1.%d" % (i + 2))
        self.assertEqual(self.observer.pending_count(), obs.MAX_PENDING)
        self.reply(first, 42)
        self.assertEqual(self.event_types(), [])


class OwnerChangeTests(ObserverTestBase):
    def test_owner_change_clears_pending(self):
        self.notify()
        self.assertEqual(self.observer.pending_count(), 1)
        self.observer.on_control_message(None, self.owner_change(":1.9"))
        self.assertEqual(self.observer.pending_count(), 0)
        self.assertEqual([e.get("code") for e in self.errors], [obs.ERROR_OWNER_CHANGED])

    def test_owner_change_on_monitor_connection(self):
        # The monitor filter observes the authenticated NameOwnerChanged
        # signal too, ordered with Notify calls and replies.
        self.notify()
        self.observer.on_message(None, self.owner_change(":1.9"))
        self.assertEqual(self.observer.pending_count(), 0)
        self.assertEqual([e.get("code") for e in self.errors], [obs.ERROR_OWNER_CHANGED])

    def test_owner_change_then_late_reply_silent(self):
        call = self.notify()
        self.observer.on_message(None, self.owner_change(":1.9"))
        self.reply(call, 42)
        self.assertEqual(self.event_types(), [])
        self.assertEqual(self.observer.pending_count(), 0)

    def test_reply_after_disconnect_silent(self):
        call = self.notify()
        self.observer.on_disconnect(None)
        self.reply(call, 42)
        self.assertEqual(self.event_types(), [])
        self.assertEqual([e.get("code") for e in self.errors], [obs.ERROR_DISCONNECTED])

    def test_unauthenticated_owner_change_ignored(self):
        # A NameOwnerChanged signal not from org.freedesktop.DBus is not
        # accepted on the monitor connection.
        self.notify()
        self.observer.on_message(None, self.owner_change(":1.9", sender=":1.99"))
        self.assertEqual(self.errors, [])
        self.assertEqual(self.observer.pending_count(), 1)

    def test_owner_change_other_name_ignored(self):
        self.notify()
        signal = dbus.lowlevel.SignalMessage(
            "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameOwnerChanged")
        signal.set_sender("org.freedesktop.DBus")
        signal.append("org.example.Other", ":1.1", ":1.9", signature="sss")
        self.observer.on_control_message(None, signal)
        self.assertEqual(self.errors, [])
        self.assertEqual(self.observer.pending_count(), 1)


class BackpressureTests(ObserverTestBase):
    def test_backpressure_fails_closed(self):
        class BlockingStdout:
            def fileno(self):
                return 3

        observer = obs.Observer()
        observer._out_fd = 3
        real_write = os.write

        def blocking_write(fd, data):
            raise BlockingIOError(11, "would block")

        os.write = blocking_write
        try:
            observer.emit({"type": "ready"})
        finally:
            os.write = real_write
        self.assertTrue(observer._exited)
        self.assertEqual(observer._exit_code, 1)


if __name__ == "__main__":
    unittest.main()
