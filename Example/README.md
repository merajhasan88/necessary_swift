# Necessary example

The Necessary SDK in a working app, against one of its sample backends ([`../backend/`](../backend/)): the
app side of device integrity, in code. The integration guide (`../doc/integration_guide.md`) is the
backend side, in words.

## Install it

The sample backends live in the repository, not in the package, so start from a clone. You need a Mac
with Xcode 15 or later.

1. Clone the repository:

   ```sh
   git clone https://github.com/merajhasan88/necessary_swift.git
   cd necessary_swift
   ```

2. Start a sample backend on your computer. It answers on `127.0.0.1` only. In Python 3.10 or later:

   ```sh
   pip install --require-hashes -r backend/python/requirements.txt
   python3 backend/python/server.py --port 8787 --schema contract/report-1/android-8-ios-5/report.schema.json
   ```

   The TypeScript and C# samples run the same way; their commands are in
   [`backend/README.md`](../backend/README.md).
3. Make the example's Xcode project, with [XcodeGen](https://github.com/yonaskolb/XcodeGen), and open it:

   ```sh
   brew install xcodegen
   cd Example && xcodegen generate && open NecessaryExample.xcodeproj
   ```

4. Run it:
   - **On the iOS Simulator**, a debug build reaches your computer at `http://127.0.0.1:8787`, the
     example's default: choose a simulator and Run.
   - **On an iPhone**, choose your team under Signing & Capabilities. An iPhone reaches your computer
     over your network, and a release build talks only HTTPS: put the sample behind an HTTPS proxy on a
     name the phone can resolve, with a certificate the phone trusts, and give that address in the
     build setting `NECESSARY_BACKEND_URL` (the target's Build Settings, or `xcodebuild …
     NECESSARY_BACKEND_URL=https://backend.example.com`).

   To offer several backends, name each in `NECESSARY_BACKENDS`:
   `Python=https://…;TypeScript=https://…`. A development build signed by Xcode measures itself as one —
   `get_task_allow` in `code_signing` — so judge the measurements on a release build.

## What the screen shows

Each section opens and closes; each result says whether the backend did what it should.

- **Installation**: start (make the key, register it, prove it), prove again, and a new installation —
  the key, its ID and the step-up key deleted and made again, as a reinstall would.
- **Measurements**: the personal measurements this app allows, the location permission, and a scan —
  every measurement the signed report carried, grouped by what it catches, each with its status and the
  fields the phone sent.
- **Account**: the sample's sign-in, an account session for this installation.
- **Requests**: a request with its proof, and a sensitive one that needs the person's approval — the
  step-up key, unlocked with the passcode, or the app PIN; and the step-up key re-enrolled.
- **Requests a backend must refuse**: made wrong on purpose — sent twice, its body changed, sent to
  another path, signed ten minutes ago, and a session copied from another phone.
- **Log**: every result, the latest first. Each also goes to the device log, prefixed `EXAMPLE:`.

## Test it on a phone, step by step

With several backends (`NECESSARY_BACKENDS`), tap one at the top and run the steps once for each. Every
result line carries a check when the backend did what it should, a red mark when it did not.

1. **Installation → Start.** If the phone asks to find devices on your local network, allow it. Expect:
   `Installation …, proved; step-up on.` On a phone without a passcode, step-up is off: `step-up off here
   (…)`, and step 7 cannot pass.
2. **Measurements:** switch on **All of them**, tap **Ask for the location permission** and allow it.
   Once is enough; the switches reset when the app restarts.
3. **Scan.** Expect: `The backend answered next: allow, report …` — the sample backends answer
   `scan_again` when a measurement could not be read, and `review` when its figures contradict each
   other. Under **Hooks, gadgets and memory changes** every row reads `measured`, none `not asked`. Open
   any row for the fields the phone sent.
4. **Account → Sign in.** Expect: `An account session for this installation.`
5. **Requests → Protected request.** Expect: a check, `{"done":"/v1/demo/echo"}`.
6. **Sensitive, without approval.** Expect: a check, `Refused, as it should be: 403 needs_approval`.
7. **Sensitive, with step-up**, then unlock with the phone's passcode. Expect: a check,
   `{"done":"/v1/demo/sensitive"}`.
8. Type 6 digits in **App PIN**, then **Set the app PIN**. Expect: a check, `Set, with the account
   password.`
9. **Sensitive, with the app PIN.** Expect: a check, `{"done":"/v1/demo/sensitive"}`.
10. **Requests a backend must refuse:** tap each of the four. Expect a check on each: `Refused, as it
    should be: 401 proof_reused` for the request sent twice, `401 proof_not_accepted` for the other three.

If the phone's passcode is removed and set again, the step-up key dies: step 7 then shows `The phone said
STEPUP_KEY_INVALIDATED`. Tap **Re-enrol the step-up key** and unlock with the passcode — expect a check,
`{"stepup_key_registered":true}` — and step 7 passes again. The new key is that account's alone. If the
passcode was off at step 1 and set afterwards, **Start again** says `step-up off here
(STEPUP_REENROL_PENDING)`: the backend took the installation without a step-up key, so re-enrol the same
way after step 4.

The app PIN belongs to the account, not to the phone. Phones signed in with the same handle share it: a
PIN set on one unlocks requests on the other, and before any is set, step 9 answers `app_pin_not_set`.
Sign in with another handle for an account of its own.

## A session copied to another phone

A session token copied off one phone must be useless on another. You need two phones running the
example against the same backend.

1. **Phone A:** steps 1 and 4 above, then **Requests a backend must refuse → Copy this phone's session**.
   Expect: `Copied this phone's session`.
2. Get the copied text to phone B, for example in a note or a message to yourself. It holds phone A's
   session and installation ID; the sample's sessions last ten minutes.
3. **Phone B:** step 1 above, on the same backend.
4. **Phone B:** paste the text into **A session from another phone**, then tap **Use it here**. Expect: a
   check, `Refused, as it should be: 401 invalid_installation_signature`. Phone B's key cannot sign for
   phone A's installation, even when the request names it.

If step 4 reads `The session is no longer valid: sign in again`, phone A's session has expired: sign in
again on phone A and copy it again.

## Measurement by measurement

What each measurement is and every field it carries: [`doc/measurements.md`](../doc/measurements.md). On a
phone of your own you can watch these change, one at a time: make the change, tap **Scan**, open the
measurement's row, and change it back afterwards.

| Measurement | Change | The row then shows |
|---|---|---|
| `network` | turn on a VPN app; or set a manual proxy on your Wi-Fi network | `vpn_active` true, the tunnel's interface in `scoped_interfaces`; `http_proxy_configured` true |
| `local_addresses` | switch between Wi-Fi and mobile data | the phone's own addresses, per interface |
| `screen_capture` | start a screen recording from Control Center; connect an external display | `recording` true; `external_displays` 1 |
| `location` | tap **Ask for the location permission** and allow it | the `permission`, the coordinates and their `age_seconds` |
| `mock_location` | simulate a location from Xcode while the app runs from it | `mock` true |
| `app_identity` | install a build of the example made with other code | other hashes and sizes |
| `code_signing` | run a development build from Xcode | `get_task_allow` true |

The rest — jailbreak traces, Frida and other hooking tools, code changed in memory, the Simulator —
needs a device you are allowed to change: never a phone you depend on. On the iOS Simulator
`simulator.is_simulator` is true. Frida on a test device shows in `dyld_images` and `code_integrity`.
