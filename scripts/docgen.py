#!/usr/bin/env python3
"""
the header is auto generated as `### name(args) -> ret`
subsequent lines are the description

- if the first line starts with `>`, it replaces the autogened header
   /// > whatever(a: b) -> type
   /// desc here

- lines indented with 4 spaces or a tab are automatically wrapped in ``` blocks
   /// example:
   ///     local x = func(1)
   ///     print(x)
"""

import re
from pathlib import Path

ROOT_ZIG = Path("src/std/root.zig")
NATIVES_DIR = Path("src/std")
MOD_ORDER = ["math", "string", "table", "meta", "fs", "net", "stupid", "iter"]

docs = {}
hl_lang = "ruby"

# build output start
output: list[str] = []
with (Path(__file__).parent / "doc-prefix.txt").open() as file:
    output = file.read().strip().splitlines()


# extract fns from zig source
def extract_functions(text):
    pattern = re.compile(
        r"((?:[ \t]*///[^\n]*\n)+)(?:[ \t]*\n)*"
        r"[ \t]*(?:pub\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)"
        r"(\([^{]*?\))([^{;]*)",
        re.DOTALL,
    )

    for m in pattern.finditer(text):
        raw_lines = [line for line in m.group(1).strip().split("\n")]
        cleaned_lines = []
        for line in raw_lines:
            stripped = line.strip()
            if stripped.startswith("///"):
                content = stripped[3:]
                if content.startswith(" "):
                    content = content[1:]
                cleaned_lines.append(content)
            else:
                cleaned_lines.append(stripped)

        doc_text = "\n".join(cleaned_lines)
        ret_raw = re.sub(r"\s+", " ", m.group(4)).strip()
        ret_raw = re.sub(r"^[!]", "", ret_raw)

        docs[m.group(2)] = {
            "doc": doc_text,
            "params": re.sub(r"\s+", " ", m.group(3)).strip(),
            "ret": ret_raw,
        }


# format docstring according to rules
def format_docstring(doc):
    if not doc:
        return None, ""

    lines = doc.split("\n")
    processed = []
    override = None

    # check for header override - can be on any line
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith(">"):
            override = stripped[1:].strip()
            # remove the override line from processing
            lines.pop(i)
            break

    CDEPTH = " " * 2

    i = 0
    while i < len(lines):
        line = lines[i]
        if not (line.startswith(CDEPTH) or line.startswith("\t")):
            processed.append(line)
            i += 1
            continue

        code_block = []
        while i < len(lines):
            curr = lines[i]
            if not (curr.startswith(CDEPTH) or curr.startswith("\t")):
                break
            # strip indent
            if curr.startswith(CDEPTH):
                code_block.append(curr[4:])
            else:
                code_block.append(curr[1:])
            i += 1

        # add blank line before code block only if previous line not empty
        if processed and processed[-1] != "":
            processed.append("")

        processed.append(f"```{hl_lang}")
        processed.extend(code_block)
        processed.append("```")

    # trailing ws
    while processed and processed[-1] == "":
        processed.pop()

    result = "\n".join(processed).strip()
    return override, result


# render single function entry
def render_function(name, types, doc, ret, variadic=False, type_hint=None):
    # build params string
    if types:
        params = ", ".join(f"arg{i}: {t}" for i, t in enumerate(types))
        if variadic:
            params += ", ..."
        params = f"({params})"
    else:
        params = ""

    ret_str = f" -> {ret}" if ret and ret != "void" else ""
    prefix = f"{type_hint}." if type_hint else ""
    sig = f"\n### - `{prefix}{name}{params}{ret_str}`"

    if not doc:
        return sig

    override, formatted = format_docstring(doc)

    if override:
        # use the override as header, add description after
        output = f"\n### - `{override}`"
        if formatted:
            output += f"\n{formatted}"
        return output

    # No override, use auto-generated sig
    if formatted:
        return f"{sig}\n{formatted}"
    return sig


# main logic start
root_text = ROOT_ZIG.read_text()
extract_functions(root_text)

# parse root reg
root_registry = []
reg_pat = re.compile(
    r'\.name\s*=\s*"([^"]+)".*?'
    r"\.f\s*=\s*(define(?:Variadic)?)\s*\("
    r"\s*&(?:\.|\[_\]TypeSpec)\{([^}]*)\}\s*,\s*"
    r"\s*&(?:\.|\[_\]FuncDef)\{([^}]*)\}\s*,\s*"
    r"((?:@import\([^)]+\)\.)?[A-Za-z_][A-Za-z0-9_.]*)"
    r"\s*\)",
    re.DOTALL,
)

for m in reg_pat.finditer(root_text):
    impl = m.group(4).split(".")[-1]
    types = [
        t.strip().lstrip(".") for t in m.group(3).split(",") if t.strip().lstrip(".")
    ]
    root_registry.append(
        {
            "name": m.group(1),
            "impl": impl,
            "types": types,
            "variadic": "Variadic" in m.group(2),
        }
    )

# native mods
for mod_path in sorted(NATIVES_DIR.glob("*.zig")):
    if mod_path.stem not in ["result", "root"]:
        extract_functions(mod_path.read_text())


# track to avoid duplicates
rendered = set()

output.append("# core")
for entry in root_registry:
    # use impl name to check for duplicates
    impl_key = entry.get("impl", entry["name"])
    if impl_key in rendered:
        continue
    rendered.add(impl_key)

    info = docs.get(entry["name"]) or docs.get(entry["impl"]) or {"doc": "", "ret": ""}
    output.append(
        render_function(
            entry["name"],
            entry["types"],
            info["doc"],
            info["ret"],
            entry.get("variadic", False),
        )
    )

for mod_name in MOD_ORDER:
    mod_path = NATIVES_DIR / f"{mod_name}.zig"
    if not mod_path.exists():
        continue

    mod_text = mod_path.read_text()

    # group by table name from registerTableFunctions
    table_entries = {}  # table_name: [entries]
    
    # extract from registerTableFunctions with tbl names
    reg_table_pat = re.compile(
        r"registerTableFunctions\s*\(vm,\s*\"([^\"]+)\"\s*,\s*&\[_\]root\.FuncDef\{(.+?)\}\s*\)",
        re.DOTALL,
    )
    for match in reg_table_pat.finditer(mod_text):
        table_name = match.group(1)
        if table_name not in table_entries:
            table_entries[table_name] = []
        
        for func_def in re.split(r"(?=\.name\s*=)", match.group(2)):
            if not func_def.strip():
                continue

            name_match = re.search(r'\.name\s*=\s*"([^"]+)"', func_def)
            impl_match = re.search(
                r"(?:std_lib\.)?root\.define(?:Variadic)?\s*\([^)]*,\s*(\w+)\s*\)", func_def
            )
            types_match = re.search(r"&(?:\.|[_\]])\{([^}]+)\}", func_def)

            if name_match and impl_match and types_match:
                types = [
                    t.strip().lstrip(".")
                    for t in types_match.group(1).split(",")
                    if t.strip().lstrip(".")
                ]
                table_entries[table_name].append(
                    {
                        "name": name_match.group(1),
                        "impl": impl_match.group(1),
                        "types": types,
                        "variadic": "Variadic" in func_def,
                    }
                )

    # also extract from registerFunctions (no table name)
    reg_fn_pat = re.compile(
        r"registerFunctions\s*\(vm,\s*&\[_\]root\.FuncDef\{(.+?)\}\s*\)",
        re.DOTALL,
    )
    for match in reg_fn_pat.finditer(mod_text):
        if mod_name not in table_entries:
            table_entries[mod_name] = []
        
        for func_def in re.split(r"(?=\.name\s*=)", match.group(1)):
            if not func_def.strip():
                continue

            name_match = re.search(r'\.name\s*=\s*"([^"]+)"', func_def)
            impl_match = re.search(
                r"(?:std_lib\.)?root\.define(?:Variadic)?\s*\([^)]*,\s*(\w+)\s*\)", func_def
            )
            types_match = re.search(r"&(?:\.|[_\]])\{([^}]+)\}", func_def)

            if name_match and impl_match and types_match:
                types = [
                    t.strip().lstrip(".")
                    for t in types_match.group(1).split(",")
                    if t.strip().lstrip(".")
                ]
                table_entries[mod_name].append(
                    {
                        "name": name_match.group(1),
                        "impl": impl_match.group(1),
                        "types": types,
                        "variadic": "Variadic" in func_def,
                    }
                )

    # extract metamethods
    meta_pat = re.compile(
        r"registerMetatable\s*\(vm,\s*&\[_\]root\.MethodDef\{(.+?)\}\s*,\s*(try\s+vm\.ownDataString|Data\.new\.[a-zA-Z_]+)",
        re.DOTALL,
    )
    type_name_map = {
        "try vm.ownDataString": "string",
        "Data.new.table": "table",
        "Data.new.tuple": "tuple",
    }

    for match in meta_pat.finditer(mod_text):
        type_val = match.group(2).strip()
        type_hint = type_name_map.get(type_val, type_val)

        if type_hint not in table_entries:
            table_entries[type_hint] = []

        for method_str in re.split(r"(?=\.key\s*=)", match.group(1)):
            if not method_str.strip():
                continue

            name_match = re.search(r'\.named\s*=\s*"([^"]+)"', method_str)
            if not name_match:
                core_match = re.search(r"\.core\s*=\s*\.(__[a-z_]+)", method_str)
                if not core_match:
                    continue
                key = core_match.group(1)
            else:
                key = name_match.group(1)

            types_match = re.search(r"&(?:\.|[_\]])\{([^}]+)\}", method_str)
            impl_match = re.search(
                r"(?:std_lib\.)?root\.define(?:Variadic)?\s*\([^)]*,\s*(\w+)\s*\)", method_str
            )

            if types_match and impl_match:
                types = [
                    t.strip().lstrip(".")
                    for t in types_match.group(1).split(",")
                    if t.strip().lstrip(".")
                ]
                table_entries[type_hint].append(
                    {
                        "name": key,
                        "impl": impl_match.group(1),
                        "types": types,
                        "type_hint": type_hint,
                    }
                )

    # output sections for each table in order they were found
    for table_name in sorted(table_entries.keys()):
        entries = table_entries[table_name]
        if not entries:
            continue
        
        # dedup if same name exists as both global and mm keep only global
        seen_names = {}
        deduped = []
        for entry in entries:
            name = entry["name"]
            type_hint = entry.get("type_hint")

            if name not in seen_names:
                seen_names[name] = entry
                deduped.append(entry)
            elif not type_hint and seen_names[name].get("type_hint"):
                # prefer global (no type_hint) over metamethods (with type_hint)
                deduped.remove(seen_names[name])
                seen_names[name] = entry
                deduped.append(entry)

        output.append(f"\n---\n# {table_name}")
        for entry in deduped:
            info = (
                docs.get(entry["name"])
                or docs.get(entry["impl"])
                or {"doc": "", "ret": ""}
            )
            output.append(
                render_function(
                    entry["name"],
                    entry["types"],
                    info["doc"],
                    info["ret"],
                    entry.get("variadic", False),
                    entry.get("type_hint"),
                )
            )

print("\n".join(output))

