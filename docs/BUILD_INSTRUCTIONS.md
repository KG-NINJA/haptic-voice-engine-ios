# Build instructions

Requirements: macOS with Xcode 26 (tested with Xcode 26.6 / iOS SDK 26.5), XcodeGen
(`brew install xcodegen`). Deployment target iOS 17.0. The project file is generated from
`project.yml` and committed.

```bash
xcodegen generate
# Unit + UI tests (Simulator; the simulator has no Taptic Engine, UI tests use the simulated backend)
xcodebuild test -project HapticVoiceEngine.xcodeproj -scheme HapticVoiceEngine \
  -destination 'platform=iOS Simulator,name=iPhone 17'
# Unsigned device IPA -> build/ipa/HapticVoiceEngine-unsigned.ipa
./scripts/build_unsigned_ipa.sh
```

## Installing on an iPhone without a Mac (iloader on Linux)
1. Copy `HapticVoiceEngine-unsigned.ipa` to the Linux PC and connect the iPhone over USB.
2. In iloader select the iPhone under iDevice, sign in with your Apple Account, then
   **Import IPA** and pick the file. iloader re-signs it with a free development certificate.
3. On the iPhone: Settings → General → VPN & Device Management → trust the developer;
   enable Developer Mode if asked (Settings → Privacy & Security → Developer Mode, reboot).
4. Free-account signatures expire after 7 days; re-import the IPA to refresh.

With a paid account in Xcode you can instead set a team in the target's Signing settings and
run directly. The bundle id is `dev.kgninja.HapticVoiceEngine`; iloader may rewrite it.

## Launch arguments (testing only)
| Argument | Effect |
|---|---|
| `-uiTestingSimulatedHaptics` | simulated backend, no physical output, UI shows SIMULATED |
| `-uiTestingShortCooldown` | 0.3 s cooldown |
| `-uiTestingRealBackend` | force Core Haptics backend |
