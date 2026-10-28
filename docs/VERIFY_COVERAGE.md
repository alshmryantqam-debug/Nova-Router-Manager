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
| PPPoE | Wired to verified writes | Profile, Caller-ID, live speed, expiry comment and disconnect mutations use a fresh read-back. |
| Hotspot | Wired to verified writes | Profile create/update, user/voucher creation, active disconnect and user removal are verified per operation. A multi-voucher batch can be partially applied if one voucher fails; it is not an atomic router transaction. |
| Address Lists / NAT | Wired to verified writes | NAT add/toggle/remove and address-list add/remove are read back. Address-list timeout is excluded from exact comparison because RouterOS returns remaining time, not the original duration. |
| Simple Queue / Queue Tree | Wired to verified writes | Queue add/edit/toggle and queue-tree limit/toggle operations verify the stored fields. |
| Dashboard, diagnostics, DHCP, neighbors, other firewall screens, Wi-Fi, WireGuard, automation, templates and other screens | Not yet converted | These screens may still have direct mutation calls; do not assume global verification coverage outside the four areas above. |

## RouterOS v6
The repository contains a binary RouterOS API socket client using TCP/8728 and API-SSL on TCP/8729 in `lib/core/network/routeros_client.dart`. REST is a separate v7-only transport option. The four migrated feature areas use the existing client and do not require REST specifically, so they can use binary API on v6. The explicit connection-screen gate that prevents selecting REST for a v6 router is still pending; a REST selection on v6 should be treated as unsupported rather than automatically falling back.

## Limitation
The shared verifier is now used by the listed four feature areas. Other screens remain outside this coverage until their writes are migrated. A confirmed result means the requested fields were observed in a fresh RouterOS read; it does not make a group of multiple writes atomic.
