"""Shared transport table; preserve input spelling except explicit aliases."""

import json
from pathlib import Path

_TABLE = json.loads((Path(__file__).resolve().parents[1] /
                     "schemas/transport-codes.json").read_text(encoding="utf-8"))
CANONICAL = tuple(_TABLE["canonical"])
ALIASES = _TABLE["aliases"]


def normalize_transport(value: str) -> str:
    return ALIASES.get(value, value) if isinstance(value, str) else value


def normalize_transports(values: list[str]) -> list[str]:
    return list(dict.fromkeys(normalize_transport(value) for value in values))
