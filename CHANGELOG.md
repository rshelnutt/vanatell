# Changelog

All notable changes to VanaTell are listed in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and VanaTell follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!--
How a release is cut (no scripts needed):

1. Move the entries under [Unreleased] into a new "## [X.Y.Z] - YYYY-MM-DD"
   section, add its compare link at the bottom, and set
   _addon.version = 'X.Y.Z' in vanatell.lua and addon.version = 'X.Y.Z' in
   ashita/vanatell.lua. Commit.
2. Tag that commit: git tag vX.Y.Z
3. Zip the shipped files into a vanatell/ folder for Windower (git archive
   leaves out tools/ and ashita/, as .gitattributes says):
   git archive --format=zip --prefix=vanatell/ -o vanatell-vX.Y.Z.zip vX.Y.Z
   The zip then holds exactly the addon folder as tagged.
4. Zip the Ashita addon: the same files in a vanatell/ folder, with
   vanatell.lua renamed main.lua and ashita/vanatell.lua as vanatell.lua:
   B=$(mktemp -d) && mkdir "$B/vanatell"
   git archive vX.Y.Z | tar -x -C "$B/vanatell"
   mv "$B/vanatell/vanatell.lua" "$B/vanatell/main.lua"
   git show vX.Y.Z:ashita/vanatell.lua > "$B/vanatell/vanatell.lua"
   (cd "$B" && zip -qrX - vanatell) > vanatell-ashita-vX.Y.Z.zip
5. Push the commit and the tag, create a GitHub release for vX.Y.Z on the
   Releases page, paste this version's section as the notes, and attach
   vanatell-vX.Y.Z.zip and vanatell-ashita-vX.Y.Z.zip.
-->

## [Unreleased]

## [0.2.0] - 2026-11-13

### Added

- VanaTell for Ashita v4: the same tells, party and linkshell chat, pairing
  and commands for Ashita players, with each command typed with one slash
  (`/vt pair CODE`). Unzip `vanatell-ashita-v0.2.0.zip` into `Ashita/addons/`
  and type `/addon load vanatell`.

## [0.1.2] - 2026-11-12

### Fixed

- Japanese chat: lines from Japanese players show on the phone instead of
  "???", and Japanese typed on the phone reaches the game.

## [0.1.1] - 2026-11-12

### Added

- Party chat on your phone: every party line you receive or send is relayed
  to the VanaTell app, and a party line sent from the app is typed in game
  with `/p`. `//vt help` lists party among the relayed channels.
- `//vt url default` goes back to the built-in relay after a custom one.

### Changed

- In-game messages are prefixed `VanaTell:`.
- The built-in relay address is never printed; `//vt status` says
  `relay: built-in` unless a custom relay is set.
- The trust-root bundle is trimmed to the roots the relay can chain to and
  renamed `relay-roots.txt`, so phones and PCs no longer offer to install it.
- Auto-translate phrases are expanded to their text before relaying.

## [0.1.0] - 2026-11-12

### Added

- Tells and linkshell chat on your phone: every tell you receive or send, and
  every LS1 and LS2 line, is relayed to the VanaTell Android app.
- Replies from the phone: a tell, an LS1 line or an LS2 line sent from the app
  is typed in game for you.
- Pairing by code: `//vt pair CODE` with the code the app shows.
- A built-in relay address, so there is nothing to configure. `//vt url` is an
  override for people who run their own relay.
- Linkshell detection: the name of the linkshell equipped in slot 1 and in
  slot 2, and whether each slot has one equipped, sent to the app and shown on
  the `linkshells:` line of `//vt status`.
- Case-insensitive pair codes: upper or lower case both work, and dashes or
  spaces copied from the phone are ignored.

[Unreleased]: https://github.com/rshelnutt/vanatell/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/rshelnutt/vanatell/releases/tag/v0.2.0
[0.1.2]: https://github.com/rshelnutt/vanatell/releases/tag/v0.1.2
[0.1.1]: https://github.com/rshelnutt/vanatell/releases/tag/v0.1.1
[0.1.0]: https://github.com/rshelnutt/vanatell/releases/tag/v0.1.0
