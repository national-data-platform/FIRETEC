#!/usr/bin/env python3
"""Build firetec_1.5.0_parameters.json from the FIRETEC 1.5.0 source code.

The catalog lists every gridlist key FIRETEC 1.5.0 reads (its QueryGridlist_*
calls) with the key's type, the default declared for the Fortran variable it
fills, and the description from that declaration's comment.
firetec_to_zarr.py uses it to fill in the defaults a gridlist leaves out and to
describe every parameter of a run in the Zarr metadata.

Usage:
    python3 build_parameter_catalog.py [CODE_DIR]

CODE_DIR defaults to the repository's CODE-1.5.0 directory.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

FIRETEC_VERSION = "1.5.0"
SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_CODE_DIR = SCRIPT_DIR.parent.parent / f"CODE-{FIRETEC_VERSION}"
CATALOG_PATH = SCRIPT_DIR / f"firetec_{FIRETEC_VERSION}_parameters.json"

# call QueryGridlist_real('dx',dx,48)  ->  kind=real, key=dx, variable=dx
QUERY_CALL = re.compile(
    r"QueryGridlist_(?P<kind>\w+?)\s*\(\s*'(?P<key>[^']+)'\s*,\s*(?P<variable>\w+)",
    re.IGNORECASE)
# real(prec) :: dx = 2. ! Size of cell in x dimension
DECLARATION = re.compile(
    r"^\s*(?:integer|real\s*(?:\(\s*\w+\s*\))?|character\s*\(\s*len\s*=\s*\d+\s*\)"
    r"|logical)[^:]*::(?P<entities>.*)$",
    re.IGNORECASE)
FORTRAN_KIND_SUFFIX = re.compile(r"_\w+$")


@dataclass(frozen=True)
class SourceLine:
    path: str
    number: int
    code: str
    comment: str

    @property
    def location(self) -> str:
        return f"{self.path}:{self.number}"


def split_comment(line: str) -> tuple[str, str]:
    """Split a Fortran line into code and the text after a '!' outside quotes."""
    quote = None
    for index, char in enumerate(line):
        if quote:
            if char == quote:
                quote = None
        elif char in "'\"":
            quote = char
        elif char == "!":
            return line[:index], line[index + 1:].strip()
    return line, ""


def split_top_level(text: str, separator: str = ",") -> list[str]:
    """Split on separators that are outside parentheses and quotes."""
    parts, depth, quote, start = [], 0, None, 0
    for index, char in enumerate(text):
        if quote:
            quote = None if char == quote else quote
        elif char in "'\"":
            quote = char
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        elif char == separator and depth == 0:
            parts.append(text[start:index])
            start = index + 1
    parts.append(text[start:])
    return parts


def parse_fortran_literal(text: str):
    """Convert a Fortran literal (2., 1.e-3, 'name', .true.) to a Python value.

    Anything else (an expression) is returned as its source text.
    """
    text = text.strip()
    if len(text) >= 2 and text[0] in "'\"" and text[-1] == text[0]:
        return text[1:-1].rstrip()
    if text.lower() in (".true.", ".false."):
        return text.lower() == ".true."
    number = FORTRAN_KIND_SUFFIX.sub("", text).replace("d", "e").replace("D", "E")
    try:
        return int(number)
    except ValueError:
        pass
    try:
        return float(number)
    except ValueError:
        return text


def read_source_lines(code_dir: Path) -> list[SourceLine]:
    lines = []
    for path in sorted(code_dir.rglob("*.F90")):
        if "build" in path.relative_to(code_dir).parts:
            continue
        relative = str(path.relative_to(code_dir))
        for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            code, comment = split_comment(line)
            lines.append(SourceLine(relative, number, code, comment))
    return lines


def find_declared_defaults(lines: list[SourceLine]) -> dict[str, tuple]:
    """Map lower-case variable name -> (default, comment, location) of its first
    declaration with an initial value."""
    defaults: dict[str, tuple] = {}
    for line in lines:
        match = DECLARATION.match(line.code)
        if not match:
            continue
        for entity in split_top_level(match["entities"]):
            name, equals, value = entity.partition("=")
            name = name.strip().lower()
            if equals and re.fullmatch(r"\w+", name):
                default = parse_fortran_literal(value)
                defaults.setdefault(name, (default, line.comment, line.location))
    return defaults


def build_catalog(code_dir: Path) -> dict:
    lines = read_source_lines(code_dir)
    defaults = find_declared_defaults(lines)
    parameters: dict[str, dict] = {}
    for line in lines:
        for match in QUERY_CALL.finditer(line.code):
            key = match["key"]
            if key in parameters:
                continue
            declaration = defaults.get(match["variable"].lower(), (None, "", None))
            default, comment, declared_in = declaration
            parameters[key] = {
                "type": match["kind"].lower().replace("_", " "),
                "default": default,
                "description": comment or line.comment,
                "variable": match["variable"],
                "read_in": line.location,
                "declared_in": declared_in,
            }
    return {
        "firetec_version": FIRETEC_VERSION,
        "generated_by": Path(__file__).name,
        "source": f"{code_dir.name} (QueryGridlist_* calls and their variable declarations)",
        "source_git_commit": git_commit(code_dir),
        "note": "default is null where FIRETEC sets the value in code or has none",
        "parameters": parameters,
    }


def git_commit(directory: Path) -> str | None:
    result = subprocess.run(["git", "-C", str(directory), "rev-parse", "HEAD"],
                            capture_output=True, text=True, check=False)
    return result.stdout.strip() or None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("code_dir", nargs="?", type=Path, default=DEFAULT_CODE_DIR,
                        help=f"FIRETEC {FIRETEC_VERSION} source directory (default: %(default)s)")
    args = parser.parse_args()
    catalog = build_catalog(args.code_dir)
    CATALOG_PATH.write_text(json.dumps(catalog, indent=2) + "\n")
    print(f"wrote {len(catalog['parameters'])} parameters to {CATALOG_PATH}")


if __name__ == "__main__":
    main()
