# 3MF Native Importer Rendering Fix

## Symptom

Thor 3MF files loaded with large diagonal/cross-shaped shading artifacts across flat CAD faces and appeared as a single fallback-style color.

## Expected Behavior

3MF files should load through a 3MF-aware path, preserve material color resources, and render hard CAD faces with flat normals.

## Diagnosis

The prior 3MF path fell through to generic mesh conversion via `trimesh`. That exported averaged vertex normals and generic color visuals, so SceneKit interpolated lighting across shared vertices. The result was smoothed shading on planar CAD faces and lost 3MF color metadata.

## Fix

Added `ThreeMFImporter.swift`, which reads `3D/3dmodel.model` from the 3MF package, parses vertices, triangles, object color references, and `m:colorgroup` resources, then builds SceneKit geometry with expanded per-triangle vertices and one flat normal per face.

`SceneBuilder` now routes `.3mf` files to this native importer before falling back to generic loaders.

## Verification

- Build passed with app, preview, and thumbnail targets:
  `xcodebuild -project QuickLookStep/QuickLookStep.xcodeproj -scheme QuickLookStep -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build`
- Single Thor 3MF run:
  `testing/results/final-thor-3mf-native.json`
  - loader: `three-mf-native`
  - normal mode: `flat-face`
  - vertices: `1026`
  - triangles: `2072`
  - colors: `1`
- Full multi-format Thor run:
  `testing/results/final-thor-multiformat-native-3mf.json`

## Status

Fixed and verified.
