#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def load_event(path: Path, event_id: str | None) -> dict:
    payload = json.loads(path.read_text())
    if "events" not in payload:
        return payload

    events = payload.get("events", [])
    if not events:
        raise SystemExit(f"No events in session: {path}")
    if event_id:
        for event in events:
            if event.get("eventID") == event_id:
                return event
        raise SystemExit(f"Event not found: {event_id}")
    return events[-1]


def expectation_from_args(event: dict, args: argparse.Namespace) -> dict:
    resolver = event.get("resolver", {})
    expectation = dict(event.get("expectation") or {})
    if args.kind:
        expectation["kind"] = args.kind
    elif "kind" not in expectation:
        expectation["kind"] = resolver.get("finalKind")

    if args.surface_triangle_count is not None:
        expectation["surfaceTriangleCount"] = args.surface_triangle_count
    elif (
        "surfaceTriangleCount" not in expectation
        and expectation.get("kind") == "surface"
        and resolver.get("selectedSurfaceTriangleCount") is not None
    ):
        expectation["surfaceTriangleCount"] = resolver.get("selectedSurfaceTriangleCount")

    if args.min_surface_triangle_count is not None:
        expectation["minSurfaceTriangleCount"] = args.min_surface_triangle_count
    if args.max_surface_triangle_count is not None:
        expectation["maxSurfaceTriangleCount"] = args.max_surface_triangle_count
    if args.must_have_rejected_alternative:
        expectation["mustHaveRejectedAlternative"] = True
    if args.forbidden_label:
        expectation["forbiddenLabels"] = args.forbidden_label

    return {key: value for key, value in expectation.items() if value is not None}


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Promote one selection debug event into a replayable golden plan."
    )
    parser.add_argument("input_json", help="selection-debug-session.json or a single event JSON")
    parser.add_argument("output_plan", help="plan JSON to write")
    parser.add_argument("--event-id", help="eventID to promote; defaults to latest session event")
    parser.add_argument("--name", default="promoted-selection-debug-event")
    parser.add_argument("--kind", choices=["surface", "edge", "none"])
    parser.add_argument("--surface-triangle-count", type=int)
    parser.add_argument("--min-surface-triangle-count", type=int)
    parser.add_argument("--max-surface-triangle-count", type=int)
    parser.add_argument("--must-have-rejected-alternative", action="store_true")
    parser.add_argument("--forbidden-label", action="append")
    parser.add_argument("--note")
    args = parser.parse_args()

    event = load_event(Path(args.input_json), args.event_id)
    normalized = event.get("input", {}).get("normalizedViewportPoint") or []
    if len(normalized) < 2:
        raise SystemExit("Event is missing input.normalizedViewportPoint")

    camera = event.get("camera", {})
    expectation = expectation_from_args(event, args)
    scenario = {
        "name": args.name,
        "file": event.get("modelHint", ""),
        "actions": [
            {
                "kind": "setCamera",
                "orientationDegrees": camera.get("orientationDegrees", [0, 0, 0]),
                "cameraPosition": camera.get("position", [0, 0, 0]),
                "fieldOfView": camera.get("fieldOfView", 0),
                "durationMs": 40,
            },
            {
                "kind": "selectAt",
                "x": normalized[0],
                "y": normalized[1],
                "coordinateSpace": "normalizedViewport",
                "expect": expectation,
                "durationMs": 80,
            },
        ],
    }
    if args.note:
        scenario["note"] = args.note

    output = {"scenarios": [scenario]}
    output_path = Path(args.output_plan)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(output, indent=2, sort_keys=True) + "\n")
    print(f"Wrote promoted plan: {output_path}")


if __name__ == "__main__":
    main()
