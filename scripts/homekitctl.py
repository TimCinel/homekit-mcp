#!/usr/bin/env python3

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


DEFAULT_SERVER = os.environ.get("HOMEKIT_MCP_URL", "http://localhost:8080")


def post_json(base_url: str, path: str, body: dict) -> dict:
    url = urllib.parse.urljoin(base_url.rstrip("/") + "/", path.lstrip("/"))
    data = json.dumps(body).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(request) as response:
            payload = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        message = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(f"Server returned HTTP {exc.code}: {message}") from exc
    except urllib.error.URLError as exc:
        raise SystemExit(f"Request failed: {exc.reason}") from exc

    try:
        return json.loads(payload)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON response: {exc}") from exc


def render_response(payload: dict, output_json: bool) -> None:
    if output_json:
        print(json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False))
        return

    error = payload.get("error")
    if isinstance(error, dict) and error.get("message"):
        raise SystemExit(str(error["message"]))

    result = payload.get("result")
    if isinstance(result, dict):
        content = result.get("content")
        if isinstance(content, list):
            parts = [item.get("text") for item in content if isinstance(item, dict) and item.get("text")]
            if parts:
                print("\n\n".join(parts))
                return

        tools = result.get("tools")
        if isinstance(tools, list):
            for tool in tools:
                if not isinstance(tool, dict):
                    continue
                print(tool.get("name", "<unknown>"))
                description = tool.get("description")
                if description:
                    print(f"  {description}")
                schema = tool.get("inputSchema")
                required = schema.get("required") if isinstance(schema, dict) else None
                if required:
                    print(f"  required: {', '.join(required)}")
            return

    print(json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False))


def call_tool(base_url: str, tool_name: str, arguments: dict) -> dict:
    return post_json(
        base_url,
        "/mcp/tools/call",
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": tool_name,
                "arguments": arguments,
            },
        },
    )


def parse_key_values(items: list[str]) -> dict:
    parsed = {}
    for item in items:
        if "=" not in item:
            raise SystemExit(f"Expected key=value argument, got '{item}'")
        key, value = item.split("=", 1)
        parsed[key] = value
    return parsed


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="homekitctl",
        description="Lightweight CLI for the HomeKit MCP HTTP server.",
    )
    parser.add_argument(
        "--server",
        default=DEFAULT_SERVER,
        help="Server base URL. Defaults to HOMEKIT_MCP_URL or http://localhost:8080",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print raw JSON responses.",
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("tools", help="List available tools exposed by the server.")
    subparsers.add_parser("rooms", help="List all HomeKit rooms.")
    subparsers.add_parser("accessories", help="List all HomeKit accessories.")

    find_accessory = subparsers.add_parser("find-accessory", help="Find an accessory by name.")
    find_accessory.add_argument("name")

    find_room = subparsers.add_parser("find-room", help="Find a room by name.")
    find_room.add_argument("name")

    room_accessories = subparsers.add_parser("room-accessories", help="List accessories in a room.")
    room_accessories.add_argument("room_name")

    move = subparsers.add_parser("move", help="Move an accessory to a room by names.")
    move.add_argument("accessory_name")
    move.add_argument("room_name")

    rename_accessory = subparsers.add_parser("rename-accessory", help="Rename an accessory.")
    rename_accessory.add_argument("accessory_name")
    rename_accessory.add_argument("new_name")

    rename_room = subparsers.add_parser("rename-room", help="Rename a room.")
    rename_room.add_argument("room_name")
    rename_room.add_argument("new_name")

    for command_name, help_text in [
        ("on", "Turn an accessory on."),
        ("off", "Turn an accessory off."),
        ("toggle", "Toggle an accessory."),
    ]:
        parser_for_command = subparsers.add_parser(command_name, help=help_text)
        parser_for_command.add_argument("accessory_name")

    call = subparsers.add_parser("call", help="Call any tool with key=value arguments.")
    call.add_argument("tool_name")
    call.add_argument("params", nargs="*")

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    if args.command == "tools":
        payload = post_json(
            args.server,
            "/mcp/tools/list",
            {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}},
        )
    elif args.command == "rooms":
        payload = call_tool(args.server, "get_all_rooms", {})
    elif args.command == "accessories":
        payload = call_tool(args.server, "get_all_accessories", {})
    elif args.command == "find-accessory":
        payload = call_tool(args.server, "get_accessory_by_name", {"name": args.name})
    elif args.command == "find-room":
        payload = call_tool(args.server, "get_room_by_name", {"name": args.name})
    elif args.command == "room-accessories":
        payload = call_tool(args.server, "get_room_accessories", {"room_name": args.room_name})
    elif args.command == "move":
        payload = call_tool(
            args.server,
            "set_accessory_room_by_name",
            {"accessory_name": args.accessory_name, "room_name": args.room_name},
        )
    elif args.command == "rename-accessory":
        payload = call_tool(
            args.server,
            "rename_accessory",
            {"accessory_name": args.accessory_name, "new_name": args.new_name},
        )
    elif args.command == "rename-room":
        payload = call_tool(
            args.server,
            "rename_room",
            {"room_name": args.room_name, "new_name": args.new_name},
        )
    elif args.command == "on":
        payload = call_tool(args.server, "accessory_on", {"accessory_name": args.accessory_name})
    elif args.command == "off":
        payload = call_tool(args.server, "accessory_off", {"accessory_name": args.accessory_name})
    elif args.command == "toggle":
        payload = call_tool(args.server, "accessory_toggle", {"accessory_name": args.accessory_name})
    elif args.command == "call":
        payload = call_tool(args.server, args.tool_name, parse_key_values(args.params))
    else:
        raise SystemExit(f"Unknown command: {args.command}")

    render_response(payload, args.json)


if __name__ == "__main__":
    main()
