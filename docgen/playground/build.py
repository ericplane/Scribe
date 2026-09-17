"""Build the docs playground from Scribe's actual runtime sources.

No package installation or network access is needed during documentation builds.
Only the generated bundle changes when the corresponding Scribe source changes.
"""
from pathlib import Path
import hashlib
import json
import re


MODULES = (
    "Datatypes", "Util", "Marker", "Big", "Derived", "Clock", "Metrics", "Template", "Node"
)
# Lifted verbatim from src/init.luau. A body that reaches past Marker, BigMath and
# Luau globals fails generation so the adapter gets reviewed.
DECLARATORS = (
    "ServerOnly", "Shared", "Session",
    "Int", "Number", "Big", "String", "Enum", "Flags", "Dynamic", "Derived",
    "Optional", "ArrayOf", "SetOf", "MapOf", "DictOf",
    "Short", "SetShortSuffixes",
)
# Timers need the server scheduler.
UNAVAILABLE = {
    "Timed": "Scribe.Timed is unavailable in this playground: timed fields need the server scheduler",
}
FOREIGN = re.compile(r"\b(require|game|script|Types|Log|Util|Template|Health|Addons|Config|Budget|Exchange|Node|task|Players|RunService)\b[.:(]")
HERE = Path(__file__).resolve().parent


def extract_declarator(public: str, name: str) -> str:
    match = re.search(rf"^function Scribe\.{name}\b.*?^end$", public, re.M | re.S)
    if match is None:
        raise ValueError(f"Scribe.{name} not found; review the playground's source extraction")
    body = match.group(0)
    foreign = FOREIGN.search(body)
    if foreign:
        raise ValueError(f"Scribe.{name} uses {foreign.group(1)}; review the playground adapter before including it")
    return body


def make_runtime(root: Path) -> str:
    """Return a Luau chunk whose results run and describe an isolated in-memory data example."""
    chunks = [
        "-- Generated from Scribe source; do not edit this output.\n"
        "local modules = {}\n"
        "local task = {\n"
        "  wait = function() error('Scheduled work is unavailable in this playground') end,\n"
        "  delay = function() error('Scheduled work is unavailable in this playground') end,\n"
        "}\n"
        "local game = { GetService = function(_, name)\n"
        "  assert(name == 'HttpService', 'Roblox services are unavailable in this playground')\n"
        "  return { GenerateGUID = function() error('GUID generation is unavailable in this playground') end }\n"
        "end }\n"
    ]
    loaded = set()
    for name in MODULES:
        source = (root / "src" / "Internal" / f"{name}.luau").read_text(encoding="utf-8")
        dependencies = re.findall(r"require\(script\.Parent\.(\w+)\)", source)
        missing = set(dependencies) - loaded
        if missing:
            raise ValueError(f"Playground module order is stale: {name} needs {sorted(missing)}")
        source = re.sub(r"require\(script\.Parent\.(\w+)\)", r"modules.\1", source)
        if re.search(r"\brequire\s*\(", source):
            raise ValueError(f"Unexpected dependency in playground module {name}; review the adapter")
        chunks.append(f"modules.{name} = (function()\n{source}\nend)()\n")
        loaded.add(name)

    public = (root / "src" / "init.luau").read_text(encoding="utf-8")
    declarators = "\n".join(extract_declarator(public, name) for name in DECLARATORS)
    stubs = "\n".join(f"function Scribe.{name}() error({json.dumps(message)}, 2) end"
                      for name, message in UNAVAILABLE.items())
    chunks.append("local Marker = modules.Marker\nlocal BigMath = modules.Big\nlocal Scribe = {}\n"
                  + declarators + "\n" + stubs + "\ntable.freeze(Scribe)\n")
    chunks.append((HERE / "bootstrap.luau").read_text(encoding="utf-8"))
    return "\n".join(chunks)


def verify_vendor(root: Path) -> None:
    vendor = root / "docgen" / "theme" / "assets" / "playground" / "runtime"
    provenance = json.loads((vendor / "PROVENANCE.json").read_text(encoding="utf-8"))
    for entry in provenance["files"]:
        actual = hashlib.sha256((vendor / entry["file"]).read_bytes()).hexdigest()
        if actual != entry["local_sha256"]:
            raise ValueError(f"Playground dependency checksum mismatch: {entry['file']}")


def build_playground(root: Path, destination: Path, version: str, api=None) -> None:
    """Write generated assets after docgen has copied theme/assets/."""
    verify_vendor(root)
    source = make_runtime(root)
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "runtime.luau").write_text(source, encoding="utf-8", newline="\n")
    metadata = {
        "scribeVersion": version,
        "runtime": "luau-web 1.4.0 / Luau 0.711 (Asyncify)",
        "sourceSha256": hashlib.sha256(source.encode("utf-8")).hexdigest(),
        "modules": list(MODULES),
        "declarators": list(DECLARATORS),
        "unavailable": sorted(UNAVAILABLE),
        "typeChecking": False,
    }
    (destination / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    (destination / "api.json").write_text(json.dumps(api or [], ensure_ascii=False, separators=(",", ":")) + "\n",
                                          encoding="utf-8")
