# Shade TestFlight

Bundle ID: `com.shadeapp.shade`. Version: 1.1.0. The build number must be chosen after inspecting existing uploads in App Store Connect.

## Account inspection comes first

Sign in to Apple Developer and App Store Connect with the authorized Account Holder account. Complete passkey authentication directly in Chrome; never paste passwords, private keys or API keys into chat. Check active program membership, team, agreements, permissions, existing Shade app records, identifiers, certificates and profiles before creating resources. Do not purchase membership or accept agreements automatically.

Verified team `YL2GBDKC79`. Xcode successfully reused the existing cloud-managed distribution certificate and generated the Shade store profile; no certificate was revoked or manually exported. Review any outstanding agreement notices directly in App Store Connect; this workflow does not accept agreements.

Reuse an app record matching the exact bundle ID. If absent, register the explicit identifier and create an iOS app record named Shade with English as its primary language and a unique SKU. The name Shade was unavailable; with user approval the record was created as **Shade Camera & Shaders**, Apple ID `6832135662`, SKU `shade-ios-001`, primary language English (Australia), with Limited Access. The home-screen display name remains Shade. A different team or bundle-ID conflict needs a deliberate decision. Inspect previous build numbers before selecting a new one.

## Local upload

Requires Xcode, its Metal component, XcodeGen, the verified team account in Xcode, and authorized distribution signing. Install XcodeGen or set `XCODEGEN` to its executable path.

Run core tests and shader checks, then:

```sh
export APPLE_TEAM_ID=VERIFIED_TEAM_ID
export BUILD_NUMBER=UNUSED_NUMBER
export XCODEGEN=xcodegen
bash scripts/testflight.sh
```

The script archives with automatic signing, exports an App Store IPA, checks its code signature, bundle ID, build number, team, distribution profile and entitlements, then requests upload through Xcode. Signing may require direct interaction with Xcode or Keychain. It does not accept agreements.

Optional API authentication uses `ASC_KEY_PATH`, `ASC_KEY_ID`, and `ASC_ISSUER_ID`. Keep the `.p8` outside this repository. Build outputs and logs are in `build/testflight/`.

## GitHub Actions

The manual `.github/workflows/testflight.yml` workflow uses a `testflight` environment. It does not run on pushes or pull requests. Make it available on the default branch only after reviewing the change. Configure:

- Environment variable `APPLE_TEAM_ID`: verified Apple team ID.
- Secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY`: an authorized App Store Connect team API key with upload and provisioning access.
- Secrets `DISTRIBUTION_P12_BASE64`, `DISTRIBUTION_P12_PASSWORD`: an existing Apple Distribution certificate exported with its private key and encrypted password, encoded as base64. Set these directly through GitHub's secure secret interface; never commit them or send them in chat.

The runner imports signing material into a temporary keychain, tests core logic and shaders, then archives, verifies and uploads. Automatic provisioning may create or update an appropriate profile using the authorized API key. It requires a valid certificate and account permissions. The cleanup step deletes the temporary keychain and key files. Only failure diagnostics are uploaded as artifacts, retained for seven days. No signing secrets belong in artifacts.

Choose a new positive integer build number for every dispatch, including after a successful upload followed by a processing failure. Runs are serialized. Never reuse an uploaded version/build combination.

## Privacy declarations

`Shade/PrivacyInfo.xcprivacy` declares app-only preferences (CA92.1), metadata of app-container files (C617.1) and user-selected imported files (3B52.1), and available disk capacity checks before recording (E174.1). These are required-reason API declarations, not a completed App Store privacy questionnaire. Data collection, export compliance and beta review answers must be based on actual app behavior and account requirements.

## Confirm the outcome

Successful local compilation is not a signed build. Successful export is not upload. Successful upload is not TestFlight availability.

After upload, open the existing Shade record in App Store Connect, inspect processing status for the exact version and build, and resolve any reported validation issues. Confirm any export-compliance requirements. A processed build must then be available to the appropriate internal tester group; external testing may require Beta App Review. Do not report availability until the TestFlight status and tester access are confirmed. Do not invite additional people without authorization.

Apple references:
- https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds
- https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app
- https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/

## Preparation status

Prepared locally from commit `21e753e`. The previous `/workspace/Shade/TESTFLIGHT.md` and workflow were not present on this Mac or the inspected default branch. The files here are reconstructed preparation, not recovered copies. Apple account inspection, identifier registration, app record creation, signed archive and App Store export are complete. Upload and processing are tracked below.

Local validation: 57 core tests passed; 30 generated Metal sources compiled; Release iPhone build succeeded with Xcode 27.2 after installing Metal Toolchain 27B47. The workflow YAML and embedded shell steps parse. Signed export and upload have not been exercised.

Verified signed export: `build/testflight/export/Shade.ipa`, version 1.1.0 (2), team `YL2GBDKC79`, profile `iOS Team Store Provisioning Profile: com.shadeapp.shade` expiring June 26, 2027. The code signature, distribution-only profile, entitlements and bundled privacy manifest passed local checks. Upload was initiated; consult the current App Store Connect build status before retrying.

App record: https://appstoreconnect.apple.com/apps/6832135662/distribution
