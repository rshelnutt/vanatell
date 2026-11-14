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

## [0.2.3] - 2026-11-13

### Fixed

- A linkshell equipped from your Mog Satchel, Sack or Case now shows on the
  phone. The addon only looked in your inventory (and the wardrobes, which never
  hold linkshells), so a pearl worn from the satchel was never found: the phone
  showed no linkshell in that slot and its lines arrived as an unknown
  linkshell you could not reply to.

## [0.2.2] - 2026-11-13

### Fixed

- Linkshells after login and zoning: for a while after you log in or zone,
  the game can show a linkshell in the wrong slot (slot 2's shell as slot 1).
  The addon now waits until what it reads has stayed the same for 10 seconds
  before it tells the phone, and keeps checking for two minutes, so the phone
  never shows a wrong slot and settles on the right one without re-equipping.
- Ashita: a leader's Linkshell in slot 1 is found as soon as the addon loads,
  as on Windower, instead of only after a zone or a re-equip.

### Added

- The addon says which version loaded: `VanaTell 0.2.2 loaded` in the
  Windower console, and in Ashita's log file on Ashita.

## [0.2.1] - 2026-11-13

### Fixed

- Linkshells: a linkshell the game does not mark the usual way is now found.
  A leader's Linkshell in slot 1 and some pearls in slot 2 read as "no
  linkshell equipped", so their chat landed under "Unknown linkshell" on the
  phone and could not be answered. On Windower slot 1 now shows as soon as
  the addon loads; slot 2 (and, on Ashita, either slot) shows after you zone
  or equip the pearl again.

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

[Unreleased]: https://github.com/rshelnutt/vanatell/compare/v0.2.2...HEAD
[0.2.2]: https://github.com/rshelnutt/vanatell/releases/tag/v0.2.2
[0.2.1]: https://github.com/rshelnutt/vanatell/releases/tag/v0.2.1
[0.2.0]: https://github.com/rshelnutt/vanatell/releases/tag/v0.2.0
[0.1.2]: https://github.com/rshelnutt/vanatell/releases/tag/v0.1.2
[0.1.1]: https://github.com/rshelnutt/vanatell/releases/tag/v0.1.1
[0.1.0]: https://github.com/rshelnutt/vanatell/releases/tag/v0.1.0
