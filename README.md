# HomeKit room editor and MCP security preview

The Mac-local room editor imports Home Assistant names and areas, matches them to
one selected HomeKit home, and prepares a reviewable room plan. HomeKit data and
recovery records remain on the Mac. Existing destination rooms bind exact UUIDs;
missing rooms are created separately before a new reviewed plan can run. A pilot
move, sequential assignments, refreshed inventory verification and scoped recovery
replace the previous bulk substring-based mutations.

**Not yet validated for production deployment.** Signed authorization, a verified
pilot and recovery on a real home remain required gates. Do not equate passing
unit tests, a signed build, or certificate creation with verified room changes.
Read [the security review](docs/SECURITY-REVIEW.md) and
[Apple licensing constraints](docs/APPLE-TERMS.md).

The secure MCP2026-07-28 protocol core and read-only inventory transport remain
available for local development, but the default app does **not** start them.
There are no TCP listeners or remote room-write tools. Do not use the inventory
relay to export HomeKit information off the Apple device. See Apple's restrictions.

## Local room workflow

1. Sign and provision normally; launch on the Mac and connect through its HomeKit
   permission prompt. Select exactly one home.
2. Import HA-only JSON schema2 (`items` contain `sourceID`, `names`, `targetRoom`).
   `sourceID` is a stable opaque HA device identity, never a HomeKit ID or credential.
3. Review home/accessory IDs and room targets. Generic names, shared aliases and
   conflicting HA source/area matches are excluded. Failed imports invalidate old plans.
4. If needed, create the missing destination rooms, then review the refreshed plan.
5. Move one item first. Verify its result before applying the remaining reviewed moves.
6. Recovery records stay under the app's sandbox Application Support/RoomMoveRecovery
   with directory0700/files0600. Open a submitted or verified receipt to prepare an
   exact-UUID reverse move after fresh reconciliation. No rooms are deleted.

A timeout does not cancel HomeKit. Pending operations are persisted and quarantined;
an unknown outcome cannot be retried merely by restarting the app. Corrupt journals
fail closed. All windows share one coordinator and one process owns the journal.

## Build and authorize

Use macOS with Xcode, an Apple Account/development team, and HomeKit configured.
Open `HomeKitSync.xcodeproj`, choose your own team under Signing & Capabilities,
and provision normally. Do not disable the sandbox or grant broad filesystem
access to work around a denied socket. The HomeKit entitlement and app sandbox
are required; access begins only after Connect to HomeKit.

Build-only verification, without launching or granting HomeKit access:

```sh
xcodebuild -project HomeKitSync.xcodeproj -scheme HomeKitSync \
  -destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO build
swift test
python3 -m unittest discover -s tests -v
```

If Xcode is installed but Command Line Tools are selected, set `DEVELOPER_DIR` for
these commands to the installed Xcode Developer directory; no global change needed.

## Local-development MCP connection (not started by the default app)

For a separately reviewed local-development transport, use a standard stdio client on the Mac:

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

Do not use an SSH relay to export HomeKit-derived inventory off the Apple device.
A local socket is a security boundary, not a licensing exception. No credentials
or verification codes belong in MCP configuration.

Read-only convenience commands on the Mac:

```sh
python3 scripts/homekitctl.py discover
python3 scripts/homekitctl.py rooms
python3 scripts/homekitctl.py accessories
```

Home/room/device names are private, untrusted data. Keep returned inventories out
of public issues and logs. The relay does not retry requests after ambiguous errors.
The old HTTP routes, SSE endpoint, device controls, renames and bulk room-management
workflow are removed in this preview. MCP writes remain disabled; the native editor handles owner-reviewed room changes locally.

The Unix socket protects against LAN clients, websites and different OS users.
It does **not** isolate the server from malicious software running as the same
Mac user or an administrator. See the documented runtime verification gates and
limitations; this project makes no claim that all possible vulnerabilities are gone.
