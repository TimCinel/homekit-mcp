# HomeKit MCP Server

[![GitHub Release](https://img.shields.io/github/v/release/TimCinel/homekit-mcp?style=for-the-badge)](https://github.com/TimCinel/homekit-mcp/releases)
[![GitHub Activity](https://img.shields.io/github/commit-activity/m/TimCinel/homekit-mcp?style=for-the-badge)](https://github.com/TimCinel/homekit-mcp/commits/main)
[![License](https://img.shields.io/github/license/TimCinel/homekit-mcp?style=for-the-badge)](LICENSE)
[![CI](https://img.shields.io/github/actions/workflow/status/TimCinel/homekit-mcp/ci.yml?style=for-the-badge&label=CI)](https://github.com/TimCinel/homekit-mcp/actions/workflows/ci.yml)

HTTP-based Model Context Protocol (MCP) server for HomeKit integration with Claude Code. Provides tools to list and manage HomeKit accessories and rooms.

This is implemented as a macOS app rather than a CLI tool because HomeKit requires a signed binary with proper entitlements that can only be achieved through an Xcode project.

## Features

- HomeKit integration for accessories and rooms
- Three core tools: list accessories, list rooms, move accessories between rooms  
- HTTP API with JSON-RPC 2.0 protocol
- Claude Code compatible MCP transport
- Local-only operation

## Prerequisites

- macOS 13.0+ with HomeKit setup
- Xcode (with Command Line Tools)
- Apple ID (free tier sufficient for development)
- HomeKit accessories configured in the Home app

## Quick Start

```bash
git clone https://github.com/TimCinel/HomeKitSync.git
cd HomeKitSync
make build
make run
```

The server will start on `http://localhost:8080`.

Add to Claude Code:
```bash
claude mcp add --transport http homekit http://localhost:8080/mcp
```

## Available Tools

| Tool | Description | Parameters |
|------|-------------|------------|
| `get_all_accessories` | List all HomeKit accessories with names, rooms, categories, and UUIDs | None |
| `get_all_rooms` | List all HomeKit rooms with names and UUIDs | None |
| `set_accessory_room` | Move an accessory to a different room using UUIDs | `accessory_uuid`, `room_uuid` |
| `get_accessory_by_name` | Find a HomeKit accessory by name | `name` |
| `get_room_by_name` | Find a HomeKit room by name | `name` |
| `set_accessory_room_by_name` | Move an accessory to a different room using names | `accessory_name`, `room_name` |
| `rename_accessory` | Rename a HomeKit accessory | `accessory_name`, `new_name` |
| `rename_room` | Rename a HomeKit room | `room_name`, `new_name` |
| `get_room_accessories` | Get all accessories in a specific room | `room_name` |
| `accessory_on` | Turn on an accessory (lights, switches) or open covers | `accessory_name` |
| `accessory_off` | Turn off an accessory (lights, switches) or close covers | `accessory_name` |
| `accessory_toggle` | Toggle an accessory between on/off or open/close | `accessory_name` |

## Development

### Testing

Full test suite (requires HomeKit):
```bash
make test
```

CI-friendly tests (no HomeKit dependency):
```bash
make test-ci
```

### Code Quality

```bash
make install-deps  # Install SwiftLint
make lint
make lint-fix      # Auto-fix issues
```

## API Reference

### HTTP Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/mcp` | MCP server discovery |
| `POST` | `/mcp/tools/list` | List available tools |
| `POST` | `/mcp/tools/call` | Execute tools |

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run tests (`make test-ci`) and linting (`make lint`)
5. Submit a pull request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Troubleshooting

**"No such module 'HomeKit'"**
- Ensure you're building for the correct target
- Verify Xcode is properly installed

**"App cannot run on the current OS version"**
- Check deployment target in Xcode project settings

**"HomeKit permissions denied"**
- Verify HomeKit entitlement is enabled
- Check Apple ID signing configuration

**Server not reachable**
- Ensure app is running and visible in Dock
- Verify server logs in Console.app (search for "MCP") or run `log stream --info --process $(ps aux | grep MCP | grep -v grep | awk '{ print $2 }')`
