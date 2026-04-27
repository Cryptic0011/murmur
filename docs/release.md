# Murmur Release Flow

This repo now includes a basic production release path for website and GitHub DMG distribution.

## Fast path

If you want one guided command for the whole flow, use:

```bash
./scripts/release-interactive.sh
```

It walks you through:

- version/build selection
- DMG creation
- optional git commit
- tag creation
- optional push
- optional GitHub release creation and DMG upload

## What the app does

On app launch, Murmur checks the latest GitHub Release for `Cryptic0011/murmur`.

- Current installed version comes from `MARKETING_VERSION`
- Latest available version comes from the GitHub release tag, such as `v0.2.0`
- If GitHub is newer, Murmur shows a native update prompt
- If the release includes a `.dmg` asset, Murmur opens that asset directly

This is a manual-update flow, not an in-place auto-installer.

## One-time setup

Install local tooling:

```bash
brew install xcodegen
```

Optional for shipping outside local dev:

- Configure a Developer ID Application certificate in Xcode
- Configure a notarytool keychain profile if you want notarized DMGs

Environment variables used by the release script:

- `MURMUR_CODESIGN_IDENTITY`
  Example: `Developer ID Application: Your Name (TEAMID)`
- `MURMUR_NOTARY_PROFILE`
  Example: `murmur-notary`

If those variables are not set, the script still builds the app and DMG, but the output is not set up as a polished notarized public release.

## Every release

### 1. Bump the app version

```bash
./scripts/bump-version.sh 0.2.0
```

That updates:

- `MARKETING_VERSION` to `0.2.0`
- `CURRENT_PROJECT_VERSION` to the next build number
- `Murmur.xcodeproj` via `xcodegen generate`

You can also set the build number explicitly:

```bash
./scripts/bump-version.sh 0.2.0 7
```

### 2. Build the release DMG

Unsigned/local-only build:

```bash
./scripts/build-release-dmg.sh
```

Signed build:

```bash
MURMUR_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
./scripts/build-release-dmg.sh
```

Signed + notarized build:

```bash
MURMUR_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
MURMUR_NOTARY_PROFILE="murmur-notary" \
./scripts/build-release-dmg.sh
```

Artifacts are written to `dist/`:

- `dist/Murmur.dmg`
- `dist/Murmur-vX.Y.Z.dmg`

Or use the all-in-one guided flow:

```bash
./scripts/release-interactive.sh
```

### 3. Create the GitHub Release

Create a release tag that matches the app version.

Example:

- app version: `0.2.0`
- GitHub tag: `v0.2.0`

Recommended GitHub Release asset upload:

- Upload `dist/Murmur.dmg`

Keeping the asset name stable as `Murmur.dmg` gives you a permanent latest-download URL:

```text
https://github.com/Cryptic0011/murmur/releases/latest/download/Murmur.dmg
```

That stable URL is the easiest thing to place on your website download button.

### 4. Update your website

Point your site’s download button to:

```text
https://github.com/Cryptic0011/murmur/releases/latest/download/Murmur.dmg
```

That URL always redirects to the `Murmur.dmg` attached to the newest GitHub release.

## Recommended release checklist

1. Run `./scripts/bump-version.sh X.Y.Z`
2. Commit the version bump
3. Run `./scripts/build-release-dmg.sh`
4. Smoke test the built app
5. Create GitHub release `vX.Y.Z`
6. Upload `dist/Murmur.dmg`
7. Verify website download link
8. Launch the previous installed version and confirm the update prompt appears

## Important production note

For public macOS distribution, the real bar is:

- Developer ID signing
- Notarization

Without those, users may hit Gatekeeper warnings or a rougher install path. The scripts support that flow, but you still need your Apple Developer signing identity and a configured notary profile.
