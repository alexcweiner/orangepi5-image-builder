#!/usr/bin/env python3
"""Validate and install machine cloud credentials without printing their values."""
import json
import os
from pathlib import Path
import sys
import tempfile


def validate(path):
    try:
        data = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        raise ValueError("credentials must be a readable JSON document") from None
    if not isinstance(data, dict) or not isinstance(data.get("cloud"), dict):
        raise ValueError("credentials must contain a cloud object")
    cloud = data["cloud"]

    def field(value, name):
        if not isinstance(value, str) or not value.strip():
            raise ValueError(f"{name} must be a nonempty string")
        if "REPLACE_WITH_" in value.upper():
            raise ValueError(f"replace the placeholder in {name}")

    field(cloud.get("id"), "cloud.id")
    field(cloud.get("app_address"), "cloud.app_address")
    if "secret" not in cloud and "api_key" not in cloud:
        raise ValueError("cloud.secret or cloud.api_key is required")
    if "secret" in cloud:
        field(cloud["secret"], "cloud.secret")
    if "api_key" in cloud:
        if not isinstance(cloud["api_key"], dict):
            raise ValueError("cloud.api_key must be an object")
        field(cloud["api_key"].get("id"), "cloud.api_key.id")
        field(cloud["api_key"].get("key"), "cloud.api_key.key")
    return data


def install(source, destination):
    data = validate(source)
    destination = Path(destination)
    fd, temp = tempfile.mkstemp(prefix=".viam-", dir=destination.parent)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(data, output, indent=2)
            output.write("\n")
        # mkstemp creates a private file; the builder runs as root, so it is root-owned.
        os.replace(temp, destination)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def main():
    args = sys.argv[1:]
    try:
        if len(args) == 2 and args[0] == "validate":
            validate(args[1])
        elif len(args) == 3 and args[0] == "install":
            install(args[1], args[2])
        else:
            raise ValueError("usage: viam-config.py validate SOURCE | install SOURCE DESTINATION")
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
