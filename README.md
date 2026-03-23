# GMOD-RampFix
A port of a port of Momentum mod's RampFix.

---

## Installation

Simply place the RampFix folder in garrysmod/addons and restart your server.

---

## Console Variables

These convars control the behaviour of the ramp / surf bug mitigation system.

All variables are **server-side** and can be changed live.

---

### `momsurffix_ramp_bumpcount`

**Default:** `8`
**Min:** `4`
**Max:** `16`

Controls how many consecutive ramp collision “bumps” must be detected before the fix logic activates.

Lower values:

* More aggressive correction
* Higher chance of false positives

Higher values:

* More tolerant movement behaviour
* Slightly weaker protection against ramp exploits

Example:

```
momsurffix_ramp_bumpcount 6
```

---

### `momsurffix_ramp_initial_retrace_length`

**Default:** `0.2`
**Min:** `0.2`
**Max:** `5.0`

Defines how far (in Hammer units) the movement system offsets when performing corrective retraces after detecting invalid ramp interaction.

Lower values:

* More precise correction
* May fail on steep or complex surf geometry

Higher values:

* Stronger recovery behaviour
* Can slightly alter edge-case surf physics feel

Example:

```
momsurffix_ramp_initial_retrace_length 0.4
```

---

### `momsurffix_enable_noclip_workaround`

**Default:** `1`
**Min:** `0`
**Max:** `1`

Enables a workaround that prevents invalid ramp traces after players exit noclip.

Recommended to keep enabled unless debugging movement traces.

Example:

```
momsurffix_enable_noclip_workaround 0
```

---

### `momsurffix_restore_ticks_back`

**Default:** `2`
**Min:** `1`
**Max:** `MAX_VELOCITY_HISTORY_TICKS_`

Specifies how many historical movement ticks are considered when restoring player velocity during low-speed ramp corrections.

Lower values:

* Faster correction response
* Less smoothing

Higher values:

* More stable recovery
* Slightly increased computational overhead

Example:

```
momsurffix_restore_ticks_back 3
```
