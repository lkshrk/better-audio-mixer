# Installed-log triage and app-owned correction

The installed app started its five-tap router successfully. Recent inspected logs contained no router recovery loop or explicit underrun/overrun/overload message. That does not prove audible playback is clean; current distortion feedback was requested separately.

## Corrected in source

The control server reported a normal diagnostic-client disconnect as an error-level warning. It now records the send errno and distinguishes expected `EPIPE`/`ECONNRESET` peer closure from unexpected send failure. Expected closure is informational; unexpected failures remain errors with the descriptor and errno. Interrupted sends retry. Existing failed-send diagnostics and dead-client removal are preserved.

Real socket-pair tests verify expected peer closure; an invalid descriptor verifies genuine errors are not reclassified as normal. All 36 BamControlKit tests passed. This source-only logging correction has not replaced the running app; playback was not restarted for a diagnostic-message change.

## Framework messages: no justified system repair

- CFBundle factory UUID `F8BB1C28-BAE8-11D6-9C31-00039315CD46`: its owner was not identified. The installed BAM driver instead registers `85A6B598-0F08-4F52-9C2D-482E1BA4750D`, its factory references resolve, and `BlackHole_Create` is exported. No BAM registration mismatch was established.
- Siri `os_eligibility` entitlement lookup: no failing BAM-required audio API was correlated with it. Private entitlements were not added.
- Missing `/private/var/db/DetachedSignatures`: Apple's local `codesign(1)` documents detached signatures for unsigned code; the app's embedded Developer ID signature was verified. No system database was created or reset.
- Audio analytics reporter disconnection: no correlated renderer disconnection was established. This is not sufficient evidence to alter the audio path.

Factory checks follow Apple's [registration rules](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html) and [CFPlugInFactories reference](https://developer.apple.com/documentation/bundleresources/information-property-list/cfpluginfactories). These checks do not prove every framework message harmless; they show that the proposed system/driver repairs lack supporting evidence.

No hardware route, volume, system file, driver, entitlement, or installed binary changed in this triage. A current audible failure and its timestamp are needed to identify any remaining sound-quality defect; the startup messages alone do not identify one.
