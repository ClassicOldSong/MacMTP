# MacMTP

[中文](README_ZH.md)

MacMTP mounts your MTP devices like your Android phones driectly into Finder. Nothing more, nothing less.

## Install

Download MacMTP from [Releases](https://github.com/ClassicOldSong/MacMTP/releases/latest), or install it with Homebrew:

> **Important:** When installing from Releases, move `MacMTP.app` to the Applications folder before opening it.

```sh
brew install --cask ClassicOldSong/tap/macmtp
```

## Requirements

- macOS 13 or later
- Apple Clang and the macOS SDK (Xcode or Command Line Tools)
- CMake 3.24 or later
- Ninja

## Build

```sh
MACMTP_TEAM_ID=TEAMID \
MACMTP_CODE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
./scripts/build.sh
```

## Note

- Unlock the phone and select its MTP/File Transfer USB mode.
- Avoid disconnecting the device during file operations.

## License

MacMTP is licensed under the GNU Lesser General Public License, version 2.1. See [LICENSE](LICENSE). Bundled dependency notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Support

To support MacMTP, please subscribe to my [Patreon](https://www.patreon.com/ClassicOldSong).

[![Support me on Patreon](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fshieldsio-patreon.vercel.app%2Fapi%3Fusername%3DClassicOldsong%26type%3Dpatrons&style=for-the-badge)](https://patreon.com/ClassicOldsong)

This also supports my other projects:

- [AirBeam](https://github.com/ClassicOldSong/AirBeam) - Android external-display air mouse and trackpad
- [Apollo](https://github.com/ClassicOldSong/Apollo)
- [Artemis](https://github.com/ClassicOldSong/moonlight-android)
- [Plexsonic](https://github.com/ClassicOldSong/Plexsonic) - Local bridge exposing Plex music libraries through Subsonic/OpenSubsonic-compatible APIs
- [rEFui](https://github.com/SudoMaker/rEFui)
- [Methanol](https://github.com/SudoMaker/methanol)
