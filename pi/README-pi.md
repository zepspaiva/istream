# The Raspberry Pi backend

For now the Pi does the content side (Nuvio account, add-ons, streams, subtitles) and can wake the TV and send to it.
The iPhone app talks to it on the home network; later this moves into the app (see the plan).

- `nuvio-web/` (unpacked from the newest `nuvio-web-v<N>.tar`, not in git): a fork of Nuvio Web
  (github.com/orochibraru/nuvio-web, AGPL-3.0) with "play on the TV", a TV tab, and the app's API.
- `server/`: the TV service (Python, aiowebostv): wake, launch, play a stream in Free My TV, subtitles.
- `compose.yaml`: both containers, on the Pi's own network.
- `tvtest.py` / `tvtest.sh`: try TV actions from the Mac. `install_ipk.py`: install any .ipk with the Developer Mode key.
- `channeltest/`: the test app that proved the phone-to-TV channel (LG app2app).

Deploy from the Mac: `./deploy.sh pi@192.168.1.35 ~/.ssh/id_ed25519_pi`.
