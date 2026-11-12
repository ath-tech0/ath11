# HYperRegedit / 3105

This archive contains the Xcode project, SwiftUI views, services, assets, patch packages, and native support files.

## Structure

- `ThreeOneOSFive/views`: SwiftUI screens and design system.
- `ThreeOneOSFive/helpers`: storage, file operations, patch packages, activation, and app services.
- `ThreeOneOSFive/Patches`: bundled patch packages.
- `ThreeOneOSFive/exploit` and `ThreeOneOSFive/kexploit`: original native support files included in the source archive.
- `ThreeOneOSFive.xcodeproj`: Xcode project.

## License activation

The app now verifies keys through the Cloudflare Worker endpoint `/api/license/mobile-verify`. Set `LicenseServerURL` in `ThreeOneOSFive/Info.plist` to the deployed Worker URL before building. The Telegram bot and all API secrets remain server-side in Cloudflare Worker secrets.

See [API_INTEGRATION.md](API_INTEGRATION.md) for deployment and integration details.

## Build

Build on macOS with Xcode: `./build_unsigned.sh`, or use the included GitHub Actions workflow. The resulting IPA must be signed using an authorized deployment method before installation.
