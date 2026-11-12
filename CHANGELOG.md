# Changelog

All notable changes to VanaTell are listed in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and VanaTell follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!--
How a release is cut (no scripts needed):

1. Move the entries under [Unreleased] into a new "## [X.Y.Z] - YYYY-MM-DD"
   section, add its compare link at the bottom, and set
   _addon.version = 'X.Y.Z' in vanatell.lua. Commit.
2. Tag that commit: git tag vX.Y.Z
3. Zip the shipped files into a vanatell/ folder:
   git archive --format=zip --prefix=vanatell/ -o vanatell-vX.Y.Z.zip vX.Y.Z
   The zip then holds exactly the addon folder as tagged.
4. Push the commit and the tag, create a GitHub release for vX.Y.Z on the
   Releases page, paste this version's section as the notes, and attach
   vanatell-vX.Y.Z.zip.
-->

## [Unreleased]

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

[Unreleased]: https://github.com/rshelnutt/vanatell/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/rshelnutt/vanatell/releases/tag/v0.1.0
