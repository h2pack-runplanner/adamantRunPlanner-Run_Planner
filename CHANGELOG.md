# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.7.11] - 2026-09-20

### Fixed

- conformance: track fig leaf last charge. (8688299)

## [0.7.10] - 2026-09-20

### Fixed

- executor: fields encounter shape mismatch (bc93e4d)

## [0.7.9] - 2026-09-20

### Fixed

- executor: resolve identity clash between artificer and original reward at thessaly wheels (8e48aef)

## [0.7.8] - 2026-09-20

### Fixed

- executor: safely fall back from rejected inventories (3352c27)

## [0.7.6] - 2026-09-20

### Fixed

- executor: settle directly granted well traits (ae7c8e8)

## [0.7.5] - 2026-09-20

### Fixed

- shops: resolve hammer options to native loot identity (d5ff594)

## [0.7.4] - 2026-09-20

### Fixed

- protocol: verify canonical execution fingerprints (2671d04)

## [0.7.3] - 2026-09-20

### Fixed

- host: attach standalone inspector UI (4510e39)

## [0.7.2] - 2026-09-20

### Fixed

- protocol: declare supported execution compatibility (eb515d6)

## [0.7.1] - 2026-09-19

### Documentation

- introduce Run Planner for new players (f215793)

## [0.7.0] - 2026-09-19

### Documentation

- explain how to find the game log (1f61053)

## [0.6.0] - 2026-09-19

### Documentation

- add illustrated planner and game walkthrough (4e90a8b)

## [0.5.0] - 2026-09-19

### Added

- branding: replace companion package icon (
8375db)
- navigation: steer published Dream routes through native transitions (
37acc9)
- protocol: align route foundation execution plans (
26c2fe)
- npc: steer ordered Latest Model upgrades (
1631e1)
- npc: steer plural Circe outcomes (
f169a5)
- encounters: steer Chronos summons and Typhon eggs (
95c479)
- encounters: steer optional generated composition (
a37e38)
- protocol: admit generated encounter customization (
6f9a29)
- encounters: realize Eris summon prefixes (
91a1c6)
- encounters: realize Cerberus howl and burrow choices (
130acc)
- encounters: realize Hecate and Scylla choices (
86319c)
- protocol: decode encounter customization (
9f0851)
- inspector: show plan loadout and live execution status (
f2353e)

### Fixed

- navigation: protect the authored exit from native blocking (
c3e241)
- conformance: ignore disposable NPC armor traits (
d1f3bd)
- commerce: scope refill checks and generation (
88e387)
- timeline: pass through unowned native contacts (
3b3045)
- fields: preserve door rewards without unpicked room layouts (
1ae8c4)
- artificer: preserve native unplanned conversions (
61b775)

## [0.4.0] - 2026-09-16

### Added

- shop: bind exact timeline transactions (
9a3b90)
- executor: settle store outcomes by result (
cffa2f)
- executor: resynchronize at postboss entry (
010e50)
- executor: verify postboss admission state (
a165d7)
- protocol: decode postboss recovery boundaries (
aa0526)
- executor: select active plan slot (
5cf1cb)
- execution: complete surface route (
27a228)
- execution: realize thessaly ship combat (
628c11)
- execution: realize ephyra hub navigation (
fc0cc3)
- execution: complete underworld route (
98350f)
- execution: realize mourning fields navigation (
1ef527)

### Fixed

- commerce: preserve shop slots and shrine generation delays (3a144e4)
- conformance: traverse sparse native Hex talent positions (
65a76d)
- commerce: bind spell setup and resolve Travel Deal drops (
dd8d84)
- navigation: resolve rewards on fixed return doors (
9742b3)
- tolerate numeric roundoff in conformance checks (
fd133c)
- keep delivered acquisitions available after encounter callbacks (
b693f9)
- log complete mismatch inventory diagnostics (
567076)
- accept Timepieced wheel rewards without acquisitions (
51b0f6)
- release completed ship wheel bindings before reuse (
39b84f)
- timeline: resolve shared acquisition sources by material identity (
1d2ed1)
- navigation: apply contract presence before door previews (
d442ba)
- nemesis: bind event completion to native owners (
0d2ac6)
- inventory: scope refills to native construction (
d5fdcf)
- wheels: publish selection before native encounter resume (
a8d9eb)
- hex: bind tree construction to its selected spell (
2f981b)
- mystery: retire unwrap context after provider construction (
9355a8)
- echo: bind deferred boon rows to the native replay menu (
ee1b31)
- room: check exit obligations at room closure (
ab7fcb)
- executor: gate outcome scopes and restore shrine context (
cd46cf)
- nemesis: steer native trait trade selection (
46e7a7)
- keepsakes: isolate the native Fig Leaf skip roll (
dc08c5)
- levels: route Pom Slice through direct acquisition (
543324)
- fields: restore steering and report placement diagnostics (
789c42)
- executor: log successful postboss resynchronization (
325222)
- runtime: keep execution session process-local (
20f6fa)
- executor: settle shrine outcomes at native contacts (
a2afe8)
- executor: bind acquisition outcomes by published roles (
0f0599)
- timeline: steer encounter trait offers (
fc433e)
- navigation: preserve Ephyra revisit bindings (
abb367)
- executor: stabilize room feature realization (
bec16d)
- executor: align room feature conformance (
86d1ed)
- executor: stabilize Ephyra room lifecycle (
911844)

### Changed

- rename game companion to Run Planner (
a51369)
- hex: leave God Sent construction native (
7a6a7e)
- sea-star: insert planned chance at native trait read (
bffd8a)
- acquisitions: remove dead markers and NPC preflight (
e6e166)
- executor: defer actuator result checks (
05c7c8)
- acquisitions: defer result checks to conformance (
3a0a41)
- runtime: separate mismatches from executor faults (
18925b)
- acquisitions: settle steering at native intervention (
097017)
- execution: separate acquisition steering from obligations (
3617e9)

### Documentation

- execution: close fixed-route expansion (
7d4a2b)

## [0.3.0] - 2026-09-07

### Added

- executor: realize Hermes Shrine commerce (
da4a6f)
- executor: realize Stygian Well commerce (
7f8e73)
- executor: realize Purging Pool menus (
938cfe)
- executor: realize World Shop commerce (
b84161)
- executor: realize volatile keepsake replays (
607e53)
- executor: close keepsake effect conformance (
2acc9e)
- executor: realize Echo volatile outcomes (
ae74f0)
- executor: realize Icarus latest model (
110381)
- executor: realize Circe stateful outcomes (
54a7c6)
- executor: steer Sea Star duplication (
cf7344)
- executor: observe Path acquisition (
ea60ed)
- executor: steer Spell Hex acquisition (
5bfb91)
- executor: steer Concave Stone residuals (
b53eb1)
- executor: steer Natural Selection distribution (
fbb696)
- executor: steer All Together grants (
93e724)
- executor: realize F/G encounter keepsakes (
b2aaab)
- executor: realize Artificer transformations (
0ae5fa)
- executor: realize npc acquisitions (
de5f75)
- executor: settle direct pickup acquisitions (
7936a0)
- executor: realize level acquisitions (
18037e)
- executor: realize ordinary trait offers (
9550cc)
- executor: verify starting loadout contract (
668a36)
- executor: replace trace runtime with room sessions (
b78d3f)
- executor: close live F and G realization (
3fe7aa)
- executor: consume protocol v7 state frames (
e86776)
- executor: realize G special encounters (
a9033e)
- executor: realize Chaos and additional exits (
3891f8)
- executor: realize F and G room interactions (
67a173)
- executor: execute room trace programs (
69148a)
- executor: realize F and G topology (
684e53)
- executor: execute F opening plan (
bb292a)
- executor: checkpoint room reward prototype (
b7c3b7)
- executor: route compiled room batches (
a5149c)
- executor: freeze and observe run sessions (
9fa578)
- executor: decode published plan slot (
6f525f)

### Fixed

- ci: extending luacheck line limit (54003a6)
- traits: realize carried acquisition outcomes (
78bbc3)
- executor: validate declared encounter carriers (
d3e001)
- decouple room exit from transition state (
dbb5b0)
- executor: check elements at room exit (
91de49)
- executor: realize protected resource outcomes (
61fb14)
- executor: defer shop purchases until interaction (
bc26cf)
- executor: read live conformance state (
718b37)
- executor: harden live execution contacts (
1b433d)
- executor: stabilize room session ownership (
ba9e68)
- executor: preserve anomaly entry presentation (
2ac13f)
- executor: unify random Arcana steering (
69aa0e)
- executor: realize exact embryo outcomes (
4a5d12)
- executor: cover consequential native acquisition contacts (
b7ebef)
- executor: preserve native required boss rewards (
cfb52f)
- executor: stabilize live F route realization (
0ef03e)
- executor: accept published protocol values (
863500)
- executor: close F and G execution boundary (
558b8a)

### Changed

- executor: move anvil steering into commerce (
d17a6e)
- executor: split room feature interactions (
fb81bb)
- executor: finish repository housekeeping (
8662e0)
- executor: organize host and runtime modules (
3b6aea)
- executor: rehome shared spell and trait adapters (
094ea7)
- executor: unify native bindings (
4f145f)
- executor: consolidate protocol decoding (
33c37e)
- executor: consolidate keepsake adapters (
00c84a)
- executor: unify NPC trait menus (
90c0d6)
- executor: retire broad trait fallback (
c2d094)
- executor: enforce exact authored outcomes (
160fd2)
- executor: isolate Chaos acquisitions (
e90d5a)
- executor: stabilize hook identities (
383786)
- executor: consolidate encounter timeline (
e502a9)
- executor: establish room timeline skeleton (
4a30cb)
- executor: close declaration-driven room structure (
d6edaf)
- executor: align startup with native run lifecycle (
2c1c15)

### Changed

- Ported the template to the current ModpackLib module host, draw, state, action, and fallback UI APIs.
- Removed module-local Chalk/config scaffolding and legacy Setup deployment scripts.
