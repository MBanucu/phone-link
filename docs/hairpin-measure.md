# Measuring the AP hairpin

`tests/live/hairpin-measure.sh` records the before/after numbers for
[#47](https://github.com/MBanucu/phone-link/issues/47): phone latency and an
8 MB transfer, the laptop's 500/200/8 MB soaks, proxy client headroom, battery
over 30 minutes, the concurrent path, cellular fallback and AP bootstrap.

It does **not** enable the hairpin. A normal run reads the feature that is
already live and leaves every network setting alone. The one exception is
`--fallback`, which needs #46, root and an explicit opt-in, because it stops the
tunnel to time the phone's fallback.

The design behind the feature is in
[#42](https://github.com/MBanucu/phone-link/issues/42). The feature is split
into #43 (forwarding/NAT), #44 (DNS), #45 (egress guard), #46 (fail-open) and
this measurement, #47.

## What can be measured when

| measurement | available on the link-only AP | needs |
|---|---|---|
| phone ICMP, TCP :443, 8 MB over the link-only AP (direct cellular) | yes | phone, adb |
| laptop 500 sequential, 200 at concurrency 40, 5 x 8 MB | yes | tunnel up, curl |
| proxy client peak / `max_connections` / battery / AP retries | yes | phone, adb |
| phone latency/throughput through the hairpin | no | #43/#44 live, AP validated |
| phone + laptop at the same time | no | #43/#44 live |
| bootstrap (AP up to validated) | no | #43/#44 live |
| fallback (kill `phone-tun`, cellular returns) | no | #46 live |
| HTTPS *request* latency from the phone | no | a TLS client on the phone |

The phone has `nc`, toybox and `ping`, but no `curl`, `wget` or `openssl`; the
harness therefore measures ICMP and TCP :443 latency, and transfers the 8 MB
body with `nc` over plain HTTP. When a TLS client is present it also records
the real HTTPS request; otherwise the number is written as `UNAVAILABLE` rather
than estimated. Android's own validation-probe count is not exposed by
`dumpsys`; the bootstrap row says so and records only the harness's own
reachability checks and whether `dumpsys wifi` mentions a temporary disable.

## Preconditions

- The phone is attached and `adb devices` shows exactly one device.
- The laptop tunnel is up (`systemctl is-active phone-tun`, and
  `ip route get 1.1.1.1` goes through `phone-tun`) for the laptop soak.
- For `--via socks`, `PHONE_SOCKS_PASS` is set or the root-only secrets file is
  readable. The default `--via tunnel` needs neither.
- For the battery number, unplug USB and use adb over the AP; while the phone
  says `USB powered: true` the level delta is recorded but marked as taken
  while charging, so it is not a battery-use number.
- The hairpin is enabled only for the **after** run. The before run is on
  `phoneLink.ap.uplink = "none"` (the link-only AP, still the default), where
  the phone keeps cellular as its default network.

Check the host and phone without changing anything:

```sh
sudo tests/live/hairpin-measure.sh --check
```

`--check` reports tools, the tunnel route, the AP/phone state, whether the
scoped forward and hairpin NAT are present, the proxy's listener state, whether
the phone has a TLS client, and which numbers are still blocked. It needs no
root when the caller can read `nft` and adb; `sudo -n` is used for the read when
available.

## The runs

Use a separate evidence directory per phase. All of them are under
`result-live/` (gitignored).

### 1. Before, on the link-only AP

```sh
sudo tests/live/hairpin-measure.sh --mode before \
  --out result-live/hairpin-before
```

This records the phone's direct-cellular path (ICMP, TCP :443, 8 MB), the
laptop's 500 sequential / 200-at-40 / 5 x 8 MB soaks, proxy client count every
5 seconds, battery for 30 minutes and the AP's retry counters. It takes roughly
35–45 minutes, mostly the battery window.

### 2. After the hairpin is enabled

Confirm the feature is really live first:

```sh
sudo tests/live/hairpin-measure.sh --check
# expect: hairpin: forward=yes nat=yes ... ap_validated=yes
#         default network: wifi-ap
```

Then:

```sh
sudo tests/live/hairpin-measure.sh --mode after \
  --out result-live/hairpin-after
```

`--mode after` refuses to run if no scoped forward, hairpin NAT or validated AP
is detected; it writes `UNAVAILABLE (needs #43/#44)` instead of measuring a
path that is not there. If detection is blocked only by permissions, set
`PHONE_HAIRPIN_ACTIVE=1` **only** after confirming the rules and validation by
hand.

### 3. Fallback, with #46 deployed

This is disruptive by design and is never part of the default run:

```sh
sudo env PHONE_MEASURE_ALLOW_FALLBACK=1 \
  tests/live/hairpin-measure.sh --mode after --fallback \
  --battery-minutes 0 --out result-live/hairpin-fallback
```

It stops `phone-tun-toggle.timer` and then `phone-tun.service`, opens a TCP :443
connection to `1.1.1.1` from the phone once a second, records the first
success, then restores the timer and the tunnel. A trap restores both if the run is interrupted. If the
laptop is still down after a killed run, restore by hand:

```sh
sudo systemctl start phone-tun-toggle.timer
sudo systemctl start phone-tun.service
```

### 4. Bootstrap, with #43/#44 deployed

Run this immediately after a laptop reboot (the AP autoconnect profile must be
on), or from a boot-time hook:

```sh
sudo tests/live/hairpin-measure.sh --mode after --bootstrap \
  --battery-minutes 0 --out result-live/hairpin-bootstrap
```

It records the time from the AP DHCP unit's activation to the phone reporting
the AP `VALIDATED`, falling back to "harness start to validated" when the AP
has been up for more than five minutes (that is no longer a boot measurement).
It also records whether `dumpsys wifi` mentions `TEMPORARY_DISABLED` and counts
the harness's own failed reachability checks. Android's internal probe count is
not exposed and is marked unavailable.

### 5. The before/after table

```sh
tests/live/hairpin-measure.sh --compare \
  result-live/hairpin-before result-live/hairpin-after
```

Paste that table into #47. Missing numbers stay `UNAVAILABLE (needs #…)`.

## What to record in #47

At minimum, from the two evidence directories:

| row | where it comes from |
|---|---|
| phone ICMP / TCP :443 median and p95, direct vs hairpin | `phone-latency.csv` |
| phone 8 MB duration and Mbit/s, exact body bytes | `phone-download.csv` (`phone_ns` is the phone-clock duration; `mbps_from_ns` makes the rate) |
| laptop sequential failures and p95 | `laptop-soak-seq.csv` |
| laptop concurrency-40 failures and p95 | `laptop-soak-par.csv` |
| laptop 5 x 8 MB sizes and Mbit/s | `laptop-download.csv` |
| peak proxy clients, `max_connections`, headroom | `proxy-samples.csv` |
| battery level/temperature, and whether it was charging | `battery.csv` |
| AP tx retries / failed frames before vs after | `ap-samples.csv` |
| phone and laptop 8 MB at the same time | `shared.csv` |
| fallback seconds, first default network after | `fallback.csv` |
| bootstrap seconds, AP-up age, temporary disable | `bootstrap.csv` |

Acceptance from #47:

- phone throughput through the hairpin stays above **50% of direct cellular**
  for normal browsing, or the measured reason it does not is recorded;
- the laptop soak has **no tunnel regression** against the with-feature run;
- the proxy peak stays below the configured ceiling, with the headroom stated;
- fallback and bootstrap are inside the budgets decided by #46/#43.

`summary.md` in each run is the readable version; `results.csv` is what
`--compare` reads.

## Safety and roll back

- A normal run measures; it does not add nftables rules, DHCP options or
  forwarding, and it does not write to the phone. `adb shell` is read-only.
- `--fallback` is the only run that changes live networking. It requires #46,
  root, `PHONE_MEASURE_ALLOW_FALLBACK=1`, and restores the timer and tunnel on
  exit with a trap.
- To roll the **feature** back, set `phoneLink.ap.uplink = "none"` (the default)
  in the NixOS configuration and `nixos-rebuild switch`, or boot the previous
  generation. The harness itself has nothing to undo.
- Evidence goes to `--out DIR`, else `PHONE_MEASURE_OUT`, else
  `result-live/hairpin-<UTC>`; it is gitignored. It contains no secret; the
  proxy password, if `--via socks` is used, is read from `PHONE_SECRETS` at run
  time only.

## Options and environment

`--quick` is a short smoke run (20 sequential, 20 at concurrency 10, 2 x 8 MB,
2-minute window). It is not a substitute for the full run.

| variable | default |
|---|---|
| `PHONE_MEASURE_OUT` | `result-live/hairpin-<UTC>`; `--out` wins over it |
| `PHONE_MEASURE_HTTPS_HOST` | `speed.cloudflare.com` |
| `PHONE_MEASURE_BYTES_URL` | `http://speed.cloudflare.com/__down?bytes=8388608` |
| `PHONE_MEASURE_BYTES` | `8388608` |
| `PHONE_MEASURE_SOAK_URL` | `https://example.com/` |
| `PHONE_MEASURE_SEQ` / `_PAR` / `_PAR_WORKERS` | `500` / `200` / `40` |
| `PHONE_MEASURE_LAPTOP_DOWNLOADS` | `5` |
| `PHONE_MEASURE_PHONE_SAMPLES` | `10` |
| `PHONE_MEASURE_PHONE_DOWNLOADS` | `3` |
| `PHONE_MEASURE_BATTERY_MINUTES` | `30` |
| `PHONE_MEASURE_VIA` | `tunnel` (`socks` matches the older runs) |
| `PHONE_MEASURE_FAILOPEN_UNIT` | `phone-link-ap-failopen.service` |
| `PHONE_HAIRPIN_ACTIVE` | unset (read-only detection; `1`/`0` overrides) |

## No-phone paths

These never call adb, `nft`, curl or the network and need no root:

```sh
tests/live/hairpin-measure.sh --self-test   # parsers, URL guard, rule matcher
tests/live/hairpin-measure.sh --dry-run     # the plan and the blocked numbers
tests/live/hairpin-measure.sh --check       # also works with no phone attached
tests/live/hairpin-measure.sh --compare A B
```

`tests/hairpin-measure.test.sh` exercises all four in `nix flake check`.
