"""Compare the maintained Odin layouts with both 64-bit Steam SDK packing modes."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


def declarations(source):
    result = {}
    for match in re.finditer(r"^(\w+) :: struct[^\n{]*\{", source, re.M):
        start = match.end()
        depth = 1
        end = start
        fields = []
        while depth:
            stop = source.find("\n", end)
            if stop < 0:
                raise ValueError(match.group(1))
            line = source[end:stop]
            if depth == 1:
                field = re.match(r"\s*(?:using\s+)?(\w+)\s*:", line)
                if field:
                    fields.append(field.group(1))
            depth += line.count("{") - line.count("}")
            end = stop + 1
        result[match.group(1)] = fields
    return result


def records(root):
    api = json.loads((root / "include/steam_api.json").read_text())
    types = declarations((root / "steamworks.odin").read_text())
    aliases = {"gameserveritem_t": "gameserveritet"}
    found = []
    missing = []
    for item in api["callback_structs"] + api["structs"]:
        native = item["struct"]
        if native in (
            "SteamDatagramHostedAddress",
            "SteamDatagramGameCoordinatorServerLogin",
        ):
            continue
        odin = aliases.get(native, native.removesuffix("_t"))
        if odin not in types and native in types:
            odin = native
        if odin not in types:
            missing.append(native)
            continue
        fields = types[odin]
        if odin == "UserStatsReceived":
            fields = ["nGameID", "eResult", "steamIDUser"]
        native_fields = [field["fieldname"] for field in item["fields"]]
        if not native_fields:
            fields = []
        if len(fields) != len(native_fields):
            raise ValueError(f"{odin}: SDK has {native_fields}, Odin has {fields}")
        if native == "SteamNetworkingConfigValue_t":
            native_fields[-1] = "m_val.m_int64"
        found.append((native, odin, list(zip(native_fields, fields))))
    if missing:
        raise ValueError(f"SDK declarations missing from bindings: {missing}")
    found.append(
        (
            "CallbackMsg_t",
            "CallbackMsg",
            [
                ("m_hSteamUser", "hSteamUser"),
                ("m_iCallback", "iCallback"),
                ("m_pubParam", "pubParam"),
                ("m_cubParam", "cubParam"),
            ],
        )
    )
    for native, odin in (
        ("CGameID", "CGameID"),
        ("FriendsGroupID_t", "FriendsGroupID"),
        ("SteamInventoryResult_t", "SteamInventoryResult"),
        ("SteamItemDef_t", "SteamItemDef"),
    ):
        found.append((native, odin, []))
    return found


def probe(root, entries, directory, pack, odin, cxx):
    cpp = [
        "#include <cstdio>",
        "#include <cstddef>",
        f'#include "{root}/include/steamclientpublic.h"',
        "#undef VALVE_CALLBACK_PACK_SMALL",
        "#undef VALVE_CALLBACK_PACK_LARGE",
        "#define VALVE_CALLBACK_PACK_" + ("SMALL" if pack == "small" else "LARGE"),
    ]
    for header in (
        "steam_api.h",
        "steam_gameserver.h",
        "isteamnetworkingutils.h",
        "steamnetworkingfakeip.h",
    ):
        cpp.append(f'#include "{root}/include/{header}"')
    cpp.append("int main() {")
    lines = [
        "package main",
        'import "core:fmt"',
        'import api "ext:steam"',
        "main :: proc() {",
    ]
    for native, name, fields in entries:
        cpp.append(f'printf("{name} %zu %zu\\n", sizeof({native}), alignof({native}));')
        lines.append(
            f'fmt.printf("{name} %d %d\\n", size_of(api.{name}), align_of(api.{name}))'
        )
        for cfield, field in fields:
            cpp.append(
                f'printf("{name}.{field} %zu\\n", offsetof({native}, {cfield}));'
            )
            lines.append(
                f'fmt.printf("{name}.{field} %d\\n", offset_of(api.{name}, {field}))'
            )
    cpp.append("}")
    lines.append("}")
    (directory / "main.cpp").write_text("\n".join(cpp))
    (directory / "main.odin").write_text("\n".join(lines))
    executable = directory / ("sdk.exe" if os.name == "nt" else "sdk")
    subprocess.run(
        [
            cxx,
            "-std=c++17",
            "-fno-access-control",
            "-Wno-invalid-offsetof",
            str(directory / "main.cpp"),
            "-o",
            str(executable),
        ],
        check=True,
    )
    expected = subprocess.check_output([str(executable)], text=True)
    env = os.environ.copy()
    env["DYLD_LIBRARY_PATH"] = str(root / "redist/osx")
    env["LD_LIBRARY_PATH"] = str(root / "redist/linux64")
    if os.name == "nt":
        env["PATH"] = str(root / "redist/win64") + os.pathsep + env.get("PATH", "")
    actual = subprocess.check_output(
        [
            odin,
            "run",
            str(directory),
            "-collection:ext=" + str(root.parent),
            "-define:STEAMWORKS_CALLBACK_PACK_LARGE="
            + ("false" if pack == "small" else "true"),
            "-out:"
            + str(directory / ("odin-probe.exe" if os.name == "nt" else "odin-probe")),
        ],
        env=env,
        text=True,
    )

    def rows(text):
        return {
            parts[0]: parts[1:] for line in text.splitlines() if (parts := line.split())
        }

    wanted, got = rows(expected), rows(actual)
    failures = [
        f"{name}: SDK {value}, Odin {got.get(name)}"
        for name, value in wanted.items()
        if got.get(name) != value
    ]
    for failure in failures:
        print(f"{pack}: {failure}")
    print(
        f"{pack}: {len(entries)} types, {sum(len(fields) for _, _, fields in entries)} field offsets, {len(failures)} mismatches"
    )
    return not failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-odin", required=True)
    parser.add_argument("-cxx", default="clang++")
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    entries = records(root)
    print(
        "Not checked: two datagram ticket types have no definitions in the public SDK headers"
    )
    passed = True
    for pack in ("small", "large"):
        with tempfile.TemporaryDirectory(prefix="steam-layout-") as temporary:
            passed = (
                probe(
                    root,
                    entries,
                    Path(temporary),
                    pack,
                    str(Path(options.odin).resolve()),
                    options.cxx,
                )
                and passed
            )
    raise SystemExit(0 if passed else 1)


if __name__ == "__main__":
    main()
