# Epson PJLink Projector

Version 1.0.1 - Control4 OS 3.x and later (written against 3.4.x). Defaults are set for the Epson EH-LS12000B / Pro Cinema LS12000B.

## Overview

This driver controls an Epson projector over the network using **PJLink Class 1** (TCP port 4352). It adds a Projector proxy to the Control4 system, so Navigator shows normal power and input controls, and it adds the events, variables, conditionals and commands needed for good programming.

**How it talks to the projector.** The driver does not keep a connection open. Every request (a status poll or a command) opens a short TCP connection, sends one PJLink command, reads the reply and closes the connection. Requests are queued and run one at a time with a short pause between them. This keeps the projector's network stack free of stale sockets, which is the main reason to prefer this driver over drivers that hold a long-lived connection.

**What you get**

- Discrete power on and off, with warm-up and cool-down tracking
- Input selection for HDMI 1 and HDMI 2 (codes are configurable)
- Status polling that speeds up automatically while the projector is changing state
- Events for power, input, faults, connectivity and light source hours
- Device variables and programming conditionals
- Installer tools on the Actions tab: test connection, read the projector's input list, poll now

## Choosing a control method

The driver can talk to the projector in two ways. Pick one in **Control Method**.

| | PJLink (default) | Web (HTTP) |
|---|---|---|
| Transport | TCP port 4352, one short connection per request | HTTP port 80, one short request at a time |
| Power on / off | Discrete commands | On: `IMPWR=ON`. Off: the remote's power key (a toggle, so the driver only sends it when the projector is on) |
| Input selection | Discrete (HDMI 1 = 32, HDMI 2 = 33) | Needs a remote-key request that you find and enter once (see below) |
| Status | Power, input, faults, light source hours, model | Power, input, faults, light source hours |
| Documented by Epson | Yes (EH-LS12000B User's Guide) | No. Epson's documented Web API does not list this model, so this uses the same pages as the projector's own Web Control screen |

Use PJLink unless you have a reason not to. Use Web (HTTP) if PJLink does not answer, or as a second path that does not depend on the PJLink service.

## Requirements

- A Control4 controller running OS 3.x or later
- An Epson projector with PJLink enabled and a wired or wireless network connection
- A fixed IP address for the projector (static, or a DHCP reservation)

## Projector setup

1. Connect the projector to the network and give it a fixed IP address (Network > Network Settings > Wired LAN > IP Settings).
2. Turn PJLink on: **Network > Network Settings > Projector Control > PJLink = On**.
3. Optionally set a PJLink password: **PJLink Password** in the same menu (up to 32 letters and digits, no spaces or symbols). **This is not the Web Control or Remote password.** Enter the same password in the driver. Leave both empty for no authentication.
4. To switch the projector on from standby, set **Operation > Standby Mode = Communication On**. With Communication Off the projector does not answer on the network in standby, so the driver shows it as Offline and cannot wake it.
5. Leave **Control4 SDDP** in the same Projector Control menu as you like. This driver does not use it.
6. Epson does not say whether **Display > Standby Confirmation** (the "are you sure" screen before power-off) affects PJLink power-off. If power-off does not work, set it to Off and test again.

## Web (HTTP) method setup

1. Set **Control Method** to **Web (HTTP)**.
2. Passwords. The status pages use the **Web Control Password** (user EPSONWEB). The Basic Control command pages use the **Remote Password** (user EPSONREMOTE). Enter whichever your projector has set (Network > Network Settings). Epson's guide says no password is set by default.
3. Basic Control must be switched on in the projector (Network > Network Settings > Projector Control > **Basic Control = On**) for the default **Web Command Path** (`/cgi-bin/Remote/directsend`) to work. The other path, `/cgi-bin/directsend`, uses the Web Control password instead.
4. **Standby Mode = Communication On** is needed here too, otherwise the web server is not reachable in standby.
5. Run **Test Connection**. **Last Test Result** should report the power state.
6. **Power on and off** work with the defaults (`IMPWR=ON` and key `6C`, as captured from an EH-LS12000B's Basic Control page). If the projector shows a confirmation screen before switching off, set **Power Off Key Presses** to 2.
7. **Input selection needs one-time set-up.** The projector reports its input over the web (HDMI 1 = `30`, HDMI 2 = `A0`), so the driver shows the current input without any set-up. To *change* input, it needs the remote key your model uses:
   1. Open the projector's Basic Control page in a browser with the developer tools Network tab open.
   2. Click the HDMI button and note the request (for example `directsend?KEY=xx`).
   3. Enter the part after the question mark in **HDMI 1 Select Request** and **HDMI 2 Select Request**. The EH-LS12000B remote has a single HDMI1/HDMI2 key that toggles, so both properties are usually the same. The driver only sends it when the wanted input is not already selected.
   4. Check it with **Send Web Request** (enter `KEY=xx`), then **Query Web Value** with `SOURCE?`.

Until the select requests are set, input changes are ignored (and logged); everything else works.

## Driver setup in Composer Pro

1. Add the **Epson PJLink Projector** driver to the project and place it in the room.
2. In **Properties**, enter the projector's **IP Address**.
3. If the projector uses a PJLink password, enter it in **PJLink Password**. Leave it empty otherwise.
4. On the **Actions** tab, run **Test Connection**. **Last Test Result** should read "OK - projector reports ..." and **Connection Status** should read "Connected".
5. Run **Read Input List**. **Available Inputs** shows the codes your projector supports, for example `32 (HDMI 1), 33 (HDMI 2)`.
6. The defaults are Epson's documented PJLink codes for the EH-LS12000B: **HDMI1 = 32, HDMI2 = 33** (EH-LS12000B User's Guide, "PJLink Support"). If Read Input List shows different codes, set **HDMI 1 Input Code** and **HDMI 2 Input Code** to match.
7. Bind the projector's **HDMI 1** and **HDMI 2** connections to the sources in the room (Connections, Video tab), and bind the projector's **Room Selection - Output** to the room so it is used as the room's video display.
8. Run **Power On**, then **Select Input** from the Actions tab to confirm control before handing over.

## Properties

| Property | Default | Description |
|---|---|---|
| Driver Version | - | Read only. |
| IP Address | empty | Projector IPv4 address. Nothing is polled until this is set. |
| PJLink Password | empty | Leave empty when PJLink authentication is off. Stored masked. |
| HDMI 1 Input Code | 32 | PJLink code the HDMI 1 binding selects. |
| HDMI 2 Input Code | 33 | PJLink code the HDMI 2 binding selects. |
| Control Method | PJLink | PJLink or Web (HTTP). |
| Web Control Password | empty | Web method. Password for user EPSONWEB (status queries). |
| Remote Password | empty | Web method. Password for user EPSONREMOTE (Basic Control commands). |
| Web Command Path | /cgi-bin/Remote/directsend | Web method. Where commands are sent. |
| Power On Request | IMPWR=ON | Web method. directsend parameter that switches on. |
| Power Off Key | 6C | Web method. Remote key sent as `KEY=xx` to switch off. |
| Power Off Key Presses | 1 | Web method. Use 2 if a confirmation screen appears. |
| HDMI 1 Web Source Code | 30 | Web method. Source code reported for HDMI 1. |
| HDMI 2 Web Source Code | A0 | Web method. Source code reported for HDMI 2. |
| HDMI 1 Select Request | empty | Web method. Request that selects HDMI 1 (for example `KEY=xx`). |
| HDMI 2 Select Request | empty | Web method. Request that selects HDMI 2. |
| Idle Polling Interval (seconds) | 30 | How often to poll while nothing is changing (10 to 600). |
| Request Timeout (seconds) | 5 | How long to wait to connect and for each reply (2 to 30). |
| Light Source Hours Alert | 0 | Fires the Light Source Hours Alert event at this many hours. 0 turns it off. |
| Debug Mode | Off | Off, Print (Lua output window) or Log (Director log). |
| Connection Status | - | Read only: Connected, Connecting, Offline, Authentication failed. |
| Power State | - | Read only: On, Standby, Warming Up, Cooling Down, Offline. |
| Current Input | - | Read only. Shows HDMI 1 / HDMI 2 or the PJLink input name. |
| Fault Status | - | Read only. OK, or the projector's reported errors and warnings. |
| Light Source Hours | - | Read only. Refreshed about every 30 minutes while the projector is on. |
| Projector Model | - | Read only. Reported by the projector. |
| Available Inputs | - | Read only. Filled by the Read Input List action. |
| Last Test Result | - | Read only. Filled by the Test Connection action. |

## Navigator and the Projector proxy

- **On** sends the PJLink power-on command. While the projector warms up the proxy reports On.
- **Off** sends the power-off command. As soon as cool-down starts the proxy reports Off, even though the projector is still cooling.
- **Input selection** maps the HDMI 1 / HDMI 2 bindings to the configured PJLink codes. The binding IDs (HDMI 1 = 1021, HDMI 2 = 1022, room selection = 7000) match Control4's own Epson LS12000B driver, so replacing that driver with this one in Composer keeps the existing room bindings.
- When the projector turns off, Navigator's selected input is cleared; it is shown again after the next power-on.
- Changes made with the projector's own remote are picked up by the next poll and reflected in Navigator.

**Commands that arrive at the wrong moment.** Projectors refuse some commands while they are warming up or cooling down, and a room "On" often sends power and input back to back. The driver therefore remembers what was asked for and applies it when the projector is ready:

| Request | Projector is... | What the driver does |
|---|---|---|
| On | in standby | Sends power on immediately. |
| On | cooling down | Waits for standby, then sends power on. |
| Off | on | Sends power off immediately. |
| Off | warming up | Waits until warm-up finishes, then sends power off. |
| Input | on | Sends the input change immediately. |
| Input | warming up or in standby | Applies it once the projector is on. |

A request that cannot be met within **3 minutes** (for example because the projector is unreachable) is dropped, so a projector that comes back later is never switched on by an old request.

## Events

Events appear in Programming under the driver. Power events fire only on real changes, never just because the driver started or reconnected.

| Event | Fires when |
|---|---|
| Projector Powered On | Warm-up has finished and the projector is on. |
| Projector Powered Off | Cool-down has finished and the projector is in standby. |
| Projector Warming Up | Power-on has been accepted and warm-up begins. |
| Projector Cooling Down | Power-off has been accepted and cool-down begins. |
| Input Changed | The input changes (from Control4 or from the remote). |
| Projector Fault | The projector reports a fault or warning (fan, light source, temperature, cover, filter, other). |
| Projector Fault Cleared | The projector no longer reports a fault. |
| Connection Lost | A previously working connection is lost. Not fired if the projector was never reachable. |
| Connection Restored | Communication returns after Connection Lost. |
| Light Source Hours Alert | Light source hours reach the **Light Source Hours Alert** value. Fires once until the hours drop below it again. |

## Actions tab (installer tools)

| Action | Purpose |
|---|---|
| Power On / Power Off | Test power control. |
| Select Input | Choose HDMI 1 or HDMI 2. |
| Poll Now | Query the projector immediately. |
| Test Connection | Check connectivity and authentication. Result in Last Test Result. |
| Read Input List | Ask the projector which inputs it supports. Result in Available Inputs. |
| Send Web Request | Web method. Send one `directsend` parameter such as `KEY=40`. Outcome in Last Test Result. |
| Query Web Value | Web method. Run any ESC/VP21 query such as `SOURCE?` or `PWR?`. Reply in Last Test Result. |
| Reset Connection | Cancel queued requests and clear an authentication lockout. |

## Programming commands

These appear under the driver's device in Programming, alongside the On, Off and input commands provided by the Projector proxy.

| Command | Parameter | Purpose |
|---|---|---|
| Select Input Code | Code | Select any input by its two-character PJLink code. Useful for inputs other than HDMI 1 and 2. |

## Conditionals

| Conditional | Test |
|---|---|
| Power state | is / is not: On, Standby, Warming Up, Cooling Down, Offline |
| Current input | is / is not: HDMI 1, HDMI 2, Other |
| Projector fault | Active or None |
| Light source hours | =, !=, <, <=, >, >= a number |

## Variables

| Variable | Type | Value |
|---|---|---|
| POWER_STATE | String | On, Standby, Warming Up, Cooling Down or Offline |
| CURRENT_INPUT | String | HDMI 1, HDMI 2 or the PJLink input name |
| FAULT_STATUS | String | OK, or the reported errors and warnings |
| LIGHT_SOURCE_HOURS | Number | Hours of the first light source |
| CONNECTED | Bool | 1 while the projector is reachable |

## Programming examples

- **Lights up when the show ends.** When *Projector Cooling Down* fires, raise the room lights. Cooling down starts the moment the projector is switched off, so the room does not wait for the fan.
- **Lights down when the picture is ready.** When *Projector Powered On* fires, dim the lights and lower the screen. This fires after warm-up, so the picture is actually there.
- **Maintenance reminder.** Set **Light Source Hours Alert** and send a notification on *Light Source Hours Alert*.
- **Fault notification.** On *Projector Fault*, send a message. The reason is in the Fault Status variable.
- **Only if on.** Use the *Power state* conditional so a scene only changes the input when the projector is On.

Avoid using Power state in a Loop with short delays. Loops re-evaluate continuously and can load the controller.

## How polling works

| Situation | Poll interval |
|---|---|
| Stable (on or standby) | Idle Polling Interval (default 30 s) |
| Warming up, cooling down, or a request is waiting | 3 s |
| Projector unreachable | 60 s |
| Authentication failed | 5 min (to avoid locking the projector out) |

While stable, each poll also reads the input and faults. Light source hours are read about every 30 minutes while the projector is on. A projector is declared Offline after two failed polls in a row.

## Troubleshooting (Web method)

| Symptom | What to check |
|---|---|
| Authentication failed | A password is wrong or missing. Status queries need the Web Control Password, commands on the default path need the Remote Password. |
| Queries work but power commands fail | Basic Control is off, or the Remote Password is wrong. Try **Web Command Path** `/cgi-bin/directsend`. |
| Projector switches on but not off | Set **Power Off Key Presses** to 2, or check **Power Off Key** with **Send Web Request**. |
| Input does not change | **HDMI 1/2 Select Request** are empty or wrong. See Web (HTTP) method setup, step 7. |
| Light source hours or Fault Status stay Unknown | The projector may not answer `LAMP?` or `ERR?`. Check with **Query Web Value**. The rest of the driver is not affected. |

## Troubleshooting

| Symptom | What to check |
|---|---|
| Connection Status: Offline | Check the IP address and that PJLink is enabled. Try the projector's network settings: if it only responds while on, set its standby network option to Communication On. |
| Authentication failed | The PJLink password is wrong or missing. It is not the Web Control password. Fix it, and the driver reconnects immediately. After repeated failures the projector may block the driver for a while. |
| Cannot switch on from standby | The projector's network is probably off in standby. See Projector setup, step 4. |
| Input does not change | Run Read Input List and compare with the HDMI Input Code properties. A code the projector does not support is dropped and logged. |
| Navigator shows Off while the projector is still cooling | Expected. See Navigator and the Projector proxy. |
| Fault Status shows warnings | Warnings (for example filter) are reported too. They clear when the projector stops reporting them. |
| Need more detail | Set **Debug Mode** to Print, open the driver's Lua tab in Composer and watch the output, or choose Log to write to the Director log. Set it back to Off afterwards. |

## Notes and limitations

- Picture adjustments that Control4's ESC/VP21 Epson driver offers as commands (aspect ratio, color mode, lens position memory, brightness and so on) are not part of PJLink and are not available in this driver.
- There is no video blank (A/V mute) control. Epson lists the PJLink image-mute command (AVMT 11) as not supported on this projector.
- PJLink Class 1 is used, so only features common to all PJLink projectors are available.
- HDMI 1 and HDMI 2 are the only inputs bound to the proxy. Use **Select Input Code** for others.
- Warm-up and cool-down are detected from the projector's own status, so the driver follows physical remote control use too.
- Power and input changes made while the projector is unreachable are not queued indefinitely (see the 3 minute rule above).

## Version history

| Version | Notes |
|---|---|
| 1.0.1 | Fixes from code review: no errors from stray network events in Web mode; clean reconnect after a reset or connect timeout (no spurious CONNECT failure, no leftover socket); INF2 asked once per connection; no input flicker after a slow input switch; a reset cancels remaining power-off key presses in Web mode. |
| 1.0.0 | First release. |
