# Apple terms and deployment constraints

Room assignment uses Apple's documented `HMHome.assignAccessory(_:to:completionHandler:)`.
The presence of that API does not waive Apple's licensing conditions.

The current Apple Developer Program terms, section3.3.3(I), restrict HomeKit use to
home configuration/automation and restrict taking HomeKit-derived information off
the applicable Apple product unless Apple documentation permits it. Consequently,
this app's room workflow keeps HomeKit inventory, matching, journals and receipts
on the Mac. Its default UI does not start an MCP/IPC inventory service. Import only
Home Assistant names/areas; do not stream HomeKit inventory to Linux or a cloud model.

The Xcode SDK agreement contains additional development-use conditions for HomeKit.
Free Personal Team provisioning is time-limited and is not a durable unattended
production-distribution arrangement. A successful build does not establish a right
to distribute it or a legal compliance certification. Use the agreement and signing
route applicable to your membership, and obtain clarification from Apple if needed.

Sources reviewed:
- https://developer.apple.com/support/terms/apple-developer-program-license-agreement/
- https://www.apple.com/legal/sla/docs/xcode.pdf
- https://developer.apple.com/documentation/homekit/hmhome/assignaccessory(_:to:completionhandler:)
