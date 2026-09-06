import importlib.util
from pathlib import Path
import socket
import time
import threading
import unittest

spec = importlib.util.spec_from_file_location("collector", Path(__file__).parents[1] / "collect-audio-diagnostics.py")
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class CollectorTests(unittest.TestCase):
    def test_skips_meter_frames_and_preserves_following_frame(self):
        reader, writer = socket.socketpair()
        with reader, writer:
            writer.sendall(b'{"t":"meter"}\n{"t":"diagnostics","audio":{"callbackCount":42}}\n{"t":"meter","n":2}\n')
            pending = bytearray()
            frame = collector.read_type(reader, pending, "diagnostics", time.monotonic() + 1)
            self.assertEqual(frame["audio"]["callbackCount"], 42)
            self.assertEqual(collector.read_type(reader, pending, "meter", time.monotonic() + 1)["n"], 2)

    def test_absolute_deadline_applies_even_with_buffered_other_frames(self):
        reader, writer = socket.socketpair()
        with reader, writer:
            with self.assertRaises(TimeoutError):
                collector.read_type(reader, bytearray(b'{"t":"meter"}\n'), "diagnostics", time.monotonic() - 1)

    def test_rejects_unterminated_oversized_frame(self):
        reader, writer = socket.socketpair()
        with reader, writer:
            writer.sendall(b"x")
            with self.assertRaisesRegex(RuntimeError, "exceeds"):
                collector.read_type(reader, bytearray(b"x" * (1024 * 1024)), "diagnostics", time.monotonic() + 1)

    def test_disconnect_is_reported(self):
        reader, writer = socket.socketpair()
        writer.close()
        with reader, self.assertRaisesRegex(RuntimeError, "disconnected"):
            collector.read_type(reader, bytearray(), "diagnostics", time.monotonic() + 1)

    def test_interval_drains_pushed_meters_instead_of_blocking_sender(self):
        reader, writer = socket.socketpair()
        with reader, writer:
            writer.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1024)
            writer.settimeout(2)
            completed = threading.Event()
            errors = []
            def send():
                try:
                    writer.sendall(b'{"t":"meter"}\n' * 1000)
                    completed.set()
                except OSError as error:
                    errors.append(error)
            thread = threading.Thread(target=send)
            thread.start()
            collector.drain_until(reader, bytearray(), time.monotonic() + 0.5)
            thread.join(timeout=2)
            self.assertTrue(completed.is_set())
            self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main()
