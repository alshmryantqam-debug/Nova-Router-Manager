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
| PPPoE | Partial / helper available | Existing mutations still require conversion to per-operation read-back before they can claim confirmation. |
| Hotspot | Partial / helper available | Bulk voucher creation must verify count and created IDs before claiming confirmation. |
| Address Lists / NAT | Partial / helper available | Existing mutations are not yet all routed through `runVerified`. |
| Simple Queue | Partial / helper available | Existing queue mutations are not yet all routed through `runVerified`. |
| Dashboard, diagnostics, DHCP, neighbors, firewall, Wi-Fi, WireGuard, automation, templates and other screens | Not yet converted | Audit remaining mutation call-sites before marking verified. |

## RouterOS v6
The repository contains a binary RouterOS API socket client using TCP/8728 and API-SSL on TCP/8729 in `lib/core/network/routeros_client.dart`. REST is a separate v7-only transport option. Thus v6 binary API transport exists. This batch does not change connection-screen gating; the explicit message when REST is selected for v6 remains pending.

## Limitation
This batch adds common error and verification primitives and tests. It does **not** claim every existing screen is migrated. Do not show “تم” in a screen until its mutation path is wired to `runVerified` with read-back.
