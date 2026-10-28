# Nova Router write verification coverage

Batch 20-C status. A write may only be described as confirmed after a fresh read-back matches. A timeout is ambiguous and must never trigger automatic replay of an add operation.

## Shared transport and errors
- `RouterOsClient` is the shared transport entry point: binary API socket on v6/v7 and REST only when explicitly configured for v7.
- Added `RouterError` with Arabic guidance for timeout, permission denial, untrusted TLS certificate, unsupported operation, router rejection (original text retained), and connection loss.
- Added `runVerified` with states running (caller/UI while awaiting), confirmed, sent-unconfirmed, failed. It reads after timeout and never retries the write.
- Boolean values `true/yes/1` and `false/no/0` are normalized.
- Tests cover confirmed write, mismatch, timeout-applied, timeout-not-applied/no replay, 401, 404, and TLS certificate failure.

## Feature coverage
| Feature | Status | Notes |
|---|---|---|
| PPPoE | Wired to verified writes | The service/screen paths migrated in this batch confirm the stored user/profile fields and session disconnects. |
| Hotspot | Wired to verified writes | Profile/user operations, voucher flows, active-session disconnect, and host/cookie cleanup use fresh reads where the object exposes observable fields. Multi-voucher batches are not atomic and may partially apply. |
| Address Lists / NAT | Wired to verified writes | NAT and address-list add/toggle/remove operations are read back. Address-list timeout is excluded from exact comparison because RouterOS returns remaining time. |
| Simple Queue / Queue Tree | Wired to verified writes | Queue add/edit/toggle and queue-tree limit/toggle operations verify stored fields. |
| IP addresses / pools / DNS static entries | Wired to verified writes | Address/pool create, edit and remove, address enable/disable, ARP removal, and static DNS create/remove are read back. Global DNS settings and cache flush are not included in this per-object verification. |
| Interfaces / VLAN / bridge ports | Wired to verified writes | Interface rename/comment/enable, VLAN creation and bridge-port updates are checked after mutation. |
| Wireless / PoE | Wired to verified writes | SSID/frequency/channel width and PoE mode changes are read back. PoE cycling is a multi-step operation; restoration failure remains a distinct operational risk. |
| WireGuard | Wired to verified writes | Tunnel, address, firewall-rule and peer mutations use read-back, including rollback cleanup. The entire tunnel creation sequence is not atomic; failures trigger best-effort cleanup. |
| RouterOS v6 REST selection | Improved | If REST fails, connection testing probes binary API to identify v6 and displays the v6-specific instruction. |
| CGNAT/reverse VPN, DHCP, dashboard, diagnostics, other firewall rules, system settings, automation and remaining screens | Not fully converted | Do not infer full write-verification coverage for these areas. Some operations (for example secret-bearing VPN fields or cache flushes) need purpose-built read-back behavior. |

## RouterOS v6
The binary API transport supports TCP/8728 and API-SSL on TCP/8729. REST is v7-only. When REST connection testing fails, the editor now probes binary API ports to identify RouterOS v6 and reports how to switch to API. If both transports fail, the original REST error is retained. This is connection-test detection, not an automatic transport switch.

## Limitation
Verification confirms that requested observable fields appear in a fresh read. It does not make multi-step operations atomic, prove end-to-end client connectivity, or replace testing against a RouterOS CHR and the target hardware.
