# STL/OBJ QuickLook Registration Fix

## Symptom

STL and OBJ files rendered in the host app, but Finder/QuickLook discovery did not route those files to QuickLookStep. macOS fell back to the system/Xcode model viewer.

## Diagnosis

`mdls` reports these system UTTypes:

- STL: `public.standard-tesselated-geometry-format`
- OBJ: `public.geometry-definition-format`

The extension plists did not advertise those exact identifiers. The installed `/Applications/QuickLookStep.app` was also stale and only advertised STEP support.

## Fix

- Added the real STL/OBJ UTTypes to preview and thumbnail `QLSupportedContentTypes`.
- Added app document claims for those UTTypes.
- Changed app handler rank from `Alternate` to `Owner`.
- Added an Editor-role document claim for OBJ/STL so Finder double-click/default-open no longer prefers Xcode's editor role.
- Added `testing/scripts/register-file-types.sh` to re-register the installed app and force sticky user-level LaunchServices defaults to QuickLookStep.
- Installed the rebuilt app to `/Applications/QuickLookStep.app`.
- Refreshed LaunchServices and QuickLook caches.

## Verification

Installed app now declares:

- `public.geometry-definition-format`
- `public.standard-tesselated-geometry-format`
- `org.khronos.gltf`
- `org.khronos.glb`

`mdls` confirms the Thor STL/OBJ files use the matching STL/OBJ UTTypes.

LaunchServices default handler check now reports:

- OBJ `public.geometry-definition-format`: viewer/editor/all = `com.johnboiles.QuickLookStep`
- STL `public.standard-tesselated-geometry-format`: viewer/all = `com.johnboiles.QuickLookStep`

`open` on the Thor OBJ launches `/Applications/QuickLookStep.app/Contents/MacOS/QuickLookStep` instead of Xcode.

## Caveat

`qlmanage -t` hung during command-line thumbnail verification after cache reset. Finder AppleScript `open` also behaved as a no-op in this shell session, but LaunchServices default-open through `open` launches QuickLookStep.
