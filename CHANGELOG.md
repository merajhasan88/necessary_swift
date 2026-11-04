# Changelog

## 0.1.6

- `dyld_images` leaves the app's own folder and main executable out of what it reads as names.
- A step-up key the phone lost and a re-enrolment made again leaves approvals waiting until the backend
  takes it, like a key replaced.
- The Python sample backend answers a malformed request with a refusal.
- `report.schema.json`: `installer_package` is left out or null when no installer is named.
- `doc/measurements.md`: every SDK sends its report in the same format.

## 0.1.5

The first release: the Necessary SDK for iOS apps, in Swift, at the protocol and measurements of the
other Necessary SDKs' version 0.1.5.

- **The installation key**: EC P-256 in the Secure Enclave — a Keychain key, marked not extractable,
  where the Secure Enclave declines — never exportable; its public JWK, its thumbprint, and what the
  phone says about it (`key_security`). Making and deleting a key run one at a time in the process.
- **Registration, proof of possession and the installation session** (the guide's section 1), with the
  reinstall hint (`idfv_sha256`). The installation ID is kept in the Keychain, on this device only,
  readable after the first unlock, never synchronized.
- **The scan** (section 2): the collector, version 8, measures what the backend's challenge asks for;
  the report is signed as sent. The app's code in memory is compared with its files image by image —
  only with the build that is running, an image the App Store encrypted skipped and named, never
  compared — and a read that failed is in `unread`, or the probe answers `error`: never a clean value.
- **The personal measurements** (section 8): seven, each measured only when the app enables it and the
  backend asks for it; three of them answer `unsupported`, since iOS shows an app no other app.
- **Request proofs** (section 3), **a scan for one action**, **step-up** with a second key the person
  unlocks with the passcode or a biometric for every signature, re-enrolled with the person's own
  re-authentication, and **the app PIN**, checked by the backend for one request.
- **The API** (section 4): the five calls under the base URL the app sets, HTTPS only in a release
  build, 15 seconds a call; the protocol errors acted on once; or the app's own transport.
- **One installation at a time**: `reset()` and `close()` end the calls still running, which keep
  nothing; a reset waits for every write and key change still running.
- **Screen covers** while a secret is typed and the screen is recorded or mirrored.
- The shared vectors byte for byte, the plugin's tests translated, the end-to-end test against the three
  sample backends, and the example app.
