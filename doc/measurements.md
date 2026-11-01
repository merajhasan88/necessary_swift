# Measurements — what the SDK measures on the iPhone

Every measurement this SDK can put in a signed report, field by field: what it is, how the SDK
measures it, and what a complete answer holds. Every Necessary SDK sends the same report format, and
none sends a score or a verdict; what a measurement means for a request is your backend's decision. The integration guide
(`integration_guide.md`, beside this file) is the protocol — how your backend asks for a scan and checks
the report — and its section 7 is about deciding with these measurements.

## The contract

The SDK follows the measurement contract published in `contract/report-1/android-8-ios-5/`, the same for
every Necessary SDK: the report's schema (`report.schema.json`), the rules a schema cannot state
(`RULES.md`), and sample reports judged each way (`samples/`). The folder's name is two versions:

- `report-1` is the report's format, version 1 — `version` in every report;
- the rest names the lowest versions of the measuring code, the collector, that the contract accepts
  on each platform: on iOS 5 — `collector_version` in every report. This SDK's collector is version 8.
  These are not iOS versions: the SDK runs on iOS 15 and later.

This file describes that contract as this SDK sends it: each heading below is one of its
measurements — a probe — and each row of a table one of its fields.

## Reading a measurement

- **Every probe has a `status`**: `ok`, measured; `error`, with `error` saying why; `unsupported`, with
  `reason`; or `not_enabled`, a personal measurement your app does not collect. **`ok` means measured, never "all clear"**: the phone took the measurement, and what it
  found is in the fields — the example app shows it as *measured*.
- **`ok` says measured; the fields say how much.** A probe is complete when it answered `ok` and carries every
  field marked *yes* below — for `code_integrity` with `checked` true, every field marked *when checked*
  as well, and for a list of apps `truncated` present and false (*yes, false*).
- **`unread`** names the parts of an `ok` probe that could not be read, each with why:
  `{"image_names": "2 of 412 could not be read"}`. An unread part is not measured: never read it as a
  clean "no".
  A probe that could read nothing answers `error`.
- **A field that is absent was not measured.** Fields are only ever added, and a field's meaning never
  changes; ignore fields and probes you do not know.
- **A report that lacks a measurement your backend asked for is refused, never read** (integration
  guide, section 2). A failed or incomplete measurement says that something could not be measured, not
  that the phone is attacked: ask again rather than punish the person.
- **Figures that contradict each other** — code-comparison coverage that does not add up, two different
  times for one location fix — make a report one to distrust (`RULES.md`, section 7).

Each probe says when it comes:

- **your backend asks for it**, in the challenge's `required_probes`. Ask every time for each
  measurement you rely on, and vary the others from scan to scan;
- **every scan**, whether or not your backend asks. Rely on one only by asking for it: until you do, its
  absence or failure does not make a report incomplete;
- **a personal measurement**, only when your backend lists it in `optional_probes` and your app enables
  it in the SDK (the README says how) — the location only with the person's permission as well.
  These identify a person's phone, network or habits (integration guide, section 8).

The columns: *Type* — `true/false`, an integer or a number with its unit, text, a list or a map;
*Needed* — *yes*, a complete answer carries it; *when checked*, needed when `checked` is true; *yes,
false*, present and false; empty, sent when the SDK has it.

## The measurements

Your backend may ask for `app_identity`, `code_signing`, `debugger`, `jailbreak_files`, `sandbox`,
`dyld_images`, `environment` and `simulator`. Every scan carries `code_integrity`, `device` and
`network`. The personal measurements are `local_addresses`, `screen_capture`, `location` and
`mock_location`; `accessibility`, `notification_access` and `other_access` exist on iOS only to say that
iOS cannot measure them.

### `app_identity`

The installed app: its bundle identifier and version, and the SHA-256 and size of its main executable.
An executable with code added is larger, and one changed byte changes the hash: compare these with each
release of yours (integration guide, section 7.2).

**When:** your backend asks for it.

| Field | Type | Needed | Meaning |
|---|---|---|---|
| `bundle_id` | text | yes | the app's bundle identifier |
| `executable_sha256` | text | yes | the SHA-256 of the main executable; empty when it could not be read |
| `version_name` | text |  | the app's version (`CFBundleShortVersionString`) |
| `version_code` | text |  | the app's build number (`CFBundleVersion`) |
| `executable_bytes` | integer, bytes |  | the main executable's size |

### `code_signing`

The main executable's own code signature, read from the file: its signing identifier, your team
identifier, and whether the app lets a debugger attach (`get-task-allow`, set on development builds). An
executable that carries no signature says so: `signed` false, never taken for a signed app.

**When:** your backend asks for it.

| Field | Type | Needed | Meaning |
|---|---|---|---|
| `signing_identifier` | text | yes | the signature's identifier; empty without one |
| `team_identifier` | text | yes | the team identifier its entitlements name; empty without one |
| `get_task_allow` | true/false | yes | its entitlements let a debugger attach |
| `signed` | true/false |  | the executable carries a signature |
| `signature_absent` | true/false |  | true when it carries none |
| `signature_parse_error` | text |  | why a signature that is there could not be read |
| `code_directory_flags` | integer |  | the code directory's flags, as a number |
| `entitlement_count` | integer, count |  | how many entitlements the signature grants |

### `debugger`

A debugger tracing the app's process: the kernel's `P_TRACED` flag.

**When:** your backend asks for it.

| Field | Type | Needed | Meaning |
|---|---|---|---|
| `traced` | true/false | yes | a debugger traces the process |

### `jailbreak_files`

Whether 20 known jailbreak paths exist: the package managers (Cydia, Sileo, Zebra), Substrate and
ElleKit, a shell and SSH, apt's and Cydia's folders, `/private/var/stash`, the marker files of the
Electra, Taurine and unc0ver jailbreaks, and the rootless `/var/jb` layout of current jailbreaks. A
clean phone's sandbox hides most of them, so a path the app cannot see reads as absent. On the
Simulator, whose files are the Mac's, it answers `unsupported`.

**When:** your backend asks for it.

| Field | Type | Needed | Meaning |
|---|---|---|---|
| `found_paths` | list | yes | the listed paths that exist |
| `checked_count` | integer, count |  | how many paths were checked |

### `sandbox`

Whether the app can write outside its sandbox: a phone that enforces the sandbox refuses it. A file that
was written is removed at once.

**When:** your backend asks for it.

| Field | Type | Needed | Meaning |
|---|---|---|---|
| `write_outside_sandbox_succeeded` | true/false | yes | the write succeeded |
| `probe_path` | text |  | the path the app tried to write |

### `dyld_images`

Instrumentation and jailbreak names among the libraries loaded into the app: Frida and its Gadget,
Objection, Cynject, Cycript, Substrate and MobileSubstrate, Substitute, libhooker, ElleKit, Cydia,
Shadow, FLEX and libSparkAppList. It matches names, so a renamed library escapes it; `code_integrity`
compares the code itself. A library whose name the loader did not give (one unloading as the list is
read) is in `unread` as `image_names`, since it could be one of those.

**When:** your backend asks for it.

| Field | Type | Needed | Meaning |
|---|---|---|---|
| `suspicious_tokens` | list | yes | the listed names found, sorted |
| `suspicious_image_count` | integer, count |  | loaded libraries with a listed name |
| `image_count` | integer, count |  | libraries loaded |

### `environment`

Libraries injected through the environment: `DYLD_INSERT_LIBRARIES`, which loads a library into the app
as it starts.

**When:** your backend asks for it.

| Field | Type | Needed | Meaning |
|---|---|---|---|
| `dyld_insert_libraries` | text | yes | the variable's value, at most 8,192 characters; empty when it is not set |

### `simulator`

Whether the app runs in the iOS Simulator, and the hardware model.

**When:** your backend asks for it.

| Field | Type | Needed | Meaning |
|---|---|---|---|
| `is_simulator` | true/false | yes | the app runs in the Simulator |
| `model` | text |  | the hardware model identifier, for example `iPhone15,2` |

### `code_integrity`

The app's own code compared in memory with its files, image by image: every image the loader mapped from
the app — the main executable and its frameworks — has its `__text` compared. iOS keeps its system
libraries in a shared cache that no app can read, so only the app's own code can be compared: the system
figures are always 0 — not measured, never clean — and `system_images_unreadable` counts those
libraries. Each app image is compared, unreadable (its file could not be read in full) or skipped (no
usable `__text`, a `__TEXT` over 64 MiB, no live address, or code encrypted on disk); images and bytes
both add up, expected = compared + unreadable + skipped. An app installed from the App Store has its
code encrypted in its files and decrypted only in memory, so the two differ in every encrypted byte of a
genuine app: such an image is skipped and named in `app_images_not_compared`, never compared — a
development, ad hoc or enterprise build is stored in the clear and is compared. A framework stored as a
universal file is compared through its arm64 image. An image whose file is another build than the one
running — an app updated while it ran — is skipped and named, never compared: the old code in memory and
the new file would differ in bytes nobody changed. An image the loader counts but gives no name for
counts as one not read. `app_complete` is true exactly when every image was compared, the main executable
among them. It comes with every scan; ask for it too, since a report that lacks it is refused
only when you asked for it.

**When:** every scan, whether or not your backend asks.

| Field | Type | Needed | Meaning |
|---|---|---|---|
| `checked` | true/false | yes | the comparison ran: at least one image was compared |
| `app_diff_bytes` | integer, bytes | yes | bytes that differ in the app's compared code |
| `app_compared_bytes` | integer, bytes | yes | the app's code compared, in bytes |
| `app_images_expected` | integer, count | when checked | the app's images the loader mapped |
| `app_images_compared` | integer, count | when checked | of those, the images compared |
| `app_images_unreadable` | integer, count | when checked | the images whose file could not be read in full |
| `app_images_skipped` | integer, count | when checked | the images skipped |
| `app_expected_bytes` | integer, bytes | when checked | the `__text` bytes of the app's images |
| `app_unreadable_bytes` | integer, bytes | when checked | those of the unreadable images |
| `app_skipped_bytes` | integer, bytes | when checked | those of the skipped images |
| `app_complete` | true/false | when checked | every app image was compared |
| `main_executable_compared` | true/false | when checked | the main executable was among the compared |
| `app_images_not_compared` | map |  | each app image not compared, by its path in the app, with why |
| `system_images_unreadable` | integer, count |  | the system libraries loaded, which no app can read |
| `app_libs_diff` | integer, count |  | app images with a difference |
| `diffed_libs` | text |  | the images with a difference, comma-separated |
| `diff_bytes` | integer |  | always 0: iOS's system libraries cannot be read |
| `core_compared_bytes` | integer |  | always 0, likewise |
| `core_diff_bytes` | integer |  | always 0, likewise |
| `ext_compared_bytes` | integer |  | always 0, likewise |
| `ext_diff_bytes` | integer |  | always 0, likewise |
| `ext_libs_diff` | integer |  | always 0, likewise |
| `system_bucket_reason` | text |  | why the system figures are 0: `dyld_shared_cache_has_no_backing_files` |
| `app_segment_compared_bytes` | integer, bytes |  | the whole `__TEXT` segments compared, beyond `__text`, in bytes: telemetry |
| `app_segment_diff_bytes` | integer, bytes |  | bytes that differ across those segments: telemetry |

### `device`

The iOS version and build, the hardware model, and the memory page size. iOS has no separate security
patch level: its security fixes ship as iOS versions, and the build tells a Rapid Security Response
apart.

**When:** every scan, whether or not your backend asks.

| Field | Type | Needed | Meaning |
|---|---|---|---|
| `os_version` | text | yes | the iOS version, for example `17.6.1` |
| `os_build` | text |  | the build, for example `21G93` |
| `model_identifier` | text |  | the hardware model identifier, for example `iPhone15,2` |
| `page_size` | integer, bytes |  | the memory page size: 16384 on Apple's 64-bit phones |

### `network`

Whether a VPN or an HTTP proxy is in use. iOS gives apps no way to ask about a VPN, so a VPN is inferred
from the network interfaces the system proxy settings are scoped to (`utun`, `ipsec`, `ppp`, `tun`,
`tap`): a heuristic, so the names come with it. The proxy is read from the system proxy settings;
whether an app's own requests follow it depends on how the app makes them.

**When:** every scan, whether or not your backend asks.

| Field | Type | Needed | Meaning |
|---|---|---|---|
| `vpn_active` | true/false | yes | an interface the proxy settings are scoped to is a VPN's kind |
| `http_proxy_configured` | true/false |  | an HTTP, HTTPS or automatic proxy is set |
| `scoped_interfaces` | list |  | the interfaces the proxy settings are scoped to, sorted, at most 32 — `en0` Wi-Fi, `pdp_ip0` cellular, `utun3` a tunnel |

### `local_addresses`

The phone's own IP addresses, per network interface. Loopback and link-local (`fe80`, `169.254`)
addresses are left out.

**When:** your backend asks for it and your app enables it — a personal measurement.

| Field | Type | Needed | Meaning |
|---|---|---|---|
| `addresses` | list | yes | each an `interface` (its name) and an `address` (IPv4 or IPv6), at most 32 |
| `truncated` | true/false |  | the phone had more than the 32 addresses a list holds (from collector 8) |

### `screen_capture`

Whether the screen showing the app is being recorded, mirrored or sent to AirPlay
(`UIScreen.isCaptured`, asked of the screen of each of the app's windows in the foreground), and how
many other screens are attached. With no window of the app's in the foreground — the app in the
background, or before its first window — recording is not measured: it is left out, unknown rather than
"no", and `recording_status` says why.

**When:** your backend asks for it and your app enables it — a personal measurement.

| Field | Type | Needed | Meaning |
|---|---|---|---|
| `recording` | true/false | yes | the screen showing the app is being captured |
| `external_displays` | integer, count | yes | other screens attached |
| `recording_status` | one of `unsupported`, `no_permission`, `unavailable` |  | why `recording` is absent: `unavailable`, no window of the app's in the foreground to ask. iOS has measured recording since iOS 11, so `unsupported` never comes from iOS |

### `location`

The last location the phone already holds — never a fresh fix, never a prompt — read once per scan, so
that both location answers describe the same fix. Coordinates come only with the location permission,
which your app asks for itself (your SDK's README says how).

**When:** your backend asks for it and your app enables it — a personal measurement.

| Field | Type | Needed | Meaning |
|---|---|---|---|
| `permission` | one of `none`, `approximate`, `precise` | yes | the app's location permission: `approximate` when the person allowed an approximate location only |
| `latitude` | number, degrees, WGS 84 | yes | the fix's latitude; absent without the permission or without a fix |
| `longitude` | number, degrees, WGS 84 | yes | the fix's longitude; absent likewise |
| `age_seconds` | integer, seconds | yes | how old the fix is |
| `accuracy_m` | number, metres |  | its horizontal accuracy |
| `fix_time` | integer, Unix seconds, UTC |  | when it was made |

### `mock_location`

Whether that same fix was simulated by software, by Apple's own flag, or produced by an external
accessory. Apple's flag catches the simulation of its own developer tools; Apple does not promise it for
other spoofing apps. It never carries coordinates.

**When:** your backend asks for it and your app enables it — a personal measurement.

| Field | Type | Needed | Meaning |
|---|---|---|---|
| `permission` | one of `none`, `approximate`, `precise` | yes | the app's location permission |
| `mock` | true/false | yes | iOS says the fix was simulated by software; absent when iOS did not say |
| `age_seconds` | integer, seconds | yes | how old the fix is |
| `accessory` | true/false |  | the fix came from an external accessory, such as a GPS receiver |
| `fix_time` | integer, Unix seconds, UTC |  | when it was made: the same as `location`'s in one report |

### `accessibility`

iOS shows an app no other app, so there is nothing to list: this answers `unsupported` when your app
enables it, and `not_enabled` when it does not. No fields.

**When:** your backend asks for it and your app enables it — a personal measurement.

### `notification_access`

iOS shows an app no other app, so there is nothing to list: this answers `unsupported` when your app
enables it, and `not_enabled` when it does not. No fields.

**When:** your backend asks for it and your app enables it — a personal measurement.

### `other_access`

iOS shows an app no other app, so there is nothing to list: this answers `unsupported` when your app
enables it, and `not_enabled` when it does not. No fields.

**When:** your backend asks for it and your app enables it — a personal measurement.

## What no measurement can prove

A fully compromised phone can report anything, and a modified app that holds a registered key signs
whatever it is given: the signature proves which installation sent a report, not that the phone is
honest or that the SDK measured what it reports (integration guide, section 9). The measurements raise
the cost of fraud; your backend weighs them with its own business logic.
