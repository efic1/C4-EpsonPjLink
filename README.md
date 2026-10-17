# Epson PJLink Projector - Control4 driver

A DriverWorks driver that controls an Epson projector over **PJLink Class 1** (TCP 4352)
(default) or over the projector's **Web Control** HTTP pages (port 80), one short request at
a time. Both share one projector state machine. See `www/documentation.md` for the
integrator-facing documentation (it is also packaged into the driver as
`www/documentation.rtf` for Composer Pro's Documentation tab).

## Layout

```
driver.xml              properties, proxy + input bindings, events, actions, commands, conditionals
driver.lua              Control4 glue only: properties, proxy, events, variables, actions
lib/pjl_codec.lua       PJLink wire format: build/parse, error and value parsers (pure)
lib/pjl_md5.lua         pure-Lua MD5, used only if C4:Hash("MD5") is unavailable
lib/pjl_client.lua      ephemeral connection per request, FIFO queue, dedupe, priority, auth
lib/epson_http.lua      web-control client: same interface as pjl_client, Digest auth, queue
lib/epson_cmds.lua      maps PJLink-style requests onto json_query / directsend and back
lib/http_digest.lua     HTTP Digest (RFC 2617) as pure functions
lib/pjl_projector.lua   state machine: intent reconciliation, adaptive polling, change detection
www/documentation.md    driver documentation (source of the RTF)
tests/                  212 tests; plain Lua 5.1, no dependencies
tools/                  md_to_rtf.py, check_xml.py
build.sh                runs checks + tests, then builds epson_pjlink.c4z
epson_pjlink.c4zproj    for Control4's DriverPackager (tests/ and tools/ excluded)
```

Only `driver.lua` touches the Control4 API. Everything in `lib/` receives its environment
(network, timers, clock, logging) by injection, which is what makes the stack testable
without a controller.

## Running the tests

```
lua5.1 tests/run.lua            # everything
lua5.1 tests/run.lua cooldown   # only tests whose group/name contains "cooldown"

C4_SYNC=disconnect lua5.1 tests/run.lua   # OFFLINE reported inside NetDisconnect, as Control4 does
C4_SYNC=all        lua5.1 tests/run.lua   # every network event reported inside the call
CHAOS_SEEDS=1000   lua5.1 tests/run.lua "after random"   # many more random sessions (default 120)
```

`build.sh` runs the suite in all three modes. The default (events arrive later, from a timer)
is not what a real controller does: Control4 reports OFFLINE from inside `C4:NetDisconnect`,
and a suite that only ever delivers events later cannot see ordering bugs around that. One
such bug (a PJLink client that waited forever after its first poll) shipped because of it.

LuaJIT works too (`luajit tests/run.lua`). The tests use Lua 5.1 deliberately: it is
the language level Director's LuaJIT mode implements, and `test_manifest.lua` rejects
5.2+ constructs (`goto`, `table.unpack`, `bit32`, ...).

What the suites cover:

| Suite | What it proves |
|---|---|
| codec | Wire format, auth hash, every value parser (power, input, error, lamp, mute) |
| client | One-at-a-time serialization, gaps, dedupe, priority, timeouts, auth success/failure, split packets |
| projector | Warm-up and cool-down handling, command races, stale readings, intent expiry, link loss/recovery, auth lockout backoff, faults, light source alert |
| driver | The real `driver.lua` against a mocked `C4` API: proxy notifications, events, actions, commands, conditionals, variables, properties |
| manifest | `driver.xml` and the Lua code agree: events, actions, commands, conditionals, properties, variables, bindings |

The projector is a behavioural simulator (`tests/helpers.lua`) with a fake clock, so tests
that cover 3 minutes of warm-up run instantly and deterministically.

## Building

```
./build.sh
```

Requires `lua5.1` (or `luajit`), `python3` and `zip`. The build refuses to package if the
tests fail. The result, `epson_pjlink.c4z`, is a plain zip with `driver.xml` at the root.
Import it in Composer Pro (Driver > Add or Update Driver). To use DriverPackager instead,
point it at `epson_pjlink.c4zproj`.

## Design notes

**Ephemeral connections.** Every poll or command is connect, greet, one request, reply,
disconnect. A 300 ms settle gap separates connections and the client waits for the
disconnect to be confirmed before opening the next one, so a stale `OFFLINE` event can
never be mistaken for a failed connect.

**Intent plus reconciliation.** `power_on()`, `power_off()` and `select_input()` record
what the room wants. `reconcile()` sends the next command that is valid for the current
projector state, and polling continues until the intent is met or expires (3 minutes).
This is what makes "Room On = power + input" work, and why a late reconnect cannot
power on a room because of an old request.

**Stale readings.** After a power command is accepted, the projector can keep reporting
its old state for a few seconds. For 8 seconds the opposite reading is ignored, so
Navigator does not flicker.

**Polling.** 30 s idle (configurable), 3 s while changing, 60 s offline, 5 min after an
authentication failure.

**Events** fire on real transitions only. Startup discovery, and recovery into the state
the projector was already in, fire nothing.

## Hardware verification status

The suite proves the logic. It cannot prove behaviour that depends on a real controller
or projector, so this section separates what has been seen on hardware from what has not.

### Confirmed on hardware (EH-LS12000B on a Control4 controller)

- **PJLink control works** as of 1.0.5: the connection opens, power on and polling run.
  This is the build that fixed the client waiting forever when Control4 reports the
  connection closing from inside `NetDisconnect`. 1.0.6 keeps that fix and adds the
  IP-change, stray-greeting and Last Error fixes, which have not been tried on the unit yet.
- **Web method:** `json_query?jsoncallback=PWR?` with Digest auth and a Referer header,
  `directsend?IMPWR=ON` and `directsend?IMPWR=OFF`, and the `KEY=6C` power key.
- **Logging:** log lines appear in Composer Pro's Lua output with Log Level and Log Output
  (debug logs from the unit were used to find the 1.0.5 fix).

### Not verified: check on site

1. **Proxy structure.** Modelled on Control4's own Sanyo PLC-WXE45 and certified Epson LS12000B drivers:
   proxy type `projector`, proxy connection class `TV` (type 2), input bindings
   1021/1022 and room-selection 7000 (the same IDs as Control4's certified Epson LS12000B
   driver, whose 7000 also carries `VIDEO_SELECTION` only). Inputs are matched on
   `binding % 1000`, and input changes are announced for both the video binding and its
   audio twin, as that driver documents is required for video-only inputs. If Composer will not offer the projector as a room's video
   device, compare that binding against a Control4 projector driver.
2. **Input codes.** Defaults are Epson's documented `32` (HDMI 1) and `33` (HDMI 2) for the
   EH-LS12000B (User's Guide, "PJLink Support"). Use the
   *Read Input List* action and correct the properties if your model differs.
3. **Changing the IP while running.** The first connection is confirmed, but changing the
   address calls `C4:CreateNetworkConnection` again on binding 6001 and resets the link.
   The tests cover the driver's side; confirm on the controller that Director picks up the
   new address, and restart the driver if it does not. (The binding is created at runtime
   and is not declared in `driver.xml`; it works in practice, but this is not documented
   Control4 behaviour.)
4. **Timing under load.** Timers (`C4:SetTimer`) and the order in which Control4 delivers
   network events are modelled by the simulator in both orders (later, and inside the
   call). The watchdog's recovery from a stuck client, and behaviour on a controller under
   load, have not been exercised on hardware.
5. **Command names in Programming.** `ExecuteCommand` normalises names (case, spaces,
   underscores), so either spelling Director sends is handled.
6. **PJLink availability.** Whether PJLink keeps working when other network services on
   your projector hang is a property of the projector's firmware, not of this driver.
7. **Standby networking.** The projector must keep its network on in standby to be
   switched on over the network.

If something misbehaves, set **Log Level** to Debug and keep the log; the **Last Error**
property shows the most recent warning or error and its cause.

## Web (HTTP) method: what is and is not verified

Verified against an EH-LS12000B (from captures you provided): the status query
`json_query?jsoncallback=PWR?` with Digest auth and a Referer header, and the Basic Control
requests `directsend?IMPWR=ON` and `directsend?KEY=6C`, plus `directsend?IMPWR=OFF`
(confirmed by hand and through the driver on the same unit). Everything else is from Epson's
ESC/VP21 documentation or is configurable:

- `SOURCE?` replies `30` / `A0` for HDMI1 / HDMI2 (Epson's ESC/VP21 list), and `ERR?` / `LAMP?`
  are assumed to work through `json_query` like any other ESC/VP21 query.
- The remote key that selects an input is not known; it is a property, empty by default.
- Power off uses `directsend?IMPWR=OFF` by default, confirmed working on an EH-LS12000B.
  It is a discrete request, unlike the remote's power key (`KEY=6C`), which toggles and
  would switch a standby projector back on. The key remains as a fallback when
  `Power Off Request` is emptied; `Power Off Key Presses` covers a confirmation screen.
- Which command path (`/cgi-bin/Remote/directsend` or `/cgi-bin/directsend`) a given
  firmware accepts, and which password each one wants, is selectable.

The tests prove the driver's behaviour against a simulator that checks Digest responses with
its own implementation of the formula; they cannot prove what the real projector accepts.

## Deliberately left out

- **Video blank.** Epson's guide lists PJLink `AVMT 11` (image mute on) as non-compatible on
  this projector, so there is no blank control. A test (`test_manifest.lua`) keeps it out
  until someone verifies it on hardware.

## Extending

- **Another input:** add an entry to `INPUTS` in `driver.lua`, a property in `driver.xml`,
  a `<connection>` (video input range 1000-1099), and the name to the `Select Input`
  action list and the `CURRENT_INPUT` conditional. `test_manifest.lua` will tell you what
  you missed.
- **Another event:** add it to the `EVENT` table and to `<events>` (next free id, `NAME` in
  the description), then call `fire(EVENT.X)` from a handler.
- **Another PJLink query:** add a step in `Projector:_followups` and a parser in
  `pjl_codec.lua`, with a test against the simulator.

## License

MIT.
