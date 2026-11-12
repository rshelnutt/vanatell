# vanatell

A Windower 4 addon that carries your FFXI chat to the VanaTell app on your
Android phone, and lets you answer from the phone. It talks to your own relay
over a secure WebSocket.

## What it does

Tells, LS1 and LS2 only.

- Every tell you receive or send, and every LS1 and LS2 line, appears on the
  phone. Tells and linkshell lines you type on the keyboard show up there too.
- From the phone you can send a tell, an LS1 line or an LS2 line, and the
  addon types it in game for you.
- Say, party, shout, yell, emotes and system messages are not carried.

## Install

1. Get the addon into `Windower4/addons/vanatell`, either way:
   - `git clone https://github.com/rshelnutt/vanatell-addon.git Windower4/addons/vanatell`
   - or download the repo as a zip and unzip its contents into `Windower4/addons/vanatell`,
     so that `Windower4/addons/vanatell/vanatell.lua` exists.
2. In game, run `//lua load vanatell`. To load it automatically, add
   `lua load vanatell` to `Windower4/scripts/init.txt`.

Until it is paired, loading it prints:

```
vanatell: not paired: set the relay with //vt url wss://<host>, then //vt pair <code>
```

## Pair

1. Run `//vt url wss://your-relay.example.workers.dev`.
   Use `wss://`. Plain `ws://` is accepted only for `localhost` and
   `127.0.0.1`, for testing against a relay on the same PC.
2. In the phone app, get a pairing code: in the Android app, open Settings
   and tap "Generate new pairing code". A code works once, within 10 minutes.
3. Run `//vt pair CODE`, with the 8 letters or digits from the phone in place
   of `CODE`. The addon prints `paired (account ...)`, then
   `connected to relay`.
4. Check with `//vt status`. It should show `connection: connected`.

If relaying was turned off with `//vt off`, pairing prints
`relay is off; //vt on to start`: run `//vt on` to connect.

A new pairing code does not cut off the addon that is already paired. The
relay revokes the old addon token only once the new code is used.

## Commands

| Command | What it does |
| --- | --- |
| `//vt url <wss://host>` | set the relay address |
| `//vt pair <code>` | pair with the code shown on your phone |
| `//vt status` | show the connection state |
| `//vt on \| //vt off` | start or stop relaying |
| `//vt unpair` | forget this addon's relay token |
| `//vt help` | show this list |

## What gets sent and what the phone can do

What the addon sends to the relay:

- One message per tell, LS1 or LS2 line: the channel, whether it came in or
  went out, the sender, the tell target, the text and the time.
- A keepalive every 30 seconds, exactly the bytes `{"type":"ping"}`.
- Nothing else from the game.

What the phone can do in game:

- The phone can only cause `/tell`, `/l` and `/l2`. No other slash command
  and no Windower command can come from the phone.
- Text starting with `/` is refused.
- `;` becomes `,`.
- Non-ASCII becomes `?`, in both directions: Japanese text in game shows as
  `?` on the phone, and emoji or accented letters from the phone show as `?`
  in game. Auto-translate phrases show as `[AT]`.
- 150 bytes maximum. Longer text is cut.
- A tell target must be a character name of 3 to 15 letters.
- While you are logged out, sends from the phone fail with `not logged in`.

## Where your data lives

- `addons/vanatell/data/settings.xml` holds the relay URL and the addon token
  in plain text. Treat it like a password: anyone who has the token can
  connect to your relay as this addon. The addon never prints the token.
- `//vt unpair` clears it: the token and the account id are wiped from the
  file, and the relay URL stays. This forgets the token on this PC only; the
  relay stops accepting it once you pair with a new code.
- Messages captured while offline are held in memory only until reconnect,
  up to 500. When the queue is full the oldest go first. Nothing is written
  to disk, so unloading the addon, closing the game or `//vt unpair` drops
  them. While relaying is off (`//vt off`) or the addon is not paired,
  nothing is captured.

## Troubleshooting

`//vt status` shows the state on its `connection:` line.

- `token rejected` -> pair again. The relay turned the addon token down, and
  the addon does not retry until you pair again. The game log says why:
  - `relay rejected the addon token; pair again with //vt pair <code>`: the
    token was revoked (close code 4001) or the relay does not know it. Get
    a new code on the phone, then run `//vt pair CODE`.
  - `account deleted on the phone; set up the app again, then //vt pair <code>`:
    the account was deleted on the phone (close code 4000). Set up the app
    again, then run `//vt pair CODE`.
- `retrying in Ns` -> check the URL and the relay. The reason for the last
  failure follows in parentheses. The addon retries on its own, waiting 1 s
  at first and doubling the wait up to 60 s.
  - On Windows, a relay that refuses the connection shows as `timeout` after
    about 10 seconds, rather than as `connection refused`. It is still a
    failed connect, and the same retry wait applies.
  - The relay's address is looked up once per host, and looked up again
    after 3 failed connects in a row, so a relay that moved is found again
    on its own.

## Third-party

- `json.lua`: rxi, MIT license, from
  `https://raw.githubusercontent.com/rxi/json.lua/v0.1.2/json.lua`,
  sha256 `b13df59b32c77db3bec7a1619280ea77ee5014e715ccffaa4876d857e3e9ab87`.
- `cacert.pem`: the Mozilla CA bundle, MPL-2.0, from
  `https://curl.se/ca/cacert.pem`. Certificate data from Mozilla as of
  `Thu Nov  5 04:12:01 2026 GMT`, downloaded 2026-11-11,
  sha256 `427c064216761a1e72a8b30f0d954d08cb6e4435a82091fb865afd20c8497285`.
  The addon checks the relay's certificate against it.

To refresh the bundle, run this in the `vanatell` folder:

```
curl -fsSL https://curl.se/ca/cacert.pem -o cacert.pem
curl -fsSL https://curl.se/ca/cacert.pem.sha256
shasum -a 256 cacert.pem
```

The hash the second command prints must equal the hash from the third. If
they differ, do not use the file; download it again. On Windows,
`certutil -hashfile cacert.pem SHA256` prints the same hash as `shasum`. The
`## Certificate data from Mozilla as of:` line near the top of `cacert.pem`
gives the new date.
