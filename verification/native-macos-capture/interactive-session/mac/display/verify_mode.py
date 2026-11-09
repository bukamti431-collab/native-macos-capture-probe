"""Validate an independent native probe; never resize or create image pixels."""
import json
import math
import sys


def verify_mode(probe, display_id):
    if type(display_id) is not int or not 0 < display_id <= 0xFFFFFFFF:
        raise ValueError("invalid_display_id")
    if not isinstance(probe, dict) or probe.get("schema_version") != 1:
        raise ValueError("invalid_probe")
    displays = probe.get("displays")
    if not isinstance(displays, list):
        raise ValueError("missing_displays")
    matches = [item for item in displays if isinstance(item, dict) and item.get("display_id") == display_id]
    if len(matches) != 1:
        raise ValueError("display_not_unique")
    display = matches[0]
    if any(display.get(key) is not expected for key, expected in [("online", True), ("active", True), ("mirrored", False)]):
        raise ValueError("display_not_active_independent")
    for key, expected in [("mode_pixels", [3840, 2160]), ("mode_points", [1920, 1080])]:
        actual = display.get(key)
        if not isinstance(actual, list) or len(actual) != 2 or any(type(n) not in (int, float) or not math.isfinite(n) for n in actual) or actual != expected:
            raise ValueError("unexpected_" + key)
    for key in ["bounds_points", "screen_frame_points"]:
        actual = display.get(key)
        if not isinstance(actual, list) or len(actual) != 4 or any(type(n) not in (int, float) or not math.isfinite(n) for n in actual) or actual[2:] != [1920, 1080]:
            raise ValueError("unexpected_" + key)
    if type(display.get("backing_scale_factor")) not in (int, float) or display["backing_scale_factor"] != 2:
        raise ValueError("unexpected_backing_scale")
    return display


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ValueError("usage_verify_mode_probe_json_display_id")
        with open(sys.argv[1], "r", encoding="utf-8") as source:
            probe = json.load(source)
        actual = verify_mode(probe, int(sys.argv[2]))
        print(json.dumps({"verified": True, "actual": actual}, sort_keys=True))
    except (ValueError, OSError) as error:
        # Never print input paths or input data in failure logs.
        print(json.dumps({"verified": False, "error": "actual_hidpi_not_verified"}))
        sys.exit(2)
