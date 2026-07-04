#!/usr/bin/env bash
set -euo pipefail

APP="${1:-/Applications/QuickLookStep.app}"

if [[ ! -d "$APP" ]]; then
  echo "QuickLookStep app not found: $APP"
  exit 1
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f -R -trusted "$APP"

swift - "$APP" <<'SWIFT'
import Foundation
import CoreServices

let bundleIdentifier = "com.johnboiles.QuickLookStep" as NSString
let types: [String] = [
    "public.step",
    "com.shapr3d.step",
    "com.shapr3d.stp",
    "a360.step",
    "com.johnboiles.step",
    "public.geometry-definition-format",
    "public.standard-tesselated-geometry-format",
    "org.khronos.gltf",
    "org.khronos.glb",
    "com.johnboiles.model3d",
]

for type in types {
    let cfType = type as NSString
    let viewerStatus = LSSetDefaultRoleHandlerForContentType(cfType, LSRolesMask.viewer, bundleIdentifier)
    let editorStatus = LSSetDefaultRoleHandlerForContentType(cfType, LSRolesMask.editor, bundleIdentifier)
    let allStatus = LSSetDefaultRoleHandlerForContentType(cfType, LSRolesMask.all, bundleIdentifier)
    print("\(type): viewer=\(viewerStatus) editor=\(editorStatus) all=\(allStatus)")
}
SWIFT

qlmanage -r
qlmanage -r cache

echo "Registered QuickLookStep file handlers for OBJ/STL/glTF/3MF."
