# GMOD-RampFix
A port of a port of Momentum mod's RampFix.

---

## Installation

Simply place the RampFix folder in garrysmod/addons and restart your server.

---
## Console Variables

These console variables control the behaviour of the ramp-bug correction algorithm.

The system works by emulating parts of `CGameMovement::TryPlayerMove` in Lua and applying corrective retraces and velocity restoration when invalid ramp collision states are detected.

All variables are **server-created and replicated**.

---

### `momsurffix_ramp_bumpcount`

**Default:** `8`
**Min:** `4`
**Max:** `16`

Defines the maximum number of collision resolution iterations performed while attempting to resolve ramp-related movement errors.

Internally this controls how many times the fix will:

* perform clipped velocity resolution against collision planes
* attempt fallback retrace probing when movement traces become invalid
* try to recover from “stuck on ramp” states

Lower values:

* Less CPU cost
* May fail to resolve complex multi-plane ramp collisions
* Rampbugs may pass through without correction

Higher values:

* More robust correction on curved / segmented surf ramps
* Increased chance of over-correction in extreme edge cases
* Slightly higher movement processing cost

Example:

```
momsurffix_ramp_bumpcount 10
```

---

### `momsurffix_ramp_initial_retrace_length`

**Default:** `0.2`
**Min:** `0.2`
**Max:** `5.0`

Controls the positional offset distance used when performing fallback hull retraces to discover a valid ramp collision plane.

When the algorithm detects an invalid movement trace, it generates a **3×3×3 offset probe cube** around the player origin and accumulates valid plane normals.

This value scales:

* the search volume size
* how far the player origin is nudged along the recovered ramp normal

Lower values:

* More precise surf feel
* May fail to recover from deep penetration or high-speed desync

Higher values:

* Stronger escape from invalid collision states
* Can slightly alter tight ramp edge behaviour

Example:

```
momsurffix_ramp_initial_retrace_length 0.35
```

---

### `momsurffix_enable_noclip_workaround`

**Default:** `1`
**Min:** `0`
**Max:** `1`

Enables a safeguard that prevents ramp correction logic from using invalid plane recovery when the player is transitioning out of noclip-like movement states.

When disabled:

* fallback retrace probing is allowed even if the velocity profile suggests a noclip transition
* this can help debugging but may introduce incorrect ramp plane recovery

When enabled:

* the fix requires more physically plausible velocity direction before performing plane reconstruction
* reduces false rampbug detection after noclip exits

Example:

```
momsurffix_enable_noclip_workaround 0
```

---

### `momsurffix_restore_ticks_back`

**Default:** `2`
**Min:** `1`
**Max:** `10`

Controls how far back in the stored velocity history the system looks when attempting **low-speed ramp transition recovery**.

If the player suddenly loses speed below the internal threshold (~100 u/s) while recent historical velocity indicates valid ramp travel, the fix may restore an earlier velocity sample.

Lower values:

* Restores more recent velocity samples
* More responsive but less stable
* Can restore a velocity already degraded by rampbug onset

Higher values:

* Restores older pre-failure velocity
* More stable speed recovery
* Slightly less accurate to the player’s immediate movement intent

Example:

```
momsurffix_restore_ticks_back 3
```

