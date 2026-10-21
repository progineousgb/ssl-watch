# ssl-watch

```sh
curl -fsSL https://raw.githubusercontent.com/progineousgb/ssl-watch/main/ssl-watch.sh | bash
```

Finds the domains configured on your server, connects to each one with openssl, and tells you how many days the certificate has left. Warns under 14 days, critical under 7. The exit code is set so it can live in cron.

Check other domains without scanning anything:

```sh
curl -fsSL https://raw.githubusercontent.com/progineousgb/ssl-watch/main/ssl-watch.sh | bash -s -- --no-scan --domains example.com,shop.example.com:8443
```

IPv6 addresses go in brackets when a port is given: `[2001:db8::1]:8443`. A bare `2001:db8::1` uses port 443. SNI is not sent for an IP address, and the address is matched against the certificate's IP entries.

## Platform

- Linux: works with bash 4 or newer, openssl, and GNU `timeout`.
- macOS: needs bash 4 or newer (`brew install bash`; the system bash 3.2 is too old) and openssl. `timeout` comes from `gtimeout` (`brew install coreutils`) when present, otherwise the script uses a perl alarm, and perl ships with macOS. Scanning only finds configs under the usual Linux paths, so use `--no-scan --domains`.
- Windows: run it in WSL or Git Bash with openssl installed.

## Example output

Real run. The `localhost` entries are throwaway self-signed certificates made for the test (5, 10 and 90 days), `nonexistent.invalid` shows an unreachable host, and the rest came from test nginx, apache and caddy configs.

```
$ ./ssl-watch.sh --config-dir /etc/ssl-watch --domains shop.example.com,api.example.com,old.example.com,nonexistent.invalid
DOMAIN                               STATUS      DAYS  EXPIRES     ISSUER
shop.example.com                     CRITICAL       4  2026-10-26  R11
api.example.com                      OK            89  2027-01-19  R10
old.example.com                      WARNING        9  2026-10-31  R11
nonexistent.invalid                  ERROR          -  -           -  (could not connect or no certificate)
cloudflare.com                       OK            44  2026-12-05  Google Trust Services
github.com                           OK            39  2026-11-30  Sectigo Limited
progineous.com                       OK            52  2026-12-12  Google Trust Services
www.progineous.com                   OK            52  2026-12-12  Google Trust Services

Checked 8 domain(s). Warn under 14 days, critical under 7. Exit code 2.
$ echo $?
2
```

## Where domains come from

- `--domains a.com,b.com` and plain arguments
- `--file domains.txt`, one per line, `#` comments allowed
- nginx `server_name`, apache `ServerName` / `ServerAlias`, and Caddyfile site addresses, read from `/etc/nginx`, `/etc/apache2`, `/etc/httpd`, `/etc/caddy` and `/usr/local/etc/nginx` (or `--config-dir` instead)

Wildcards, IPs, `_`, `localhost` and `example.com` style placeholders are skipped when scanning configs. Use `host:port` for anything not on 443.

## What it reports

For each domain: status, days left, expiry date, issuer. It also flags a certificate that does not cover the name you asked for (checked against the SAN list, wildcards included), since that breaks browsers just as badly as an expired one.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | all OK |
| 1 | at least one under `--warn` days, or a name mismatch |
| 2 | at least one under `--crit` days, expired, or could not connect |
| 3 | usage error or nothing to check |

Cron, mail only when something needs attention:

```
0 8 * * * /usr/local/bin/ssl-watch.sh -q || mail -s "SSL expiry on $(hostname)" you@example.com
```

## Options

```
-d, --domains LIST   comma separated domains (host or host:port)
-f, --file FILE      one domain per line
--config-dir DIR     scan this directory instead of the default paths (repeatable)
--no-scan            only check the domains you passed
--warn DAYS          default 14
--crit DAYS          default 7
--timeout SEC        per domain, default 10
--json               JSON output
-q, --quiet          only print domains that are not OK
--no-color
-h, --help
-V, --version
```

## Limits

- It checks the certificate the server actually serves, so the domain must resolve and be reachable from where you run it. That is usually what you want, but a domain behind a CDN shows the CDN certificate.
- Config parsing is line based. Includes, variables and macros (for example apache `Use` or nginx `include` of generated files outside the scanned paths) are not followed.
- Needs `openssl` and GNU `date`.

## Maintained by

Maintained by Pro Gineous, a domains, hosting and VPS provider: https://progineous.com

Issues and pull requests are welcome.

## License

MIT, see [LICENSE](LICENSE).
