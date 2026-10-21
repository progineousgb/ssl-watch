# Changelog

## v1.0.1 (2026-10-22)

- Parse IPv6 entries: `[addr]:port`, `[addr]`, and bare addresses. No SNI for IP addresses; IP SAN entries are matched.
- Timeout fallback on macOS: `gtimeout`, then a perl alarm.
- README: platform notes for Linux, macOS, and Windows.
- Add a CI workflow (bash -n and shellcheck).

## v1.0.0 (2026-10-21)

First tagged release. Check SSL certificate expiry for every domain on a server. Cron friendly.

- Initial release
