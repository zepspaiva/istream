# iStream for iPhone and iPad

SwiftUI, iOS 18+. `FreeMyTVKit` (a Swift package) talks to the Pi; the app is the screens.

## First time on the Mac

1. Install Xcode (from the App Store) and XcodeGen: `brew install xcodegen`.
2. Put your Apple team id in `ios/Config/Local.xcconfig` (not in git):
   ```
   DEVELOPMENT_TEAM = ABCDE12345
   ```
   It's under Xcode > Settings > Accounts > your team, or developer.apple.com > Account > Membership details.
3. `cd ios && xcodegen && open iStream.xcodeproj`
4. Pick your iPhone as the run destination and press Run (⌘R). The first time, the iPhone asks to allow
   Developer Mode (Settings > Privacy & Security), and the app asks for Local Network access: allow it.

After pulling changes: `xcodegen` again (new files join the project), then Run.

## Checks

- `cd ios/FreeMyTVKit && swift test` runs the package's tests on the Mac (decoding, URLs, which episode Play picks).
- Build errors: copy them from Xcode's Issue navigator (⌘5) and paste them to Claude.

## Layout

| Path | What |
| --- | --- |
| `FreeMyTVKit/` | `PiClient` (the Pi's API, see `pi/API.md`) and the models |
| `iStream/App/` | The app, the setup-or-app switch, the tabs |
| `iStream/Model/` | `AppModel` (Pi, account, profile), `Playback` (sending to the TV), Keychain |
| `iStream/Views/` | Home, Search, Library, TV, the title page, sources, setup and settings |
| `project.yml` | The Xcode project, for XcodeGen |
