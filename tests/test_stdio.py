import importlib.util
import io
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('mcp_stdio', Path(__file__).parents[1] / 'scripts/mcp_stdio.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class RelayTests(unittest.TestCase):
    def test_strict_json_rejects_hostile_values(self):
        for value in [b'{"id":"\\ud800"}', b'{"x":1e9999}', b'{"x":NaN}',
                      b'{"x":1,"x":2}', b'\xff', b'[' * 40 + b'0' + b']' * 40]:
            with self.subTest(value=value[:24]), self.assertRaises((ValueError, UnicodeError)):
                m.strict_json(value)

    def test_bounded_identifiers(self):
        for value in [True, None, 1.5, 2**63, 'x' * 257]:
            self.assertIsNone(m.identifier({'id': value}))
        for value in ['x', 0, -1, 2**63 - 1]:
            self.assertIsNotNone(m.identifier({'id': value}))

    def test_cross_request_response_rejected(self):
        for value in [{'jsonrpc': '2.0', 'id': 'wrong', 'result': {}},
                      {'jsonrpc': '2.0', 'id': 'x', 'result': {}, 'error': {}},
                      {'jsonrpc': '2.0', 'id': 'x'}]:
            with self.assertRaises(ValueError):
                m.validate_response(m.encode(value), (str, 'x'))

    def test_cancellation_reuse_ignores_stale_socket_event(self):
        old, new, selector = Mock(), Mock(), Mock()
        stdin = SimpleNamespace(buffer=io.BytesIO(), fileno=lambda: 0)
        output = io.BytesIO()
        request = m.encode({'jsonrpc': '2.0', 'id': 'x', 'method': 'ping'})
        cancellation = m.encode({'jsonrpc': '2.0', 'method': 'notifications/cancelled', 'params': {'requestId': 'x'}})
        selector.select.side_effect = [
            [(SimpleNamespace(data=None), 1)],
            [(SimpleNamespace(data=None), 1), (SimpleNamespace(data=(str, 'x'), fileobj=old), 1)],
            [(SimpleNamespace(data=(str, 'x'), fileobj=new), 1)],
            [(SimpleNamespace(data=None), 1)]]
        new.recv.return_value = m.encode({'jsonrpc': '2.0', 'id': 'x', 'result': {'resultType': 'complete'}})
        with patch.object(m.selectors, 'DefaultSelector', return_value=selector), \
             patch.object(m, 'connect', side_effect=[old, new]), \
             patch.object(m.os, 'read', side_effect=[request, cancellation + request, b'']), \
             patch.object(m.sys, 'stdin', stdin), \
             patch.object(m.sys, 'stdout', SimpleNamespace(buffer=output)):
            m.relay('unused')
        old.recv.assert_not_called()
        new.recv.assert_called_once()
        old.close.assert_called_once()
        self.assertEqual(json.loads(output.getvalue())['id'], 'x')

    def test_ninth_request_returns_overload_without_dropping_eight(self):
        selector = Mock()
        selector.select.side_effect = [[(SimpleNamespace(data=None), 1)], [(SimpleNamespace(data=None), 1)]]
        requests = b''.join(m.encode({'jsonrpc': '2.0', 'id': n, 'method': 'ping'}) for n in range(9))
        channels = [Mock() for _ in range(8)]
        output = io.BytesIO()
        with patch.object(m.selectors, 'DefaultSelector', return_value=selector), \
             patch.object(m, 'connect', side_effect=channels) as connect, \
             patch.object(m.os, 'read', side_effect=[requests, b'']), \
             patch.object(m.sys, 'stdin', SimpleNamespace(buffer=io.BytesIO(), fileno=lambda: 0)), \
             patch.object(m.sys, 'stdout', SimpleNamespace(buffer=output)):
            m.relay('unused')
        self.assertEqual(connect.call_count, 8)
        response = json.loads(output.getvalue())
        self.assertEqual(response['id'], 8)
        self.assertEqual(response['error']['code'], -32603)
        for channel in channels:
            channel.close.assert_called_once()

    def test_absolute_deadline_stops_dripping_server(self):
        channel = Mock()
        channel.__enter__ = Mock(return_value=channel)
        channel.__exit__ = Mock(return_value=False)
        channel.recv.return_value = b'{'
        with patch.object(m, 'connect', return_value=channel), \
             patch.object(m.time, 'monotonic', side_effect=[0, 10, 41]):
            with self.assertRaises(TimeoutError):
                m.request_once('unused', {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'})
        channel.recv.assert_called_once()

    def test_unsafe_socket_permissions_fail_before_connect(self):
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            os.chmod(directory, 0o755)
            path = Path(directory) / 's'
            path.touch(mode=0o600)
            with self.assertRaises(ValueError):
                m.connect(str(path))


if __name__ == '__main__':
    unittest.main()
