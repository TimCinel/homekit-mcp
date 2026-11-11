# Security review and migration

Reviewed baseline: `69d1ebb44d1fd52c2b5dd5e5e43092e484f284e4`.
This is a source review plus credential-free tests, not a penetration-test
certification, proof of exploit in somebody's home, or a claim of zero vulnerabilities.
A separate hostile review challenged the initial hardening and its follow-up changes.

## Findings in the upstream baseline

| Finding | Impact and evidence | Change in this preview |
|---|---|---|
| High: no authorization on network control API | `HTTPMCPServer.setupHTTPServer` constructs `NWListener` without an explicit loopback-only endpoint; routing reaches HomeKit inventory and power/cover/rename/move tools without authentication. A reachable client can act with the app's granted HomeKit authority. Actual reachability depends on OS/firewall configuration. | Remove TCP and all mutation code; require an owner-only Unix socket and same effective UID. |
| High: browser-accessible control surface | No Origin/Host validation, wildcard CORS, and mutation routes together expose a browser/network trust boundary. Exploitability depends on browser private-network restrictions; no browser exploit was attempted. | Remove the HTTP/CORS surface entirely, rather than rely on browser policy. |
| Medium: Stop could leave the listener alive | `AppWrapper.stopServer` releases one reference, while listener/connection callbacks retain the server; there is no explicit listener/connection teardown. UI may imply access is revoked while it persists. | Explicit asynchronous stop completes after socket removal and instance-lock release; close active connections and routers. |
| Medium: unbounded resource handling and invalid framing | Each `NWConnection.receive` chunk is treated as an entire HTTP request; no connection count/deadline, bounded stream accumulation or EOF disposal. `Content-Length` and transfer framing are not enforced. | Remove custom HTTP parsing. Bound NDJSON frames, concurrency, nesting, I/O time and absolute connection lifetime; close EOF and malformed frames. |
| Medium: name-based mutations can target ambiguous objects | Substring/first-match lookup and independently searched home/room objects do not establish unique intended device identity. | Remove all mutations and legacy bulk scripts in this preview. Any future writes need exact IDs, same-home checks and scoped owner approval. |
| Medium: synchronous waits block HomeKit callbacks | `DispatchGroup.wait` runs on the same main queue used by the server/HomeKit callbacks. A timeout does not cancel a write; callers may retry after an ambiguous outcome. | Remove blocking write workflows and prohibit automatic retries; production tools are read-only. |
| Low: private home data in diagnostics | Logs include home/device names, IDs, request arguments and result text; inventory includes unnecessary serial/firmware information. | Remove runtime app diagnostics and serial/firmware reads; inventory remains private output only. |
| Protocol/security validation gap | The baseline advertises2024-11-05 while exposing custom routes. Its SwiftPM tests exercise separate helpers/model examples rather than the deployed routing/transport. | Production MCP2026-07-28 router and Unix host compile into both app and tested SwiftPM target. CI runs actual unsigned Catalyst build. |

Severity is contextual, not a CVSS score. These findings do not show that Apple
account credentials were stolen. HomeKit authorization grants device/home access;
the reviewed code does not require the user's Apple password.

## Issues caught in the local adaptation, not upstream vulnerabilities

These are included for transparency and regression coverage; do not attribute them
to the upstream author:

- A temporary token-based client could use environment proxies and preserve its
  Authorization header across redirects. That architecture was never activated.
- The temporary Catalyst Keychain token could not reliably be retrieved using the
  file-Keychain CLI. No password export or relaxed ACL workaround was used.
- Deferred socket cleanup caused an immediate stop/start lock race. Stop completion
  now runs only after socket teardown/lock release, and the UI disables Start meanwhile.
- Relay cancellation followed by request-ID reuse could consume a stale selector
  event against a new socket. Events now verify socket identity and tolerate EAGAIN.
- Malformed IDs, duplicate keys, invalid Unicode, excessive nesting, NaN/Infinity
  or numeric overflow, and overload could disrupt unrelated relay calls. Validation
  now rejects these inputs with bounded errors; overload preserves existing calls.
- The convenience client's per-read timeout could be extended by a trickling peer.
  It now enforces a monotonic absolute deadline.
- Empty-argument tools and the modern-only legacy-client diagnostic needed protocol
  corrections. Tool calls accept omitted arguments; unknown/extra arguments and
  unavailable tools never reach the backend.

## Protocol and least-authority design

Modern-only MCP2026-07-28: per-request version/capabilities, `server/discover`,
`resultType: complete`, numeric/string IDs, no notification responses, cancellation
suppression for in-flight router completions and -32022 version errors with a
supported-version list. No legacy handshake or HTTP transport is advertised.
The stdio relay multiplexes up to8 requests; the internal custom Unix transport
accepts one NDJSON request per connection and closes after its bounded response.
The app accepts up to16 owner-UID connections. Idle socket calls have5-second
limits and connections a45-second absolute lifetime. No retries after ambiguity.

Only `get_all_accessories` and `get_all_rooms` exist. Tool annotations describe
read-only behavior but are not access control; the production dispatcher/backend
contain no mutation implementation. Device names are untrusted content, not
instructions. Inventories contain private home metadata and must not be published.
No credentials, HTTP server, proxy support, redirect handling, telemetry or updater.
App Sandbox remains enabled; startup is an explicit local owner action.

## Verification and remaining activation gates

Tests exercise the production protocol core, framing and Unix connection host,
plus relay parser, cancellation/ID-reuse, overload and deadline regressions. No test
loads HomeKit or contacts real accessories. See CI for commands and exact coverage.

Before enabling this in a home, still verify:

1. Normal signing/provisioning, actual sandbox socket location, HomeKit authorization
   and terminal/SSH access to the container. Do not weaken sandbox/privacy to pass.
2. Other-user connection denial on the signed app and absence of a TCP listener.
3. Signed app start/stop/restart, active-request teardown and inventory correctness.
4. Review the changed compatibility surface: HTTP, legacy clients and all mutation
   workflows are deliberately unavailable. This PR is a draft security preview.

Native tests and unsigned builds cannot establish these signed Catalyst properties.
The OS user account is the IPC trust boundary: same-user malware or an administrator
can inspect private data or impersonate a local socket. Code-identity-authenticated
XPC would be a stronger separate design. Socket directories rely on trusted OS
container ancestors; peer checks and0700/0600 permissions do not defeat a compromised
owner account. Read-only home inventory is still sensitive.

## Recorded validation

- 48 Swift tests passed, including production protocol and Unix-host tests.
- 7 Python relay regression tests passed.
- Actual Catalyst application compiled with CODE_SIGNING_ALLOWED=NO.
- Independent hostile source review found no remaining blocker in this scoped
 read-only preview; signed runtime gates above remain unresolved.
- No production app launch, HomeKit permission grant or accessory operation occurred.

## Primary protocol references

- https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning
- https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio
- https://modelcontextprotocol.io/specification/2026-07-28/server/discover
- https://modelcontextprotocol.io/specification/2026-07-28/server/tools
- https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains
