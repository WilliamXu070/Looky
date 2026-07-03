# Shape detection failure - 20260605-165822

## Symptom

Saved edge polygon did not match its expected shape classification.

## Expected behavior

Long edges should classify as `line`; curved regions should classify as one `semicircle`, not fragmented arc segments.

## Scope Boundary

Do not change click detection, snapping, connected-edge detection, UI behavior, or the edge JSON producer. Diagnose and patch only the shape-detection layer that consumes existing `chainPoints`.

## Evidence

