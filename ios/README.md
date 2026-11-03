# iStream for iPhone and iPad

SwiftUI, iOS 18+. No server: the app reads the person's add-ons itself (`FreeMyTVKit`), keeps their library and
progress on the device (SwiftData; iCloud in M5), and talks to the LG TV directly (its remote API and Free My TV's
channel).

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
| `FreeMyTVKit/` | The add-on engine (Stremio's protocol), stream picking, subtitles, the Stremio import, the models; `PiClient` only to carry the TV's wake addresses over from the Pi |
| `iStream/App/` | The app, the setup-or-app switch, the tabs |
| `iStream/Model/` | `AppModel`, `ContentService` (what the screens ask for), `LocalStore` (SwiftData), `TVConnection` (the TV), `Playback`, the Live Activity |
| `iStream/Views/` | Home, Search, Library, TV, the title page, sources, Now Playing, setup (add-ons, the TV) and settings |
| `Widgets/`, `Shared/` | The Live Activity (Lock Screen and Dynamic Island) |
| `project.yml` | The Xcode project, for XcodeGen |
