# Couchwire

Watch from the sofa without the TV remote: browse on an iPhone or iPad, tap, and the TV wakes and plays.

| Folder | What it is |
| --- | --- |
| `tv/` | Couchwire's TV app (`com.zeeh.couchwire.tv`): a fork of [Free My TV](https://github.com/simbasjungles/free-my-tv) (launcher + player, MIT), with the phone channel and our changes. Build: `cd tv && python3 webos/build.py` → `Couchwire-webos.ipk`; install: `python3 webos/install.py <TV IP>` |
| `ios/` | The iPhone and iPad app (SwiftUI) |
| `pi/` | The Raspberry Pi backend of M1 to M3 (Docker), no longer needed; kept for its TV test tools |

The plan: https://claude.ai/artifact/S9kc3b2jCvu1QM2WXjSN52
