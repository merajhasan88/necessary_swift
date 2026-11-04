# Necessary for iOS

Device integrity for iOS apps, in Swift. The SDK gives your app a key it never exports — made in the
iPhone's Secure Enclave where it can, and in the Keychain where the Secure Enclave declines — signed
measurements of the phone and of the app running on it, and a proof on each request your app sends —
and, if you turn them on, a second key the person must unlock to approve a request, and a PIN your
backend checks. **It never scores and never decides: your backend does.**

iOS 15 and later, for apps built with Swift 5.9 or later. The measuring code, the collector, is version 8.

The SDK's website is **[necessarysdk.com](https://necessarysdk.com)**.

## Documentation

- [The integration guide](doc/integration_guide.md) — the protocol: what the SDK sends, and how your
  backend checks it.
- [The measurements](doc/measurements.md) — everything the SDK measures on the phone, field by field:
  what each measurement is, how it is taken, and what a complete answer holds.
- [The measurement contract](contract/report-1/android-8-ios-5/) — the report's schema, its rules and
  sample reports, the same for every Necessary SDK. The folder's name is two versions: `report-1` is the
  report's format, and the rest the lowest versions of the measuring code, the collector, that the
  contract accepts on each platform — on iOS 5 (`collector_version`; this SDK's is 8). They are not the iOS
  versions the SDK runs on, which are above.
- [The example app](Example/) puts every piece below in a working app, against the
  [sample backends](backend/) (in the repository, not in the package). [Try the example
  app](#try-the-example-app), below, installs it and tests it step by step.

## Install

With the Swift Package Manager. In Xcode: File → Add Package Dependencies…, enter
`https://github.com/merajhasan88/necessary_swift`, and add the library `Necessary` to your app's target.
In a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/merajhasan88/necessary_swift", from: "0.1.6"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "Necessary", package: "necessary_swift")]),
]
```

The SDK has no dependencies, and carries its own privacy manifest. Your app adds only what you choose to
use, in its `Info.plist`:

- **Location measurements**: `NSLocationWhenInUseUsageDescription`. The SDK never asks by itself: call
  `trust.requestLocationPermission()` from your own screen.
- **Biometric step-up**: `NSFaceIDUsageDescription`.

`DeviceTrust` lives on the main actor, and every call but `close()` is `async`: the Keychain, the Secure
Enclave and the collection run on a queue of the SDK's own, off the main thread, and UIKit and Core
Location are read on the main thread.

## Start

```swift
import Necessary

let trust = DeviceTrust(
    baseURL: "https://api.example.com",
    // The personal measurements your app allows; your backend asks for what it needs of them.
    personalMeasurements: [.screenCapture])

try await trust.start() // loads or makes the key, registers it, proves it holds it
```

`start()` makes the guide's first three calls under `baseURL`: register the installation, ask for a key
challenge, answer it. Your backend answers each as the guide says. A new key is a new installation:
`trust.identity?.createdThisLaunch` tells your app to forget what it kept for the old one.

## Scan

```swift
let scan = try await trust.scan()
let answer = scan.answer // your backend's answer, whole
```

The SDK measures what your backend's challenge asks for — and, of the personal measurements it asks
for, the ones your app enabled — signs the report with the installation key and sends it. It acts on the
guide's protocol errors once (a challenge expired, the installation session expired, the backend lost
the installation, a short wait); any other refusal reaches your app as an `APIError`.

An answer is a `JSONObject`: your backend's JSON, its members in the order they came, an integer apart
from other numbers — `answer["integrity"]?["next"]?.stringValue`.

## Personal measurements

Seven measurements identify a person's phone, network or habits. Each is collected only when your app
enables it **and** your backend's challenge asks for it (`optional_probes`); otherwise the report says
`not_enabled`. None is on unless your app turns it on:

```swift
trust.personalMeasurements = [
    .screenCapture, // the screen recorded, mirrored or sent to AirPlay
    .location, // the last location the phone already knows
]
```

Set them when you make `DeviceTrust`, or change them whenever the person does — in a privacy setting:
the next scan follows, and the installation and its step-up key stay as they are.

| `PersonalMeasurement` | What it reports |
|---|---|
| `.localAddresses` | the phone's own IP addresses, link-local ones left out |
| `.screenCapture` | the screen being recorded, mirrored or sent to AirPlay |
| `.location` | the last location the phone already knows — never a fresh fix, never a prompt |
| `.mockLocation` | whether that location was simulated by software or came from an accessory |
| `.accessibility`, `.notificationAccess`, `.otherAccess` | nothing: iOS shows an app no other app, so these answer `unsupported` |

The location needs the person's permission as well: declare it (Install, above) and ask from your own
screen with `try await trust.requestLocationPermission()`, which answers `precise`, `approximate` or
`none`.

## Prove your own requests

Every request your app sends to your own API can carry a proof that this installation's key signed it,
so a copied session token is useless on another phone:

```swift
let body = (["amount": 25, "to": "payee-7"] as JSONObject).encodedJSON
let proof = try await trust.signRequest(
    method: "POST",
    path: "/v1/transfer",
    bearer: accountSession, // your backend's session for this installation
    body: body) // sent exactly as signed

var request = URLRequest(url: URL(string: "https://api.example.com/v1/transfer")!)
request.httpMethod = "POST"
request.httpBody = Data(body.utf8)
request.setValue("Bearer \(accountSession)", forHTTPHeaderField: "Authorization")
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
for (name, value) in proof.headers { // X-Access-Proof, X-Access-Signature
    request.setValue(value, forHTTPHeaderField: name)
}
```

Each proof serves its request once. `try await trust.send(proof)` sends it through the SDK's transport
instead.

## A scan for one action

For a request that matters — a payment, a new payee — have the scan name it, under the account session
that will send it, and send the scan's report with the request:

```swift
let operation = describeOperation("POST", "/v1/transfer", body)
let scan = try await trust.scan(session: accountSession, operation: operation)
let proof = try await trust.signRequest(
    method: "POST",
    path: "/v1/transfer",
    bearer: accountSession,
    body: body,
    reportId: scan.reportId) // X-Integrity-Report
```

## Step-up: the person approves one request

Turn it on, and choose how the key is unlocked:

```swift
let trust = DeviceTrust(
    baseURL: "https://api.example.com",
    stepUp: StepUpOptions(factor: "passcode", mode: "per_use"))
try await trust.start() // registers the step-up key with the installation

if trust.stepUpUnavailable != nil {
    // This phone cannot make the key -- no passcode, say. Step-up is off here.
}

let proof = try await trust.signRequest(
    method: "POST",
    path: "/v1/transfer",
    bearer: accountSession,
    body: body,
    stepUp: true,
    reason: "Approve the transfer of 25") // what the phone shows the person
```

| Option | Values |
|---|---|
| `factor` | `passcode` (the phone's passcode) or `biometric` (Face ID or Touch ID, as enrolled now) |
| `mode` | `per_use`: the person unlocks the key for every signature — iOS makes per-use keys only |

An app whose backend sets the policy assigns `trust.stepUp` before `start()`.

Removing the passcode, or enrolling another face or finger for a biometric key, makes the key
unusable: an approval then fails with `NativeKeyError` `STEPUP_KEY_INVALIDATED`. The person re-enrols a
new key with their own re-authentication:

```swift
try await trust.reenrolStepUp(
    session: accountSession,
    reauthentication: ["password": .string(password)]) // as your backend requires
```

A new key is made, the person unlocks it to sign its proof, and your backend takes it for that account
alone; approvals use it from then on. The call goes to `/v1/installations/stepup-key`, or to your API's
own path: `StepUpOptions(reenrolPath: …)`. Until your backend has taken the new key — the person
cancelled the prompt, the password was wrong, the answer was lost — approvals fail with
`STEPUP_REENROL_PENDING`, across restarts too: call `reenrolStepUp` again. The same holds for a key the
phone made after the installation was registered — the passcode was off at the first `start()` and set
later, say — since your backend takes a step-up key only at an installation's first registration:
`start()` reports `stepUpUnavailable` `STEPUP_REENROL_PENDING`, and re-enrolment registers the key.

## The app PIN: the person's PIN for one request

Turn it on; the two paths default to the guide's and can be your API's own:

```swift
let trust = DeviceTrust(
    baseURL: "https://api.example.com",
    appPin: AppPinOptions()) // path: "/v1/account/app-pin", proofPath: "/v1/account/app-pin/proof"

// Setting it: with the person's own re-authentication, as your backend requires.
try await trust.setAppPin(session: accountSession, pin: pin, reauthentication: ["password": .string(password)])

// Using it: your backend checks the PIN for this one request, and the request carries its proof.
let proof = try await trust.signRequest(
    method: "POST",
    path: "/v1/transfer",
    bearer: accountSession,
    body: body,
    appPin: pin)
```

The PIN travels once, in a signed body, never in a header, and the SDK never stores it. Protect the
screen while it is typed:

```swift
SecureScreen.protect(true) // the window is covered while the screen is recorded or mirrored
// ... the PIN is typed ...
SecureScreen.protect(false)
```

Calls nest — each `protect(true)` needs its `protect(false)` — and the cover stays until the last one
ends. iOS lets no app block screenshots: the cover is over your app's window, not the system keyboard.
Opening Control Center to start a recording closes the keyboard, so protect whenever the field has
focus, as the example does.

Your backend's refusals reach your app as `APIError` with the guide's codes: `app_pin_not_set`,
`app_pin_invalid` (it counts), `app_pin_locked` (a new PIN, set with the re-authentication, unlocks it).
Step-up and the app PIN combine: your backend decides which requests need which.

## What happens when

| When | What the SDK does |
|---|---|
| The key is lost — a keychain cleared | `start()` makes a new key and a new installation ID; `trust.identity?.createdThisLaunch` is true, so forget what you kept for the old installation. Your backend links the two only provisionally, by the reinstall hint |
| iOS keeps the key across a reinstall | with its ID, the same installation comes back; without it, the SDK proposes a new ID, your backend answers with the one it holds for the key, and the SDK keeps that one |
| The keychain cannot be read | `start()` fails with that `NativeKeyError` (`KEY_LOOKUP_FAILED`), sends nothing and makes no key over the one it may hold: call it again later; if it persists, `reset()` starts a new installation |
| The app's process restarts | nothing is kept in memory: `start()` again finds the same key and installation, and proves it for a new installation session |
| A scene or a window is replaced | screen protection follows: the cover is placed again, on the window the person sees in each scene, whenever a window becomes key, visible or hidden or a scene comes to the foreground — and protection asked for before any window exists covers the first one |
| Two calls at once | `start()`, `prove()`, `loadIdentity()` and the same `scan()` run once, and the second caller gets the first's result; scans for different operations, or asked after the personal measurements changed, run apart |
| A step-up prompt is open | the SDK's other native work — a scan, a request's signature — waits until the person answers it |
| `reset()` or `close()` while calls run | the calls end with `InterruptedCallError` and keep nothing — no session, no installation ID, no report sent, no request proof or app PIN answer handed out; a reset first waits for every write and key change still running, so none outlives it; after a reset, new calls wait for the deletion and never join one made before. A proof handed out before the reset, or a request already sent, is beyond it: reset is local |
| A key cannot be deleted | `reset()` fails with that `NativeKeyError` (`KEY_DELETE_FAILED`): call it again. If it is the installation key, the installation stays as it was, its ID with it; if it is the step-up key, the installation itself is already gone. None to delete is no failure |
| A native call fails | the `NativeKeyError`'s message says what failed and what the system answered beneath it: the keychain's `OSStatus`, or the signing error's domain, code and description |
| A call abandoned, or its answer lost | a scan is simply asked for again — a challenge serves once; the SDK never sends a signed request twice: sign it again, and let your backend decide whether the first one reached it |
| A report over 65,536 bytes | it is never sent: the lists the contract lets a collector shorten are shortened, and say `truncated`; anything else throws an `APIError` `report_too_large` |

The failures, by type: `NativeKeyError` (`code`, `message`) from the phone's keychain or a prompt;
`APIError` (`message`, `statusCode`, `code`, `details`) from your backend or the way to it;
`InterruptedCallError` from a reset or a close; `InvalidAnswerError` for an answer without what the
protocol needs; `UsageError` for a call the SDK cannot serve as made.

## A release build talks only HTTPS

The SDK refuses an `http://` base URL in a release build, with `APIError` `api_base_url_insecure`, so a
mistyped endpoint fails loudly instead of sending tokens in the clear; a debug build may talk plain HTTP
to a sample on your own computer. Without a base URL every call fails with `api_base_url_missing`. Each
call has 15 seconds.

## Your own transport

```swift
let trust = DeviceTrust(over: MyTransport()) // conforms to DeviceTrustTransport
```

A transport sends each message the SDK builds and answers your backend's JSON object, or throws an
`APIError` with its `code`, `message` and `details`. `HTTPTransport(baseURL:session:)` takes a
`URLSession` of your own — one whose delegate evaluates the server's certificate, say. To carry the
messages over an API of your own shape instead, use the pieces directly — `trust.client`,
`collectReport`, `signRequest` — and make the guide's checks in your backend.

## What the SDK never does

It never scores, decides, or tells your app a score; never stores your account session; never sends the
PIN in a header; and uses no platform attestation (App Attest, DeviceCheck). It never exports a private
key, but it cannot prove to your backend where a key is kept: the registration's `key_security` is the
phone's own word, and where the Secure Enclave declines — the Simulator, some configurations — the key
is a software key, which a compromised phone can copy. A fully compromised phone can falsify what it
measures and can use a genuine key to sign what it likes: the measurements raise the cost of fraud, and
your backend weighs them with its own business logic.

## Try the example app

The example app (`Example/`) puts every piece above in a working app, against a sample backend. Its own
README carries the same steps.

### Install it

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
   [`backend/README.md`](backend/README.md).
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

### Test it on a phone, step by step

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

### A session copied to another phone

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

### Measurement by measurement

What each measurement is and every field it carries: [`doc/measurements.md`](doc/measurements.md). On a
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

## Licence

Copyright 2026 Meraj Hasan. Licensed under the Apache License, Version 2.0 (`LICENSE`, `NOTICE`).
