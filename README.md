# HelloIPA

Minimal iOS app project.

Behavior:
- Launches to a white screen
- Shows `hello` in black text

Files added for GitHub Actions:
- `.github/workflows/build-ios-unsigned.yml`
- `scripts/build_unsigned_ipa.sh`
- shared scheme at `HelloIPA.xcodeproj/xcshareddata/xcschemes/HelloIPA.xcscheme`

Windows + GitHub Actions usage:
1. Create a new GitHub repository.
2. Upload this whole `HelloIPAProject` folder to the repository root.
3. Push to `main` or `master`, or manually run the workflow from the Actions tab.
4. Wait for the `Build Unsigned iOS IPA` workflow to finish.
5. Download the artifact named `HelloIPA-unsigned`.
6. Inside it, you will get `HelloIPA.ipa`.

What the workflow does:
- Uses GitHub's cloud macOS runner
- Builds `HelloIPA.app` with code signing disabled
- Packs `Payload/HelloIPA.app` into `HelloIPA.ipa`

Important:
- This is an unsigned IPA intended for your jailbreak-style workflow.
- It is not suitable for normal App Store / stock iPhone installation.
- This local workspace does not have Xcode, so the IPA is produced by GitHub Actions, not here.

Open on macOS with Xcode if needed:
1. Open `HelloIPA.xcodeproj`
2. Build directly to simulator or device

Bundle identifier:
- `com.example.helloipa`
