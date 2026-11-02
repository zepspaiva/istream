# iStream API (v1)

Served by the Nuvio Web fork on the Pi: `http://<pi>:3000/api/v1`. JSON in and out. Errors are
`{ "status": 401, "message": "Sign in first" }` with that HTTP status.

## Auth

`POST /auth/login` with `{ "email", "password" }` (the Nuvio account) returns `{ "token", "user": { "id", "email" } }`.
Send the token on every other call as `Authorization: Bearer <token>`, and the chosen profile as `X-Profile: <1..6>`.
Tokens last 30 days from the last use. `POST /auth/logout` ends the session.

| Method and path | Needs a profile | Returns |
| --- | --- | --- |
| `GET /` | no | `{ name: "istream", api: 1 }`: the app checks it found the Pi |
| `GET /me` | no | `{ user: { id, email }, profile }` |
| `GET /profiles` | no | `[{ id, name, color, avatar }]` |
| `GET /home` | yes | `{ continueWatching: [Resume], rows: [Row] \| null }`; `null` means the add-ons couldn't be reached |
| `GET /catalog/<addon>/<type>/<catalog>?skip=&genre=` | yes | `{ items: [Card] }`: more of one row |
| `GET /search?q=` | yes | `{ movies: [Card], series: [Card] }` |
| `GET /meta/<type>/<id>` | yes | `Title` |
| `GET /streams/<type>/<videoId>?quality=` | yes | `{ best: url, streams: [Stream] }`, playable on the TV, add-on order |
| `GET /subtitles/<type>/<videoId>` | yes | `{ subtitles: [{ lang, url, sdh, addon }] }` |
| `GET /library` | yes | `{ items: [{ id, type, name, poster, year, rating }] }` |
| `POST /library` | yes | Adds `{ id, type, name?, poster?, background?, description?, year? }` |
| `DELETE /library/<type>/<id>` | yes | Removes it |
| `POST /play` | yes | Sends to the TV, see below |
| `GET\|POST /tv/<path>` | no | The TV service, see below |

`type` is `movie` or `series`. A series episode's `videoId` is `<seriesId>:<season>:<episode>` (as in `Title.videos`).

### Shapes

- **Card**: `{ id, type, name, poster, posterShape, background, logo, year, rating, description }`
- **Row**: `{ addon, addonName, type, catalog, title, items: [Card] }`
- **Resume**: `{ id, type, name, poster, background, logo, videoId, season, episode, episodeTitle, progress (0..1), remainingMs }`
- **Title**: Card plus `{ addonName, runtime, released, country, genres, cast, director, certification, status, trailer
  (YouTube id), inLibrary, progress (movie, 0..1), videos: [{ id, season, episode, title, overview, thumbnail,
  released, progress, watched }] }`
- **Stream**: `{ url, addon, name, title, filename, quality, source, videoCodec, audioCodec, hdr, size, languages,
  cached, label }`

### Play

`POST /play` with `{ type, id: videoId, streamUrl?, quality?, start? }`. Without `streamUrl` the Pi picks the best
stream. It waits up to 4 s for subtitles (later ones follow the video), sends everything to Free My TV and returns
`{ job, title, label, url }`. Poll `GET /tv/status` until `job.done` for the steps (Waking the TV, Opening Free My TV,
Loading the stream, Playing). With `"send": false` it returns `{ payload }` instead (for the phone to send itself,
from M2).

### The TV (`/tv/...`, the TV service on port 8080)

| Call | Body | What it does |
| --- | --- | --- |
| `GET /tv/status` | | `{ power: on\|standby\|off, app, appTitle, media, volume, muted, job: { id, step, done, ok, title } }` |
| `GET /tv/inputs` | | `{ inputs: [{ id, name }] }`, the named HDMI inputs (PS5, Switch) |
| `POST /tv/launch` | `{ target }` | An input id or name, `stremio`, `nuvio`, `freemytv`, or any app id. Wakes the TV first |
| `POST /tv/off` | | Turns the TV off |
| `POST /tv/volume` | `{ direction: up\|down\|mute }` | |
| `POST /tv/button` | `{ name }` | `UP DOWN LEFT RIGHT ENTER BACK HOME PLAY PAUSE ...` |
| `POST /tv/text` | `{ text, enter? }` | Types into the TV's focused field |
| `POST /tv/player/cmd` | `{ cmd, ... }` | A command for Free My TV's player |
