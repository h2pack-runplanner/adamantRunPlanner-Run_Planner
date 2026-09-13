# Development

This repository contains the Hades II game module for
[Run Planner](https://github.com/maybe-adamant/RunPlanner). The application owns
authoring, simulation, and validation. This module consumes its published
execution plans; it is not a second planner or simulator.

## Repository layout

- `src/` — the active Hades II module.
- `fixtures/` — execution plans shared with the planner for compatibility testing.
- `tests/` — Lua unit and integration tests.

Within `src/mods/`, code is grouped by runtime responsibility: host and protocol
integration, route navigation, room behavior, timeline interactions, and
modeled traits or keepsakes.

## Checks

Run the Lua test suite from the repository root:

```sh
lua tests/all.lua
```

Check the module with Luacheck:

```sh
luacheck src/
```

For local deployment and modpack-level checks, see the
[Run Planner modpack repository](https://github.com/h2pack-runplanner/run-planner-modpack).

## Documentation

`README.md` is the user-facing introduction for both GitHub and Thunderstore.
The package's `thunderstore.toml` points to that same file. Keep implementation
and development details here rather than maintaining a second user guide.
