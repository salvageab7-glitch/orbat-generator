# Mode 3 · External Agent Quick Start (English)

> **For**: GPT-4o / GPT-5, Claude (Sonnet/Opus 3.5+), Gemini 1.5+ and other **vision-capable** English-speaking agents.
> **Not for**: text-only models. If you cannot see images, use the fallback in §0.
> **Version**: orbat-cli v0.3.5. Run every command from the folder that contains `orbat-cli.exe`.

---

## 0. Decide in 30 seconds whether you can do this

| Your capability | What to do |
|---|---|
| You can read images (multimodal) | Follow this document; you are the recognition engine |
| Text only | Ask the user to paste the ORBAT as indented text, then do "text → JSON" only (skip §4) |
| You can read images but small labels blur | Tile the image (§4). Do not read a dense chart in one pass |

The whole point of Mode 3: **the app calls no model and needs no API key.** You do the recognition; the app validates and renders.

---

## 1. Where you sit in the pipeline

```
user image ──▶ you (read → orbat.json) ──▶ orbat-cli (validate / audit / render) ──▶ PNG + SVG
                     ▲                                  │
                     └────── blocking issues (exit 3) ───┘
```

Three hard rules:

1. **Do not call `generate`.** That is Mode 1/2 (the app calls a model). Without a key it fails by design.
2. **You write the JSON.** The app will not transcribe for you.
3. **Rendering needs the internet**: it drives the online renderer at spatialillusions.com, and locally needs Node ≥ 24 plus Chrome or Edge.

---

## 2. Minimal loop (four commands)

```bat
:: 1. Fetch the recognition rules once, read them into context
orbat-cli.exe prompts --type tile --out prompt.txt

:: 2. Read the image yourself and write orbat.json (format in §3)

:: 3. Validate: exit code 3 means blocking issues — fix them before rendering
orbat-cli.exe validate orbat.json

:: 4. Render: 15-40 s, returns absolute PNG / SVG paths
orbat-cli.exe render --in orbat.json --out final
```

`render` returns a single JSON object on stdout:

```json
{"ok":true,"command":"render","data":{
  "outputBase":"D:\\out\\final","png":"D:\\out\\final.png","svg":"D:\\out\\final.svg",
  "nodeCount":44,"ok":true,"error":null,"elapsedMs":14842}}
```

Conventions for every command: stdout is exactly one JSON object; stderr carries logs; exit codes are `0` success, `1` execution failure, `2` bad arguments, `3` blocking validation issues.

---

## 3. JSON contract (only three fields matter)

This is the minimum viable structure. **Unknown keys are ignored**, so do not worry about renderer options:

```json
{
  "options": {
    "sidc": "130310002111000000000000000000",
    "uniqueDesignation": "2nd Division",
    "additionalInformation": ""
  },
  "subOrganizations": [
    {
      "options": {
        "sidc": "130310001612110200000000000000",
        "uniqueDesignation": "1st Mechanised Infantry Battalion",
        "additionalInformation": "Holsworthy"
      },
      "subOrganizations": []
    }
  ],
  "commandLevels": "1"
}
```

| Field | Rule |
|---|---|
| `options.sidc` | **Exactly 30 digits** (§5). If unsure, use the closest match — `validate` will tell you what is wrong |
| `options.uniqueDesignation` | Designation copied **verbatim** from the chart, including model designations; never summarise |
| `options.additionalInformation` | Location or short role; ≤20 letters in English, ≤12 CJK characters; may be empty |
| `subOrganizations` | Child units, nested exactly as the chart's connectors show |
| `commandLevels` | Root node only; usually `"1"` (compact) or `"3"`; omit on children |

Notes:

- Hierarchy is expressed **only** by nesting. Do not add parent/child fields.
- `parse` only reports node count and depth (it does not convert). Use `normalize orbat.json --out render.json` if you need the renderer's 7-key form.
- Keep original designations in the JSON you hand over; length adaptation happens only at render time.

---

## 4. Tiling (the single biggest accuracy factor)

Reading a dense chart in one pass is the main cause of missed nodes and wrong levels.

| Condition | Action |
|---|---|
| Long side ≤ 4000 px and ≤ 30 megapixels | Send the whole image |
| Long side > 4000 px with aspect ratio < 1.8 (near-square, tiny text) | **Tile it** (this is what the app does too) |
| Long side > 4000 px, wide chart (aspect ratio ≥ 1.8) | Whole image is acceptable; with many units, vertical strips read more reliably |

Tiling parameters (same as the app, measured to work best):

- Each tile covers **2600 px** of the source along the long side, with **12 % overlap** between neighbours;
- Downscale each tile to **1536 px** on the long side before sending — labels stay sharp;
- Wide charts: cut vertical strips, read **left to right**. Near-square dense charts: cut horizontal strips.

After reading tiles, merge with these three rules:

1. **Same name under the same parent** → one node; keep the copy with the more complete subtree;
2. **Same name under different parents** → keep the one with better structural evidence, list the other as "uncertain";
3. **Duplicates in the overlap band** are expected — deduplicate by name, they are not two units.

Then re-check against the image: `JSON node count = sum of per-tile box counts − overlaps`. A mismatch means you dropped or invented nodes.

### Naming rules (the validator enforces these)

- Copy designations verbatim: `1st МТ-12 Anti-tank Battery`, not `1st Anti-tank Battery`;
- Model, calibre and quantity belong in the note, never in the name;
- Notes: ≤20 letters (≤12 CJK characters), never a commander's name;
- No "space + opening parenthesis" in names — move bracket content into the note;
- **Battalion and above: one node each.** No `×3` collapsing. Companies/platoons may be collapsed only when identical;
- Do not invent boxes; mark unclear units with `[?]` and keep them.

---

## 5. SIDC in 30 seconds

```
1303 | symbol set | 00 | echelon | entity | type | mobility | sector | 00000000
  4        2        2      2         6        2       2         2         8     = 30
```

| Echelon | Code | Entity | Code |
|---|---|---|---|
| Squad | 12 | HQ / command post | 110000 |
| Platoon | 14 | Infantry (incl. light infantry) | 121100 |
| Company | 15 | Armoured / mechanised (tracked) | 121102 |
| Battalion | 16 | Motorised infantry | 121104 |
| Regiment | 17 | Infantry fighting vehicle (IFV) | 121105 |
| Brigade | 18 | Armour | 120500 |
| Division | 21 | Anti-tank | 120400 |
| Corps | 22 | Artillery (general) | 130300 |
| Army group | 23 | Self-propelled artillery (tracked) | 130301 |
| | | Artillery reconnaissance / observation | 130400 |
| | | Mortar | 130800 |
| | | Air defence | 130100 |
| | | Reconnaissance | 121300 |
| | | Surveillance / radar station | 121600 |
| | | Counterintelligence | 150200 |
| | | Electronic warfare | 150500 |
| | | Liaison | 110500 |
| | | Signals | 111000 |
| | | Engineer | 140700 |
| | | Service support | 160000 |
| | | Medical / sanitary | 161300 |
| | | Judge Advocate General (JAG) | 160800 |

> Entity semantics follow the official spatialillusions.com code table (decided 2026-11-19). Note: `121100` infantry, `121102` armoured/mechanised, `121104` motorised and `121105` IFV belong to the same family (`12110x`) — **same first 5 digits, different last digit**; do not mix them up. `130301` self-propelled artillery is a legacy subtype: absent from the current site table but verified to render a real icon.

> ### ⛔ All modifier digits are disabled (user decision, 2026-11-19)
> The **14 digits after the 6-digit entity must all be zero** (type 2 + mobility 2 + sector 2 + reserved 8). **No small modifiers at all** — no `04` tracked, `05` wheeled, `41` rocket artillery, `01` sector. Vehicle/calibre/rocket details go in `uniqueDesignation`.
> Examples: motorised infantry=`130310001612110400000000000000`, self-propelled artillery=`130310001613030100000000000000`, rocket artillery=`130310001613030000000000000000` (no dedicated rocket entity on site; distinguish by name).
> `validate` reports a **warn** (not error) for non-zero modifiers, so old files with legacy modifiers still render.

The two most common mistakes:

- **Symbol set**: land units `10`, helicopters / UAVs / fixed-wing `01`. Wrong set renders as a plain box.
- **110000 (HQ) must not carry type modifier `98`**, otherwise the whole subtree disappears from the chart.

Example, armoured infantry battalion: `1303` + `10` + `00` + `16` + `121102` + `00` + `00` + `00` + `00000000`.

---

## 6. Paste-ready system prompt

```
You are an ORBAT transcription engine. Input: one chart or chart tile.
Output exactly three sections and nothing else.

<observe>
Box count: N            <- number of independent unit boxes in this tile; must be a number
Then list 5-15 key units line by line: designation + what it connects to
Mark unreadable units with [?]
</observe>

<json>
{"options":{"sidc":"30 digits","uniqueDesignation":"verbatim designation","additionalInformation":"location or role"},
 "subOrganizations":[...],"commandLevels":"1"}
</json>

<check>
JSON node count: M (and why it differs from N)
Removed (no box on the chart): ...
Uncertain (marked [?]): ...
</check>

Rules:
1. Only units actually drawn. Stop at the level the chart stops at; do not invent companies.
2. Parent/child comes from connectors only. Direct-support units (HQ company, signals,
   engineers) are siblings of battalions, not children of one.
3. Names verbatim; model/calibre/quantity go into the note; note <= 20 letters.
4. Battalion and above: one node each, never collapse with xN.
5. SIDC 30 digits: 1303|symbol set(10 land / 01 air)|00|echelon|entity|type|mobility|sector|00000000.
6. Every node must map to a box you can point at; if not, delete it.
```

For the full rule set (complete entity table, counting anchors, decision criteria), use the exported file from `orbat-cli.exe prompts --type tile`. That file is authoritative.

---

## 7. Quality loop

```
validate --blocking--> fix JSON --> validate --clean--> audit --> render
```

- `validate` returns `redCount / warnCount / issues[{level,path,message}]`; **exit 3 means blocking issues**.
- Typical blocking issues and fixes:

| Message | Meaning | Fix |
|---|---|---|
| `SIDC 必须 30 位，当前 N 位` | A segment was dropped while assembling | Rebuild per §5; check for a missing symbol set or `00` |
| `110000(HQ) 禁止加类型修饰 98` | Illegal modifier on a command post | Set type digits to `00` |
| `…是空中单位，符号集应为 01` | Helicopter/UAV with land symbol set | Change digits 5-6 to `01` |
| `同一父节点下出现同名子节点` | Merge did not deduplicate | Delete the redundant node, merge its children into the keeper |
| `注释超长` | Note over 12 CJK / 20 letters | Shorten; abbreviate locations |
| `层级倒挂` | Child outranks its parent | Re-check connectors, fix nesting or echelon code |

- `audit --in orbat.json` checks name-vs-code consistency and returns `sidcMismatches[{path,name,current,suggested,reason}]`.
  Apply `suggested` only when the name's trailing echelon word clearly conflicts. Names that begin with the parent formation, such as `2nd Division Postal Unit`, must **not** be changed.
- Apply fixes as patches; never let a model rewrite the whole tree:

```bat
:: patches.json
:: {"patches":[{"path":"root/1st Brigade/2nd Battalion","sidc":"130310001612110200000000000000"}]}
orbat-cli.exe edit --in orbat.json --patches patches.json --out orbat_fixed.json
```

Paths use `/`, start at the root name (aliases `根/` and `root/` also work), and must match node names **character for character**. Non-matching paths are skipped; the input file is never corrupted.

---

## 8. What to hand back to the user

1. `orbat.json` — original designations, untruncated;
2. `*.png` / `*.svg` — use the absolute paths from the `render` response;
3. One-line summary: **N nodes / max depth D / 0 blocking issues / K uncertain**, plus the uncertain list;
4. If you tiled: say how many tiles and how overlaps were deduplicated.

---

## 9. Troubleshooting

| Symptom | Cause | Action |
|---|---|---|
| `render` says `未找到 node ≥ 24` | Node missing or too old | Install Node 24+; the full installer ships `bin\node.exe` |
| `render` times out after ~15 s | Site unreachable, browser blocked by policy, or a very long designation | Run `selfcheck --smoke` first; move bracket content from name to note |
| `generate` complains about a missing API key | You used a Mode 1/2 command | Do not use `generate` in Mode 3; follow §2 |
| `validate` keeps returning exit 3 | Only part of the issues were fixed | Work through `issues` until `redCount` is 0 |
| `edit` reports "no path matched" | Name mismatch (spaces, full/half-width characters) | Copy the exact name from `audit` or `parse` output |
| Symbols render as blank boxes | Wrong symbol set or entity code | Check §5, or read the suggested value from `audit` |

Self-check: `orbat-cli.exe selfcheck --smoke` (about 20 s; it really renders a 3-node chart).

---

## 10. Command cheat sheet

| Command | Purpose |
|---|---|
| `prompts --type tile [--out file]` | Export the recognition prompt |
| `validate orbat.json` | Structural validation (exit 3 on blocking issues) |
| `audit --in orbat.json` | Name-vs-code consistency and cross-parent duplicate scan |
| `edit --in orbat.json --patches patches.json [--out]` | Apply field patches in bulk |
| `edit --in orbat.json --path "root/1st Bde/2nd Bn" --name/--note/--sidc [--out]` | Edit one unit |
| `normalize orbat.json --out render.json` | Convert to the renderer's 7-key form |
| `render --in orbat.json [--out basename]` | Render (needs Node ≥ 24, a browser, internet) |
| `tutorial` | Print the app's built-in tutorial (for humans) |
| `selfcheck --smoke` | Verify the whole render chain |

Add `--help` to any command for its parameters.
