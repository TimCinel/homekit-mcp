#!/usr/bin/env python3
"""MCP 2026-07-28 stdio relay to the signed app's owner-only Unix socket.

No HTTP, proxies, redirects, bearer tokens, subprocess tools, or device writes.
A remote client may run this script through passwordless SSH with host checking.
"""
import argparse
import json
import os
import selectors
import socket
import stat
import sys
import time

MAX_MESSAGE = 65536
MAX_RESPONSE = 1048576
DEFAULT_SOCKET = os.path.expanduser(
    '~/Library/Containers/com.timcinel.homekitmcp1/Data/.homekit-mcp/s')


def connect(path):
    parent, endpoint = os.lstat(os.path.dirname(path)), os.lstat(path)
    if not (stat.S_ISDIR(parent.st_mode) and parent.st_uid == os.geteuid()
            and stat.S_IMODE(parent.st_mode) == 0o700
            and stat.S_ISSOCK(endpoint.st_mode) and endpoint.st_uid == os.geteuid()
            and stat.S_IMODE(endpoint.st_mode) == 0o600):
        raise ValueError('Unsafe local socket permissions')
    channel = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        channel.settimeout(5)
        channel.connect(path)
        return channel
    except BaseException:
        channel.close()
        raise


def identifier(message):
    value = message.get('id')
    if ((isinstance(value, str) and len(value.encode('utf-8')) <= 256)
            or (type(value) is int and -(2**63) <= value < 2**63)):
        return (type(value), value)
    return None


def strict_json(payload):
    depth, quoted, escaped = 0, False, False
    for byte in payload:
        if quoted:
            if escaped: escaped = False
            elif byte == 92: escaped = True
            elif byte == 34: quoted = False
        elif byte == 34: quoted = True
        elif byte in (91, 123):
            depth += 1
            if depth > 32: raise ValueError('JSON nesting too deep')
        elif byte in (93, 125):
            depth -= 1
            if depth < 0: raise ValueError('Invalid JSON structure')
    def object_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result: raise ValueError('Duplicate JSON key')
            result[key] = value
        return result
    def reject_constant(_):
        raise ValueError('Invalid JSON number')
    value = json.loads(payload.decode('utf-8'), object_pairs_hook=object_pairs, parse_constant=reject_constant)
    # Reject escaped lone surrogates and finite-looking numbers that overflow to infinity.
    json.dumps(value, ensure_ascii=False, allow_nan=False).encode('utf-8')
    return value


def encode(message):
    return json.dumps(message, ensure_ascii=False, separators=(',', ':'), allow_nan=False).encode('utf-8') + b'\n'


def validate_response(payload, request_id):
    response = strict_json(payload)
    if (not isinstance(response, dict) or response.get('jsonrpc') != '2.0'
            or identifier(response) != request_id
            or ('result' in response) == ('error' in response)):
        raise ValueError('Invalid local response')
    return response


def request_once(path, message):
    payload = encode(message)
    if len(payload) - 1 > MAX_MESSAGE:
        raise ValueError('Request too large')
    with connect(path) as channel:
        deadline = time.monotonic() + 40
        channel.settimeout(40)
        channel.sendall(payload)
        data = bytearray()
        while b'\n' not in data:
            remaining = deadline - time.monotonic()
            if remaining <= 0: raise TimeoutError('Local request deadline exceeded')
            channel.settimeout(remaining)
            chunk = channel.recv(16384)
            if not chunk:
                raise ValueError('Local server disconnected')
            data.extend(chunk)
            if len(data) > MAX_RESPONSE + 1:
                raise ValueError('Response too large')
        line, extra = bytes(data).split(b'\n', 1)
        if extra:
            raise ValueError('Multiple local responses')
        return validate_response(line, identifier(message))


def relay(path):
    """Bounded multiplexing permits cancellation while other requests are in flight."""
    selector = selectors.DefaultSelector()
    selector.register(sys.stdin.buffer, selectors.EVENT_READ, None)
    pending = {}
    input_buffer = bytearray()
    eof = False

    def emit(message):
        sys.stdout.buffer.write(encode(message))
        sys.stdout.buffer.flush()

    def close(key):
        item = pending.pop(key, None)
        if item:
            selector.unregister(item['socket'])
            item['socket'].close()

    try:
        while not eof or pending:
            for event, _ in selector.select(timeout=0.1):
                if event.data is None:
                    chunk = os.read(sys.stdin.fileno(), 16384)
                    if not chunk:
                        selector.unregister(sys.stdin.buffer)
                        eof = True
                        # A closed input is shutdown, not authorization to finish queued work.
                        return
                    input_buffer.extend(chunk)
                    while b'\n' in input_buffer:
                        line, _, rest = input_buffer.partition(b'\n')
                        input_buffer[:] = rest
                        if not line or len(line) > MAX_MESSAGE:
                            raise ValueError('Invalid stdio frame')
                        try:
                            message = strict_json(line)
                        except (UnicodeError, ValueError):
                            emit({'jsonrpc': '2.0', 'error': {'code': -32700, 'message': 'Relay: parse error'}})
                            continue
                        if not isinstance(message, dict):
                            emit({'jsonrpc': '2.0', 'error': {'code': -32600, 'message': 'Relay: invalid request'}})
                            continue
                        key = identifier(message)
                        if 'id' not in message:
                            if message.get('method') == 'notifications/cancelled':
                                params = message.get('params', {})
                                if isinstance(params, dict):
                                    target = identifier({'id': params.get('requestId')})
                                    close(target)
                            continue  # Notifications never receive responses or authorize a tool call.
                        if key is None:
                            emit({'jsonrpc': '2.0', 'error': {'code': -32600, 'message': 'Relay: invalid request ID'}})
                            continue
                        if key in pending:
                            raise ValueError('Duplicate in-flight ID')
                        if len(pending) >= 8:
                            emit({'jsonrpc': '2.0', 'id': message['id'], 'error': {'code': -32603, 'message': 'Relay: too many in-flight requests'}})
                            continue
                        channel = connect(path)
                        try:
                            channel.sendall(bytes(line) + b'\n')
                            channel.setblocking(False)
                            pending[key] = {'socket': channel, 'data': bytearray(), 'deadline': time.monotonic() + 40}
                            selector.register(channel, selectors.EVENT_READ, key)
                        except BaseException:
                            channel.close()
                            raise
                    if len(input_buffer) > MAX_MESSAGE:
                        raise ValueError('Stdio frame too large')
                else:
                    key = event.data
                    if key not in pending:
                        continue
                    item = pending[key]
                    # A cancelled ID may have been reused after select() returned.
                    if item['socket'] is not event.fileobj:
                        continue
                    try:
                        chunk = item['socket'].recv(16384)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        raise ValueError('Local server disconnected before response')
                    item['data'].extend(chunk)
                    if len(item['data']) > MAX_RESPONSE + 1:
                        raise ValueError('Response too large')
                    if b'\n' in item['data']:
                        line, extra = bytes(item['data']).split(b'\n', 1)
                        if extra:
                            raise ValueError('Multiple local responses')
                        response = validate_response(line, key)
                        close(key)
                        emit(response)
            if any(time.monotonic() > item['deadline'] for item in pending.values()):
                raise TimeoutError('Local request timed out; do not automatically retry writes')
    finally:
        for key in list(pending):
            close(key)
        selector.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--socket', default=DEFAULT_SOCKET)
    args = parser.parse_args()
    try:
        relay(args.socket)
    except (OSError, ValueError, TimeoutError):
        print('MCP local relay failed; verify the signed app and socket permissions. No credentials were used.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
