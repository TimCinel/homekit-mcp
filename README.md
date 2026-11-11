# HomeKit MCP — secure local preview

This draft replaces the unauthenticated HTTP server with an owner-only Unix socket
and an MCP **2026-07-28** stdio relay. It is deliberately **read-only**: only
`get_all_accessories` and `get_all_rooms` are exposed. There is no HomeKit mutation
code, network listener, API password, bearer token, telemetry, or automatic startup.

**Do not deploy until signed Catalyst sandbox and container-access checks pass.**
An unsigned compile and native tests do not establish actual HomeKit authorization.
This is a breaking security preview, not a drop-in update to the old HTTP API.
Read [the security assessment](docs/SECURITY-REVIEW.md) before use.

## Build and authorize

Use macOS with Xcode, an Apple Account/development team, and HomeKit configured.
Open `HomeKitSync.xcodeproj`, choose your own team under Signing & Capabilities,
and provision normally. Do not disable the sandbox or grant broad filesystem
access to work around a denied socket. The HomeKit entitlement and app sandbox
are required; the app starts stopped until the owner clicks Start Server.

Build-only verification, without launching or granting HomeKit access:

```sh
xcodebuild -project HomeKitSync.xcodeproj -scheme HomeKitSync \
  -destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO build
swift test
python3 -m unittest discover -s tests -v
```

If Xcode is installed but Command Line Tools are selected, set `DEVELOPER_DIR` for
these commands to the installed Xcode Developer directory; no global change needed.

## MCP connection

After signed validation and owner authorization, use a standard stdio MCP client:

```json
{
  "mcpServers": {
    "homekit": {
      "command": "python3",
      "args": ["/absolute/path/to/scripts/mcp_stdio.py"]
    }
  }
}
```

The client must support MCP 2026-07-28. Every request needs
`params._meta["io.modelcontextprotocol/protocolVersion"] = "2026-07-28"` and
`params._meta["io.modelcontextprotocol/clientCapabilities"] = {}`. `server/discover`
replaces `initialize`; older handshake-only clients are intentionally unsupported.
String and signed 64-bit integer IDs are supported (strings up to256 UTF-8 bytes).
Request frames are limited to64KiB and32 JSON nesting levels; responses to1MiB.

The app's socket is `<sandbox-home>/.homekit-mcp/s`. For the supplied bundle ID,
the relay defaults to
`~/Library/Containers/com.timcinel.homekitmcp1/Data/.homekit-mcp/s`.
If you change the bundle ID, explicitly pass the verified container socket via
`--socket`. The directory must be0700, the socket0600, and both owned by the user.
The server also checks the connecting effective UID. Container privacy access
from a terminal/SSH session must be verified; it is not guaranteed by native tests.

For remote use, run the stdio relay on the Mac through an already configured,
pinned-host SSH connection with BatchMode, StrictHostKeyChecking, ForwardAgent=no,
and ClearAllForwardings=yes. No TCP port forwarding or API token is needed.
Do not put account passwords or verification codes in MCP configuration.

Read-only convenience commands on the Mac:

```sh
python3 scripts/homekitctl.py discover
python3 scripts/homekitctl.py rooms
python3 scripts/homekitctl.py accessories
```

Home/room/device names are private, untrusted data. Keep returned inventories out
of public issues and logs. The relay does not retry requests after ambiguous errors.
The old HTTP routes, SSE endpoint, device controls, renames and bulk room-management
workflow are removed in this preview. Restoring writes needs a separate reviewed,
scoped owner-approval policy and actual HomeKit persistence verification.

The Unix socket protects against LAN clients, websites and different OS users.
It does **not** isolate the server from malicious software running as the same
Mac user or an administrator. See the documented runtime verification gates and
limitations; this project makes no claim that all possible vulnerabilities are gone.
