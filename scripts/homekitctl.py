#!/usr/bin/env python3
"""Read-only convenience client for the modern local MCP transport."""
import argparse
import json
from mcp_stdio import DEFAULT_SOCKET, request_once


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--socket', default=DEFAULT_SOCKET)
    parser.add_argument('command', choices=['discover', 'tools', 'rooms', 'accessories'])
    args = parser.parse_args()
    params = {'_meta': {'io.modelcontextprotocol/protocolVersion': '2026-07-28',
                       'io.modelcontextprotocol/clientCapabilities': {},
                       'io.modelcontextprotocol/clientInfo': {'name': 'homekitctl', 'version': '2.0.0'}}}
    method = {'discover': 'server/discover', 'tools': 'tools/list',
              'rooms': 'tools/call', 'accessories': 'tools/call'}[args.command]
    if args.command in ('rooms', 'accessories'):
        params.update(name='get_all_rooms' if args.command == 'rooms' else 'get_all_accessories', arguments={})
    try:
        response = request_once(args.socket, {'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params})
    except (OSError, ValueError):
        parser.exit(1, 'Local HomeKit request failed; verify the signed app and permissions.\n')
    print(json.dumps(response, indent=2, ensure_ascii=False))
    return int('error' in response)


if __name__ == '__main__':
    raise SystemExit(main())
