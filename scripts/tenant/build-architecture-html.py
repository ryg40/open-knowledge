#!/usr/bin/env python3
import argparse
import contextlib
import copy
import difflib
import html
import io
import json
import math
import os
import re
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOURCE = os.path.join(ROOT, "deploy", "docs", "diagrams", "architecture-graph.json")
PUBLIC_OUT = os.path.join(ROOT, "deploy", "docs", "architecture.html")
LOCAL_NAME = "architecture.html"
TITLE = "OpenKnowledge architecture"
PUBLIC_LABEL = "Public"
LOCAL_LABEL = "Local-dev (real values, do not publish)"
PLACEHOLDERS = ("<domain>", "<organization>", "<repository>", "<idp>")
OVERVIEW = {
    "id": "all",
    "label": "All views",
    "summary": "This view shows every node, grouped by the kind of part. Choose another view to see one part of the system in its own frames.",
}
COLORS = {
    "root": "#0b0b0c",
    "panel": "#141414",
    "card": "#1c1b1a",
    "elevated": "#242321",
    "text": "#f3eee8",
    "muted": "#bcb0a0",
    "accent": "#e0b07e",
    "ink": "#1a1208",
    "warn": "#f2a07b",
}
GROUPS = (
    ("package", "Package", "#86b9e3"),
    ("process", "Process", "#e8a86c"),
    ("data", "Data", "#7fcca2"),
    ("network", "Network", "#c3a1f0"),
    ("identity", "Identity", "#f094ad"),
    ("repository", "Repository", "#dcc46e"),
    ("check", "Check", "#6fd3cf"),
    ("client", "Client", "#b6d873"),
    ("external", "External", "#b0a9a3"),
)
KINDS = ("core", "option")
STATUSES = ("built", "planned")
EDGE_KINDS = (
    ("request", "Request", "#8fb8de", ""),
    ("dependency", "Dependency", "#a89e93", "6 4"),
    ("data", "Data", "#7fcca2", ""),
    ("git", "Git", "#dcc46e", ""),
    ("step", "Install order", "#e8a86c", "2 5"),
    ("check", "Check", "#6fd3cf", "4 3"),
)
NODE_W = 210
NODE_H = 58
COL_GAP = 96
ROW_GAP = 18
FRAME_PAD = 20
FRAME_HEAD = 30
FRAME_GAP = 44
MAX_ROWS = 6
MAX_RANKS = 4
ASPECT = 1.4
SECTIONS = ("views", "nodes", "edges", "frames", "tours")
OVERLAY_KEYS = frozenset(SECTIONS + ("replace",))
NODE_KEYS = frozenset(("id", "label", "group", "kind", "status", "summary", "views"))
EDGE_KEYS = frozenset(("id", "from", "to", "kind", "label", "views"))
FRAME_KEYS = frozenset(("id", "view", "label", "nodes"))
TOUR_KEYS = frozenset(("id", "view", "label", "steps"))
VIEW_KEYS = frozenset(("id", "label", "summary"))
TEXT_FIELDS = {
    "views": ("label", "summary"),
    "nodes": ("label", "summary"),
    "edges": ("label",),
    "frames": ("label",),
    "tours": ("label",),
}
ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]*$")
EDGE_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9>.-]*$")
PLACEHOLDER_PATTERN = re.compile(r"<[a-z][a-z ]*>")
SENTENCE_END = re.compile(r"[.!?](?=\s|$)")


class BuildError(Exception):
    pass


def display(path):
    absolute = os.path.abspath(path)
    if absolute == ROOT or absolute.startswith(ROOT + os.sep):
        return os.path.relpath(absolute, ROOT)
    return path


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate key {key!r}")
        result[key] = value
    return result


def load_json(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle, object_pairs_hook=unique_pairs)
    except OSError as error:
        raise BuildError(f"{display(path)}: {error.strerror}") from None
    except ValueError as error:
        raise BuildError(f"{display(path)}: {error}") from None


def is_text(value):
    return isinstance(value, str) and value.strip() != ""


def sentence_count(text):
    return len(SENTENCE_END.findall(text.strip()))


def merge(graph, overlay, origin):
    if not isinstance(overlay, dict):
        raise BuildError(f"{origin}: the overlay must be a JSON object")
    unknown = sorted(set(overlay) - OVERLAY_KEYS)
    if unknown:
        raise BuildError(f"{origin}: unknown key {unknown[0]}")
    replace = overlay.get("replace", {})
    if not isinstance(replace, dict) or not all(is_text(key) and isinstance(value, str) for key, value in replace.items()):
        raise BuildError(f"{origin}: replace must map a text to a text")
    for section in SECTIONS:
        entries = overlay.get(section, [])
        if not isinstance(entries, list):
            raise BuildError(f"{origin}: {section} must be a list")
        current = graph.setdefault(section, [])
        index = {item.get("id"): item for item in current if isinstance(item, dict)}
        for entry in entries:
            if not isinstance(entry, dict) or not is_text(entry.get("id")):
                raise BuildError(f"{origin}: each entry of {section} needs an id")
            if "add_nodes" in entry and section != "frames":
                raise BuildError(f"{origin}: add_nodes belongs to frames only")
            if "add_steps" in entry and section != "tours":
                raise BuildError(f"{origin}: add_steps belongs to tours only")
            added_nodes = entry.get("add_nodes", [])
            added_steps = entry.get("add_steps", [])
            if not isinstance(added_nodes, list) or not isinstance(added_steps, list):
                raise BuildError(f"{origin}: {section} {entry['id']}: add_nodes and add_steps must be lists")
            fields = {key: copy.deepcopy(value) for key, value in entry.items() if key not in ("add_nodes", "add_steps")}
            target = index.get(entry["id"])
            if target is None:
                target = fields
                current.append(target)
                index[entry["id"]] = target
            else:
                target.update(fields)
            if added_nodes:
                members = target.setdefault("nodes", [])
                if not isinstance(members, list):
                    raise BuildError(f"{origin}: frame {entry['id']}: nodes must be a list")
                members.extend(node for node in added_nodes if node not in members)
            if added_steps:
                steps = target.setdefault("steps", [])
                if not isinstance(steps, list):
                    raise BuildError(f"{origin}: tour {entry['id']}: steps must be a list")
                steps.extend(copy.deepcopy(added_steps))
    return replace


def apply_replace(graph, mapping):
    keys = sorted(mapping, key=lambda key: (-len(key), key))

    def swap(text):
        for key in keys:
            text = text.replace(key, mapping[key])
        return text

    for section, fields in TEXT_FIELDS.items():
        for item in graph.get(section, []):
            if not isinstance(item, dict):
                continue
            for field in fields:
                if isinstance(item.get(field), str):
                    item[field] = swap(item[field])
    for tour in graph.get("tours", []):
        if not isinstance(tour, dict) or not isinstance(tour.get("steps"), list):
            continue
        for step in tour["steps"]:
            if isinstance(step, dict) and isinstance(step.get("text"), str):
                step["text"] = swap(step["text"])


def texts_of(graph):
    for section, fields in TEXT_FIELDS.items():
        for item in graph.get(section, []):
            for field in fields:
                if isinstance(item, dict) and isinstance(item.get(field), str):
                    yield f"{section} {item.get('id')}", item[field]
    for tour in graph.get("tours", []):
        for step in tour.get("steps", []) if isinstance(tour, dict) and isinstance(tour.get("steps"), list) else []:
            if isinstance(step, dict) and isinstance(step.get("text"), str):
                yield f"tours {tour.get('id')}", step["text"]


def validate(graph, public):
    errors = []

    def need(condition, message):
        if not condition:
            errors.append(message)

    if not isinstance(graph, dict):
        raise BuildError("the source must be a JSON object")
    unknown = sorted(set(graph) - set(SECTIONS))
    need(not unknown, f"unknown top-level key {unknown[0] if unknown else ''}")
    for section in SECTIONS:
        need(isinstance(graph.get(section), list), f"{section} must be a list")
    if errors:
        raise BuildError("\n".join(errors))
    view_ids = []
    for view in graph["views"]:
        vid = view.get("id") if isinstance(view, dict) else None
        need(isinstance(view, dict) and set(view) <= VIEW_KEYS, f"view {vid}: unknown key")
        need(isinstance(vid, str) and ID_PATTERN.match(vid) and vid != OVERVIEW["id"], f"view {vid}: invalid id")
        need(vid not in view_ids, f"view {vid}: duplicate id")
        need(isinstance(view, dict) and is_text(view.get("label")) and is_text(view.get("summary")), f"view {vid}: label or summary is missing")
        view_ids.append(vid)
    group_ids = {group[0] for group in GROUPS}
    node_views = {}
    for node in graph["nodes"]:
        nid = node.get("id") if isinstance(node, dict) else None
        if not isinstance(node, dict) or not isinstance(nid, str) or not ID_PATTERN.match(nid):
            errors.append(f"node {nid}: invalid id")
            continue
        need(nid not in node_views, f"node {nid}: duplicate id")
        need(set(node) <= NODE_KEYS, f"node {nid}: unknown key {sorted(set(node) - NODE_KEYS)}")
        need(is_text(node.get("label")), f"node {nid}: label is missing")
        need(node.get("group") in group_ids, f"node {nid}: unknown group {node.get('group')}")
        need(node.get("kind") in KINDS, f"node {nid}: kind must be core or option")
        need(node.get("status") in STATUSES, f"node {nid}: status must be built or planned")
        summary = node.get("summary")
        need(is_text(summary) and 2 <= sentence_count(summary) <= 4, f"node {nid}: the summary needs two to four sentences")
        views = node.get("views")
        good = isinstance(views, list) and views and len(set(map(str, views))) == len(views) and all(view in view_ids for view in views)
        need(good, f"node {nid}: views must be a list of known views")
        node_views[nid] = set(views) if good else set()
    edge_ids = set()
    kind_ids = {kind[0] for kind in EDGE_KINDS}
    for edge in graph["edges"]:
        eid = edge.get("id") if isinstance(edge, dict) else None
        if not isinstance(edge, dict) or not isinstance(eid, str) or not EDGE_ID_PATTERN.match(eid):
            errors.append(f"edge {eid}: invalid id")
            continue
        need(eid not in edge_ids, f"edge {eid}: duplicate id")
        edge_ids.add(eid)
        need(set(edge) <= EDGE_KEYS, f"edge {eid}: unknown key")
        source, target = edge.get("from"), edge.get("to")
        need(source in node_views and target in node_views, f"edge {eid}: unknown node")
        need(source != target, f"edge {eid}: an edge needs two different nodes")
        need(edge.get("kind") in kind_ids, f"edge {eid}: unknown kind {edge.get('kind')}")
        need(is_text(edge.get("label")), f"edge {eid}: label is missing")
        if "views" in edge:
            views = edge["views"]
            shared = node_views.get(source, set()) & node_views.get(target, set())
            need(isinstance(views, list) and views and all(view in shared for view in views), f"edge {eid}: each view must hold both nodes")
    frame_ids = set()
    membership = {}
    for frame in graph["frames"]:
        fid = frame.get("id") if isinstance(frame, dict) else None
        if not isinstance(frame, dict) or not isinstance(fid, str) or not ID_PATTERN.match(fid):
            errors.append(f"frame {fid}: invalid id")
            continue
        need(fid not in frame_ids, f"frame {fid}: duplicate id")
        frame_ids.add(fid)
        need(set(frame) <= FRAME_KEYS, f"frame {fid}: unknown key")
        view = frame.get("view")
        need(view in view_ids, f"frame {fid}: unknown view {view}")
        need(is_text(frame.get("label")), f"frame {fid}: label is missing")
        members = frame.get("nodes")
        if not isinstance(members, list) or not members:
            errors.append(f"frame {fid}: nodes must be a list with one node or more")
            continue
        for member in members:
            need(view in node_views.get(member, set()), f"frame {fid}: node {member} is not in view {view}")
            membership.setdefault((view, member), []).append(fid)
    for nid, views in node_views.items():
        for view in sorted(views):
            count = len(membership.get((view, nid), []))
            need(count == 1, f"node {nid}: view {view} needs it in exactly one frame, found {count}")
    tour_views = []
    tour_ids = set()
    for tour in graph["tours"]:
        tid = tour.get("id") if isinstance(tour, dict) else None
        if not isinstance(tour, dict) or not isinstance(tid, str) or not ID_PATTERN.match(tid):
            errors.append(f"tour {tid}: invalid id")
            continue
        need(tid not in tour_ids, f"tour {tid}: duplicate id")
        tour_ids.add(tid)
        need(set(tour) <= TOUR_KEYS, f"tour {tid}: unknown key")
        view = tour.get("view")
        need(view in view_ids, f"tour {tid}: unknown view {view}")
        tour_views.append(view)
        need(is_text(tour.get("label")), f"tour {tid}: label is missing")
        steps = tour.get("steps")
        if not isinstance(steps, list) or not steps:
            errors.append(f"tour {tid}: steps must be a list with one entry or more")
            continue
        for number, entry in enumerate(steps, 1):
            members = entry.get("nodes") if isinstance(entry, dict) else None
            need(isinstance(entry, dict) and set(entry) <= {"nodes", "text"}, f"tour {tid} entry {number}: unknown key")
            need(isinstance(members, list) and members and all(view in node_views.get(member, set()) for member in members), f"tour {tid} entry {number}: each node must be in view {view}")
            need(isinstance(entry, dict) and is_text(entry.get("text")), f"tour {tid} entry {number}: text is missing")
    for view in view_ids:
        need(tour_views.count(view) == 1, f"view {view}: needs exactly one tour, found {tour_views.count(view)}")
    if public:
        for where, text in texts_of(graph):
            for token in PLACEHOLDER_PATTERN.findall(text):
                need(token in PLACEHOLDERS, f"{where}: placeholder {token} is not one of {', '.join(PLACEHOLDERS)}")
    if errors:
        raise BuildError("\n".join(errors[:40]))
    return node_views


def rank_members(members, links):
    following = {node: [] for node in members}
    for source, target in links:
        if target not in following[source]:
            following[source].append(target)
    seen = set()
    finished = []
    for root in members:
        if root in seen:
            continue
        seen.add(root)
        stack = [(root, iter(following[root]))]
        while stack:
            node, children = stack[-1]
            advanced = False
            for child in children:
                if child not in seen:
                    seen.add(child)
                    stack.append((child, iter(following[child])))
                    advanced = True
                    break
            if not advanced:
                finished.append(node)
                stack.pop()
    order = list(reversed(finished))
    place = {node: index for index, node in enumerate(order)}
    rank = {node: 0 for node in members}
    for node in order:
        for child in following[node]:
            if place[child] > place[node]:
                rank[child] = max(rank[child], rank[node] + 1)
    return rank


def shelve(blocks, limit):
    x = y = band = 0
    for block in blocks:
        if x > 0 and x + block["w"] > limit:
            x = 0
            y += band + FRAME_GAP
            band = 0
        block["x"], block["y"] = x, y
        x += block["w"] + FRAME_GAP
        band = max(band, block["h"])
    return max(block["x"] + block["w"] for block in blocks), max(block["y"] + block["h"] for block in blocks)


def best_limit(blocks):
    widest = max(block["w"] for block in blocks)
    candidates = {widest}
    for start in range(len(blocks)):
        total = 0
        for block in blocks[start:]:
            total += block["w"] + (FRAME_GAP if total else 0)
            if total >= widest:
                candidates.add(total)
    best = None
    for limit in sorted(candidates):
        width, height = shelve(blocks, limit)
        score = min(ASPECT / width, 1 / height)
        if best is None or score > best[0] + 1e-12:
            best = (score, limit)
    return best[1]


def place(frames, links):
    neighbours = {}
    ranks = {}
    for source, target in links:
        neighbours.setdefault(source, []).append(target)
        neighbours.setdefault(target, []).append(source)
    blocks = []
    for frame in frames:
        members = list(frame["nodes"])
        member_set = set(members)
        internal = [(source, target) for source, target in links if source in member_set and target in member_set and source != target]
        rank = rank_members(members, internal)
        ranks.update(rank)
        levels = max(rank.values()) + 1
        if levels > MAX_RANKS:
            rank = {node: value * MAX_RANKS // levels for node, value in rank.items()}
        columns = []
        for value in sorted(set(rank.values())):
            layer = [node for node in members if rank[node] == value]
            count = math.ceil(len(layer) / MAX_ROWS)
            size = math.ceil(len(layer) / count)
            columns.extend(layer[start:start + size] for start in range(0, len(layer), size))
        rows = max(len(column) for column in columns)
        width = len(columns) * NODE_W + (len(columns) - 1) * COL_GAP + 2 * FRAME_PAD
        height = FRAME_HEAD + rows * NODE_H + (rows - 1) * ROW_GAP + 2 * FRAME_PAD
        blocks.append({"frame": frame, "columns": columns, "rows": rows, "w": width, "h": height})
    shelve(blocks, best_limit(blocks))
    positions = {}

    def set_column(block, index):
        column = block["columns"][index]
        left = block["x"] + FRAME_PAD + index * (NODE_W + COL_GAP)
        offset = (block["rows"] - len(column)) * (NODE_H + ROW_GAP) / 2
        for row, node in enumerate(column):
            positions[node] = (left, block["y"] + FRAME_HEAD + FRAME_PAD + offset + row * (NODE_H + ROW_GAP))

    sequence = [(block, index) for block in blocks for index in range(len(block["columns"]))]
    for block, index in sequence:
        set_column(block, index)
    for sweep in range(6):
        for block, index in sequence if sweep % 2 == 0 else list(reversed(sequence)):
            column = block["columns"][index]
            inside = set(column)

            def weight(item):
                spot, node = item
                others = [positions[other][1] for other in neighbours.get(node, []) if other in positions and other not in inside]
                centre = sum(others) / len(others) if others else positions[node][1]
                return (ranks[node], round(centre, 6), spot)

            block["columns"][index] = [node for spot, node in sorted(enumerate(column), key=weight)]
            set_column(block, index)
    frames_out = []
    for block in blocks:
        frames_out.append({"id": block["frame"]["id"], "label": block["frame"]["label"], "x": block["x"], "y": block["y"], "w": block["w"], "h": block["h"]})
    nodes_out = {node: [int(round(spot[0])), int(round(spot[1]))] for node, spot in positions.items()}
    size = [max(block["x"] + block["w"] for block in blocks), max(block["y"] + block["h"] for block in blocks)]
    return {"frames": frames_out, "nodes": nodes_out, "size": size}


def render_payload(graph, node_views, local):
    view_order = {view["id"]: index for index, view in enumerate(graph["views"])}
    edges = []
    for edge in graph["edges"]:
        if "views" in edge:
            views = sorted(set(edge["views"]), key=view_order.get)
        else:
            views = sorted(node_views[edge["from"]] & node_views[edge["to"]], key=view_order.get)
        edges.append({"id": edge["id"], "from": edge["from"], "to": edge["to"], "kind": edge["kind"], "label": edge["label"], "views": [OVERVIEW["id"]] + views})
    nodes = [{key: node[key] for key in ("id", "label", "group", "kind", "status", "summary", "views")} for node in graph["nodes"]]
    layouts = {}
    overview_frames = []
    for group_id, group_label, _ in GROUPS:
        members = [node["id"] for node in nodes if node["group"] == group_id]
        if members:
            overview_frames.append({"id": f"group-{group_id}", "label": group_label, "nodes": members})
    layouts[OVERVIEW["id"]] = place(overview_frames, [(edge["from"], edge["to"]) for edge in edges])
    for view in graph["views"]:
        frames = [frame for frame in graph["frames"] if frame["view"] == view["id"]]
        links = [(edge["from"], edge["to"]) for edge in edges if view["id"] in edge["views"]]
        layouts[view["id"]] = place(frames, links)
    return {
        "title": TITLE,
        "version": LOCAL_LABEL if local else PUBLIC_LABEL,
        "size": {"w": NODE_W, "h": NODE_H},
        "colors": COLORS,
        "groups": [{"id": group_id, "label": label, "color": color} for group_id, label, color in GROUPS],
        "edgeKinds": [{"id": kind_id, "label": label, "color": color, "dash": dash} for kind_id, label, color, dash in EDGE_KINDS],
        "views": [OVERVIEW] + [{"id": view["id"], "label": view["label"], "summary": view["summary"]} for view in graph["views"]],
        "nodes": nodes,
        "edges": edges,
        "tours": [{"id": tour["id"], "view": tour["view"], "label": tour["label"], "steps": tour["steps"]} for tour in graph["tours"]],
        "layouts": layouts,
    }


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def serialize(payload):
    lines = ["{"]
    keys = list(payload)
    for position, key in enumerate(keys):
        value = payload[key]
        tail = "," if position < len(keys) - 1 else ""
        if isinstance(value, list) and value:
            lines.append(f"{json.dumps(key)}:[")
            lines.extend(compact(item) + ("," if index < len(value) - 1 else "") for index, item in enumerate(value))
            lines.append("]" + tail)
        elif key == "layouts":
            lines.append(f"{json.dumps(key)}:{{")
            names = list(value)
            lines.extend(f"{json.dumps(name)}:{compact(value[name])}" + ("," if index < len(names) - 1 else "") for index, name in enumerate(names))
            lines.append("}" + tail)
        else:
            lines.append(f"{json.dumps(key)}:{compact(value)}{tail}")
    lines.append("}")
    return re.sub(r"<(?=[/!])", r"\\u003c", "\n".join(lines))


def stylesheet():
    names = "".join(f"--{name}:{value};" for name, value in COLORS.items())
    return ":root{" + names + "--line:rgba(224,176,126,0.16);--edge-line:rgba(224,176,126,0.3);}\n" + STYLE


def page(payload, local):
    version = payload["version"]
    text = TEMPLATE
    for token, value in (
        ("__TITLE__", html.escape(f"{TITLE}: {version}")),
        ("__HEADING__", html.escape(TITLE)),
        ("__VERSION__", html.escape(version)),
        ("__BODY__", "local" if local else "public"),
        ("__CSS__", stylesheet()),
        ("__JS__", SCRIPT.strip("\n")),
        ("__DATA__", serialize(payload)),
    ):
        text = text.replace(token, value)
    return text


def assemble(graph, overlays):
    graph = copy.deepcopy(graph)
    replace = {}
    for origin, overlay in overlays:
        replace.update(merge(graph, overlay, origin))
    apply_replace(graph, replace)
    node_views = validate(graph, public=not overlays)
    payload = render_payload(graph, node_views, bool(overlays))
    stats = {"nodes": len(graph["nodes"]), "edges": len(graph["edges"]), "tours": len(graph["tours"]), "views": len(graph["views"])}
    return page(payload, bool(overlays)), payload, stats


def build(source, overlay_paths):
    graph = load_json(source)
    overlays = [(display(path), load_json(path)) for path in overlay_paths]
    return assemble(graph, overlays)


def default_out(overlay_paths):
    if overlay_paths:
        return os.path.join(os.path.dirname(os.path.abspath(overlay_paths[-1])), LOCAL_NAME)
    return PUBLIC_OUT


def write_file(path, text):
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix=".architecture.", dir=directory)
    try:
        with os.fdopen(handle, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(text)
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(temporary)
        raise


def compare(path, text, summary):
    shown = display(path)
    try:
        with open(path, "rb") as handle:
            current = handle.read()
    except FileNotFoundError:
        print(f"architecture: missing {shown}")
        return 1
    except OSError as error:
        print(f"architecture: cannot read {shown}: {error.strerror}", file=sys.stderr)
        return 2
    if current == text.encode("utf-8"):
        print(f"architecture: ok {shown} ({summary})")
        return 0
    print(f"architecture: differs {shown}; run the builder without --check to write it")
    lines = difflib.unified_diff(current.decode("utf-8", "replace").splitlines(), text.splitlines(), f"{shown} on disk", f"{shown} built", lineterm="", n=1)
    for count, line in enumerate(lines):
        if count == 40:
            print("...")
            break
        print(line[:240])
    return 1


def contrast(first, second):
    def luminance(color):
        channels = [int(color[index:index + 2], 16) / 255 for index in (1, 3, 5)]
        linear = [value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4 for value in channels]
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]

    high, low = sorted((luminance(first), luminance(second)), reverse=True)
    return (high + 0.05) / (low + 0.05)


FIXTURE = {
    "views": [
        {"id": "alpha", "label": "Alpha", "summary": "The first view. It has three nodes."},
        {"id": "beta", "label": "Beta", "summary": "The second view. It has two nodes."},
    ],
    "nodes": [
        {"id": "one", "label": "One at <domain>", "group": "process", "kind": "core", "status": "built", "summary": "The first node. It starts the work.", "views": ["alpha"]},
        {"id": "two", "label": "Two", "group": "data", "kind": "option", "status": "built", "summary": "The second node. It holds the data.", "views": ["alpha", "beta"]},
        {"id": "three", "label": "Three", "group": "identity", "kind": "core", "status": "planned", "summary": "The third node. Nobody built it yet.", "views": ["alpha"]},
        {"id": "four", "label": "Four", "group": "check", "kind": "core", "status": "built", "summary": "The fourth node. It checks the data.", "views": ["beta"]},
    ],
    "edges": [
        {"id": "one>two", "from": "one", "to": "two", "kind": "request", "label": "calls"},
        {"id": "two>three", "from": "two", "to": "three", "kind": "data", "label": "feeds"},
        {"id": "three>one", "from": "three", "to": "one", "kind": "check", "label": "closes the loop"},
        {"id": "two>four", "from": "two", "to": "four", "kind": "step", "label": "next", "views": ["beta"]},
    ],
    "frames": [
        {"id": "alpha-left", "view": "alpha", "label": "Left", "nodes": ["one", "two"]},
        {"id": "alpha-right", "view": "alpha", "label": "Right", "nodes": ["three"]},
        {"id": "beta-all", "view": "beta", "label": "All", "nodes": ["two", "four"]},
    ],
    "tours": [
        {"id": "alpha-tour", "view": "alpha", "label": "Alpha tour", "steps": [{"nodes": ["one"], "text": "Start here."}]},
        {"id": "beta-tour", "view": "beta", "label": "Beta tour", "steps": [{"nodes": ["two", "four"], "text": "Both nodes."}]},
    ],
}
OVERLAY_FIXTURE = {
    "replace": {"<domain>": "example.org"},
    "nodes": [
        {"id": "one", "label": "One renamed at <domain>"},
        {"id": "five", "label": "Five", "group": "external", "kind": "option", "status": "built", "summary": "An added node. Only the overlay has it.", "views": ["beta"]},
    ],
    "edges": [{"id": "four>five", "from": "four", "to": "five", "kind": "check", "label": "checks"}],
    "frames": [{"id": "beta-all", "add_nodes": ["five"]}],
    "tours": [{"id": "beta-tour", "add_steps": [{"nodes": ["five"], "text": "The added node."}]}],
}


def selftest():
    results = []

    def expect(condition, message):
        results.append(message)
        if not condition:
            raise AssertionError(message)

    def refused(graph, overlays, message):
        try:
            assemble(graph, overlays)
        except BuildError:
            results.append(message)
            return
        raise AssertionError(message)

    try:
        first, payload, stats = assemble(FIXTURE, [])
        second, _, _ = assemble(FIXTURE, [])
        expect(first == second, "two builds give the same bytes")
        expect(f"<title>{TITLE}: {PUBLIC_LABEL}</title>" in first and html.escape(LOCAL_LABEL) not in first, "the public page names its version")
        expect(stats == {"nodes": 4, "edges": 4, "tours": 2, "views": 2}, "the public counts are right")
        local, local_payload, local_stats = assemble(FIXTURE, [("fixture overlay", OVERLAY_FIXTURE)])
        expect(html.escape(LOCAL_LABEL) in local and "local" in local, "the local page names its version")
        expect("One renamed at example.org" in local and "<domain>" not in serialize(local_payload), "the overlay renames and replaces")
        expect(local_stats["nodes"] == 5 and "The added node." in local, "the overlay adds a node and a tour entry")
        expect(local_payload["layouts"]["beta"]["nodes"].keys() == {"two", "four", "five"}, "the overlay adds a node to a frame")
        expect(default_out(["a/b/overlay.json"]).endswith(os.path.join("a", "b", LOCAL_NAME)), "the local page goes next to the last overlay")
        for name, layout in list(payload["layouts"].items()) + list(local_payload["layouts"].items()):
            spots = list(layout["nodes"].values())
            for index, a in enumerate(spots):
                for b in spots[index + 1:]:
                    expect(abs(a[0] - b[0]) >= NODE_W or abs(a[1] - b[1]) >= NODE_H, f"no two nodes overlap in {name}")
            for frame in layout["frames"]:
                expect(frame["x"] >= 0 and frame["y"] >= 0, f"frame {frame['id']} starts inside the canvas")
        bad_group = copy.deepcopy(FIXTURE)
        bad_group["nodes"][0]["group"] = "unknown"
        refused(bad_group, [], "an unknown group is refused")
        loose = copy.deepcopy(FIXTURE)
        loose["frames"][1]["nodes"] = ["one"]
        refused(loose, [], "a node outside a frame or in two frames is refused")
        dangling = copy.deepcopy(FIXTURE)
        dangling["edges"].append({"id": "one>nine", "from": "one", "to": "nine", "kind": "data", "label": "lost"})
        refused(dangling, [], "an edge to an unknown node is refused")
        short = copy.deepcopy(FIXTURE)
        short["nodes"][1]["summary"] = "Only one sentence."
        refused(short, [], "a summary with one sentence is refused")
        private = copy.deepcopy(FIXTURE)
        private["nodes"][1]["label"] = "Two at <private host>"
        refused(private, [], "an unknown placeholder in the public version is refused")
        twice = copy.deepcopy(FIXTURE)
        twice["tours"].append({"id": "alpha-again", "view": "alpha", "label": "Again", "steps": [{"nodes": ["two"], "text": "Again."}]})
        refused(twice, [], "a second tour for one view is refused")
        refused(FIXTURE, [("bad overlay", {"colour": "red"})], "an unknown overlay key is refused")
        refused(FIXTURE, [("bad overlay", {"nodes": [{"id": "one", "add_steps": []}]})], "add_steps outside tours is refused")
        pairs = [("text", "panel"), ("text", "card"), ("text", "root"), ("muted", "panel"), ("muted", "card"), ("accent", "panel"), ("accent", "root"), ("ink", "accent"), ("ink", "warn")]
        for first_name, second_name in pairs:
            expect(contrast(COLORS[first_name], COLORS[second_name]) >= 4.5, f"{first_name} on {second_name} meets WCAG AA")
        for group_id, _, color in GROUPS:
            expect(contrast(color, COLORS["card"]) >= 4.5, f"the border of group {group_id} has contrast")
        for kind_id, _, color, _ in EDGE_KINDS:
            expect(contrast(color, COLORS["root"]) >= 3, f"the edge colour of {kind_id} has contrast")
        source = TEMPLATE + STYLE + SCRIPT
        expect("://" not in source, "the page template makes no network request")
        expect("/*" not in source and "<!--" not in source, "the page template has no block comment")
        expect(not any(line.strip().startswith("//") for line in SCRIPT.splitlines()), "the script has no line comment")
        expect("<script src" not in first and "<link" not in first and "@import" not in first and "url(" not in first.replace("url(#arrow-", ""), "the page loads no outside file")
        with tempfile.TemporaryDirectory() as directory:
            target = os.path.join(directory, LOCAL_NAME)
            quiet = io.StringIO()
            with contextlib.redirect_stdout(quiet):
                missing = compare(target, first, "fixture")
                write_file(target, first)
                same = compare(target, first, "fixture")
                with open(target, "a", encoding="utf-8") as handle:
                    handle.write("x")
                changed = compare(target, first, "fixture")
            expect((missing, same, changed) == (1, 0, 1), "the check finds a missing file and a changed file")
    except AssertionError as error:
        print(f"architecture: selftest failed: {error}", file=sys.stderr)
        return 1
    print(f"architecture: selftest ok ({len(results)} checks)")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(prog="build-architecture-html.py", description="Build the interactive architecture page from its graph source.")
    parser.add_argument("--source", default=SOURCE, help="the public graph source")
    parser.add_argument("--overlay", action="append", default=[], help="an overlay that renames, replaces and adds; give it more than one time to stack overlays")
    parser.add_argument("--out", help="the page to write or check; the default is the public page, or architecture.html next to the last overlay")
    parser.add_argument("--check", action="store_true", help="build in memory and compare with the page on disk")
    parser.add_argument("--selftest", action="store_true", help="test the builder on a small fixture")
    args = parser.parse_args(argv)
    if args.selftest:
        if args.check or args.overlay or args.out:
            parser.error("--selftest takes no other option")
        return selftest()
    out = args.out or default_out(args.overlay)
    try:
        text, _, stats = build(args.source, args.overlay)
    except BuildError as error:
        print(f"architecture: invalid input: {error}", file=sys.stderr)
        return 2
    summary = f"{stats['nodes']} nodes, {stats['edges']} edges, {stats['tours']} tours, {stats['views']} views"
    if args.check:
        return compare(out, text, summary)
    try:
        write_file(out, text)
    except OSError as error:
        print(f"architecture: cannot write {display(out)}: {error.strerror}", file=sys.stderr)
        return 2
    print(f"architecture: wrote {display(out)} ({summary})")
    return 0


TEMPLATE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark">
<title>__TITLE__</title>
<style>
__CSS__
</style>
</head>
<body class="__BODY__">
<header class="banner">
<div class="brand"><span class="mark"></span><h1>__HEADING__</h1></div>
<span class="badge" id="version-badge">__VERSION__</span>
<span class="stats" id="stats"></span>
</header>
<div class="layout">
<aside class="sidebar" aria-label="Search, views and filters">
<section>
<h2>Search</h2>
<input id="search" type="search" placeholder="Label or summary" aria-label="Search the nodes" autocomplete="off">
<ul id="search-results" class="results"></ul>
</section>
<section>
<h2>View</h2>
<div id="view-list" class="view-list"></div>
</section>
<section>
<h2>Groups</h2>
<div id="group-list"></div>
</section>
<section>
<h2>Path finder</h2>
<label class="field">From<select id="path-from"></select></label>
<label class="field">To<select id="path-to"></select></label>
<div class="row"><button id="path-find" type="button">Find path</button><button id="path-clear" class="quiet" type="button">Clear</button></div>
<p id="path-note" class="note"></p>
<ol id="path-result" class="path-result"></ol>
</section>
<section>
<h2>Legend</h2>
<div id="legend"></div>
</section>
</aside>
<main class="stage">
<svg id="canvas" aria-label="Architecture graph"><defs id="defs"></defs><g id="viewport"><g id="frame-layer"></g><g id="edge-layer"></g><g id="node-layer"></g><g id="label-layer"></g></g></svg>
<div class="zoom"><button id="zoom-in" type="button" aria-label="Zoom in">+</button><button id="zoom-out" type="button" aria-label="Zoom out">&minus;</button><button id="zoom-fit" type="button">Fit</button></div>
<div id="tooltip" class="tooltip" hidden></div>
<div class="tourbar">
<select id="tour-select" aria-label="Tour"></select>
<button id="tour-prev" type="button" aria-label="Previous tour stop">&larr;</button>
<span id="tour-count" class="tour-count"></span>
<button id="tour-next" type="button" aria-label="Next tour stop">&rarr;</button>
<p id="tour-text" class="tour-text"></p>
</div>
</main>
<aside class="detail" id="detail" aria-label="Details"></aside>
</div>
<script id="graph-data" type="application/json">
__DATA__
</script>
<script>
__JS__
</script>
</body>
</html>
"""

STYLE = r"""* { box-sizing: border-box; }
.tooltip[hidden] { display: none; }
html, body { height: 100%; margin: 0; }
body { background: var(--root); color: var(--text); font: 14px/1.45 system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; overflow: hidden; }
.banner { height: 54px; display: flex; align-items: center; gap: 14px; padding: 0 18px; border-bottom: 1px solid var(--line); background: linear-gradient(180deg, #171615, #0f0f0f); }
.brand { display: flex; align-items: center; gap: 10px; }
.mark { width: 12px; height: 12px; border-radius: 3px; background: var(--accent); box-shadow: 0 0 14px rgba(224, 176, 126, 0.55); }
.banner h1 { margin: 0; font: 400 21px/1 Georgia, "Times New Roman", serif; letter-spacing: 0.2px; }
.badge { font-size: 12px; font-weight: 700; padding: 3px 11px; border-radius: 999px; border: 1px solid var(--accent); color: var(--accent); }
body.local .badge { background: var(--warn); border-color: var(--warn); color: var(--ink); }
body.local .banner { box-shadow: inset 0 -2px 0 var(--warn); }
.stats { margin-left: auto; color: var(--muted); font-size: 12px; }
.layout { display: grid; grid-template-columns: 292px minmax(0, 1fr) 340px; height: calc(100% - 54px); }
.sidebar, .detail { background: var(--panel); overflow-y: auto; padding: 16px 16px 28px; }
.sidebar { border-right: 1px solid var(--line); }
.detail { border-left: 1px solid var(--line); }
section { margin-bottom: 20px; }
h2 { margin: 0 0 8px; font-size: 11px; font-weight: 700; letter-spacing: 1.3px; text-transform: uppercase; color: var(--accent); }
.detail h3 { margin: 2px 0 12px; font: 400 23px/1.2 Georgia, "Times New Roman", serif; }
.detail p { margin: 0 0 14px; }
input[type="search"], select { width: 100%; padding: 7px 9px; color: var(--text); background: var(--card); border: 1px solid var(--edge-line); border-radius: 8px; font: inherit; }
.field { display: block; margin: 6px 0; color: var(--muted); font-size: 12px; }
.field select { margin-top: 3px; }
button { padding: 6px 10px; color: var(--text); background: var(--elevated); border: 1px solid var(--edge-line); border-radius: 8px; font: inherit; }
button:hover:not(:disabled) { border-color: var(--accent); }
button:disabled { opacity: 0.45; }
button:focus-visible, input:focus-visible, select:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
.row { display: flex; gap: 8px; margin-top: 8px; }
.quiet { background: transparent; }
.view-list { display: flex; flex-wrap: wrap; gap: 6px; }
.view-list button[aria-pressed="true"] { background: var(--accent); border-color: var(--accent); color: var(--ink); font-weight: 700; }
.group-row { display: flex; align-items: center; gap: 8px; margin: 4px 0; }
.group-row .count { margin-left: auto; color: var(--muted); font-size: 12px; }
.swatch { display: inline-block; width: 12px; height: 12px; border-radius: 3px; flex: none; }
.legend-row { display: flex; align-items: center; gap: 9px; margin: 5px 0; color: var(--muted); font-size: 12px; }
.legend-row svg { flex: none; }
.results, .links { list-style: none; padding: 0; margin: 8px 0 0; }
.results button, .links button, .hop { display: block; width: 100%; margin: 3px 0; text-align: left; background: var(--card); }
.target { display: block; color: var(--text); }
.via { display: block; color: var(--muted); font-size: 12px; }
.note { color: var(--muted); font-size: 12px; }
.path-result { margin: 8px 0 0; padding-left: 22px; color: var(--muted); }
.chips { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 14px; }
.chip { display: inline-flex; align-items: center; gap: 6px; padding: 2px 9px; border-radius: 999px; background: var(--card); border: 1px solid var(--edge-line); font-size: 12px; }
.chip.planned { border-style: dotted; border-color: var(--accent); }
.chip.option { border-style: dashed; }
.stage { position: relative; overflow: hidden; background: radial-gradient(circle at 50% 35%, #131211 0%, var(--root) 72%); }
#canvas { display: block; width: 100%; height: 100%; touch-action: none; user-select: none; }
.frame { animation: appear 0.4s ease both; }
.frame rect { fill: rgba(255, 255, 255, 0.022); stroke: rgba(224, 176, 126, 0.22); stroke-width: 1; }
.frame text { fill: var(--accent); font-size: 12px; font-weight: 700; letter-spacing: 0.6px; }
@keyframes appear { from { opacity: 0; } to { opacity: 1; } }
.node { transition: opacity 0.2s ease; }
.node .card { fill: var(--card); stroke: var(--group); stroke-width: 1.6; }
.node.kind-option .card { stroke-dasharray: 7 4; }
.node.status-planned .card { stroke-dasharray: 1.5 4.5; stroke-linecap: round; stroke-width: 2.2; }
.node .label { fill: var(--text); font-size: 13px; font-weight: 600; }
.node .meta { fill: var(--muted); font-size: 11px; }
.node.dim { opacity: 0.17; }
.node.match .card { stroke: var(--accent); stroke-width: 2.4; }
.node.tour .card, .node.path .card { stroke: var(--accent); stroke-width: 2.8; }
.node.selected .card { stroke: var(--accent); stroke-width: 3.2; filter: drop-shadow(0 0 9px rgba(224, 176, 126, 0.6)); }
.node.hidden, .edge.hidden { display: none; }
.edge { fill: none; stroke-width: 1.4; opacity: 0.5; transition: opacity 0.2s ease; }
.edge.dim { opacity: 0.06; }
.edge.lit { opacity: 1; stroke-width: 2.4; }
.edge-label { display: none; fill: var(--text); font-size: 10.5px; text-anchor: middle; paint-order: stroke; stroke: var(--root); stroke-width: 4px; stroke-linejoin: round; }
.edge-label.show { display: inline; }
.zoom { position: absolute; top: 14px; right: 14px; display: flex; flex-direction: column; gap: 6px; }
.zoom button { min-width: 42px; background: rgba(28, 27, 26, 0.92); }
.tooltip { position: absolute; z-index: 5; max-width: 300px; padding: 6px 10px; pointer-events: none; background: rgba(20, 20, 20, 0.97); border: 1px solid var(--edge-line); border-radius: 8px; font-size: 12px; }
.tooltip strong { display: block; color: var(--text); }
.tooltip span { color: var(--muted); }
.tourbar { position: absolute; left: 16px; right: 16px; bottom: 14px; display: grid; grid-template-columns: minmax(180px, 260px) auto auto auto minmax(0, 1fr); gap: 10px; align-items: center; padding: 10px 12px; background: rgba(20, 20, 20, 0.95); border: 1px solid var(--edge-line); border-radius: 12px; box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5); }
.tour-count { min-width: 52px; color: var(--muted); font-size: 12px; text-align: center; }
.tour-text { margin: 0; color: var(--text); }
"""

SCRIPT = r"""
(() => {
  'use strict';
  const data = JSON.parse(document.getElementById('graph-data').textContent);
  const byId = (id) => document.getElementById(id);
  const svg = byId('canvas');
  const NS = svg.namespaceURI;
  const viewport = byId('viewport');
  const frameLayer = byId('frame-layer');
  const edgeLayer = byId('edge-layer');
  const nodeLayer = byId('node-layer');
  const labelLayer = byId('label-layer');
  const tooltip = byId('tooltip');
  const W = data.size.w;
  const H = data.size.h;
  const overview = data.views[0].id;
  const groups = new Map(data.groups.map((g) => [g.id, g]));
  const kinds = new Map(data.edgeKinds.map((k) => [k.id, k]));
  const nodes = new Map(data.nodes.map((n) => [n.id, n]));
  const views = new Map(data.views.map((v) => [v.id, v]));
  const tours = new Map(data.tours.map((t) => [t.id, t]));
  const outgoing = new Map(data.nodes.map((n) => [n.id, []]));
  const incoming = new Map(data.nodes.map((n) => [n.id, []]));
  for (const e of data.edges) {
    outgoing.get(e.from).push(e);
    incoming.get(e.to).push(e);
  }
  const state = {
    view: overview,
    selected: null,
    hidden: new Set(),
    query: '',
    tour: null,
    at: 0,
    path: null,
    camera: { x: 0, y: 0, k: 1 },
    positions: new Map(),
    motion: 0,
    glide: 0,
  };
  const drag = { active: false, moved: false, x: 0, y: 0, camera: null };
  const nodeEls = new Map();
  const edgeEls = new Map();

  function svgEl(name, attrs, parent) {
    const item = document.createElementNS(NS, name);
    for (const [key, value] of Object.entries(attrs || {})) item.setAttribute(key, String(value));
    if (parent) parent.appendChild(item);
    return item;
  }

  function htmlEl(tag, className, text, parent) {
    const item = document.createElement(tag);
    if (className) item.className = className;
    if (text !== undefined && text !== null) item.textContent = text;
    if (parent) parent.appendChild(item);
    return item;
  }

  const has = (object, key) => Object.hasOwn(object, key);
  const shorten = (text, max) => (text.length > max ? `${text.slice(0, max - 1)}…` : text);
  const layout = (view) => data.layouts[view || state.view];
  const inLayout = (id, view) => has(layout(view).nodes, id);
  const visibleNode = (id) => inLayout(id) && !state.hidden.has(nodes.get(id).group);
  const visibleEdge = (e) => e.views.includes(state.view) && visibleNode(e.from) && visibleNode(e.to);
  const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2);
  const matches = (n, q) => n.label.toLowerCase().includes(q) || n.summary.toLowerCase().includes(q);
  const metaText = (n) => {
    const parts = [groups.get(n.group).label];
    if (n.kind === 'option') parts.push('option');
    if (n.status === 'planned') parts.push('planned');
    return parts.join(' · ');
  };

  for (const k of data.edgeKinds) {
    const marker = svgEl('marker', { id: `arrow-${k.id}`, viewBox: '0 0 10 10', refX: 9, refY: 5, markerWidth: 7, markerHeight: 7, orient: 'auto-start-reverse' }, byId('defs'));
    svgEl('path', { d: 'M0,0 L10,5 L0,10 z', fill: k.color }, marker);
  }

  for (const e of data.edges) {
    const kind = kinds.get(e.kind);
    const path = svgEl('path', { class: `edge kind-${e.kind}`, stroke: kind.color, 'marker-end': `url(#arrow-${e.kind})` }, edgeLayer);
    if (kind.dash) path.setAttribute('stroke-dasharray', kind.dash);
    const label = svgEl('text', { class: 'edge-label' }, labelLayer);
    label.textContent = e.label;
    edgeEls.set(e.id, { path, label });
  }

  for (const n of data.nodes) {
    const group = groups.get(n.group);
    const item = svgEl('g', { class: `node kind-${n.kind} status-${n.status}`, 'data-id': n.id }, nodeLayer);
    svgEl('rect', { class: 'card', width: W, height: H, rx: 9, ry: 9, style: `--group:${group.color}` }, item);
    svgEl('rect', { class: 'bar', x: 9, y: 9, width: 5, height: H - 18, rx: 2.5, fill: group.color }, item);
    const title = svgEl('text', { class: 'label', x: 24, y: 25 }, item);
    title.textContent = shorten(n.label, 25);
    const meta = svgEl('text', { class: 'meta', x: 24, y: 44 }, item);
    meta.textContent = metaText(n);
    item.addEventListener('click', (event) => {
      event.stopPropagation();
      if (!drag.moved) select(n.id);
    });
    item.addEventListener('pointerenter', (event) => showTip(n, event));
    item.addEventListener('pointermove', placeTip);
    item.addEventListener('pointerleave', hideTip);
    nodeEls.set(n.id, item);
  }

  function route(from, to) {
    const a = state.positions.get(from);
    const b = state.positions.get(to);
    if (!a || !b) return null;
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    let points;
    if (Math.abs(dx) >= W * 0.75) {
      const forward = dx > 0;
      const sx = forward ? a[0] + W : a[0];
      const tx = forward ? b[0] : b[0] + W;
      const sy = a[1] + H / 2;
      const ty = b[1] + H / 2;
      const bend = Math.max(36, Math.abs(tx - sx) / 2) * (forward ? 1 : -1);
      points = [sx, sy, sx + bend, sy, tx - bend, ty, tx, ty];
    } else if (Math.abs(dy) <= H + 44) {
      const down = dy >= 0;
      const sx = a[0] + W / 2;
      const tx = b[0] + W / 2;
      const sy = down ? a[1] + H : a[1];
      const ty = down ? b[1] : b[1] + H;
      const bend = Math.max(14, Math.abs(ty - sy) / 2) * (down ? 1 : -1);
      points = [sx, sy, sx, sy + bend, tx, ty - bend, tx, ty];
    } else {
      const sx = a[0] + W;
      const tx = b[0] + W;
      const sy = a[1] + H / 2;
      const ty = b[1] + H / 2;
      const bulge = 34 + Math.min(110, Math.abs(dy) / 4);
      points = [sx, sy, sx + bulge, sy, tx + bulge, ty, tx, ty];
    }
    const [x0, y0, x1, y1, x2, y2, x3, y3] = points;
    return {
      d: `M${x0.toFixed(1)},${y0.toFixed(1)} C${x1.toFixed(1)},${y1.toFixed(1)} ${x2.toFixed(1)},${y2.toFixed(1)} ${x3.toFixed(1)},${y3.toFixed(1)}`,
      x: (x0 + 3 * x1 + 3 * x2 + x3) / 8,
      y: (y0 + 3 * y1 + 3 * y2 + y3) / 8,
    };
  }

  function applyPositions() {
    for (const [id, item] of nodeEls) {
      const spot = state.positions.get(id);
      if (spot && inLayout(id)) item.setAttribute('transform', `translate(${spot[0].toFixed(1)},${spot[1].toFixed(1)})`);
    }
    for (const e of data.edges) {
      if (!visibleEdge(e)) continue;
      const geometry = route(e.from, e.to);
      if (!geometry) continue;
      const item = edgeEls.get(e.id);
      item.path.setAttribute('d', geometry.d);
      item.label.setAttribute('x', geometry.x.toFixed(1));
      item.label.setAttribute('y', (geometry.y - 5).toFixed(1));
    }
  }

  function moveTo(view, duration) {
    const target = layout(view).nodes;
    const start = new Map();
    for (const id of Object.keys(target)) start.set(id, state.positions.get(id) || target[id]);
    const token = ++state.motion;
    const began = performance.now();
    const tick = (now) => {
      if (token !== state.motion) return;
      const t = duration ? Math.min(1, (now - began) / duration) : 1;
      const e = ease(t);
      for (const [id, from] of start) {
        const to = target[id];
        state.positions.set(id, [from[0] + (to[0] - from[0]) * e, from[1] + (to[1] - from[1]) * e]);
      }
      applyPositions();
      if (t < 1) requestAnimationFrame(tick);
    };
    if (duration) requestAnimationFrame(tick);
    else tick(began);
  }

  function renderFrames() {
    frameLayer.replaceChildren();
    for (const f of layout().frames) {
      const item = svgEl('g', { class: 'frame' }, frameLayer);
      svgEl('rect', { x: f.x, y: f.y, width: f.w, height: f.h, rx: 14, ry: 14 }, item);
      const title = svgEl('text', { x: f.x + 16, y: f.y + 21 }, item);
      title.textContent = f.label;
    }
  }

  function focus() {
    if (state.path && (!state.selected || state.path.nodes.includes(state.selected))) {
      return { kind: 'path', nodes: new Set(state.path.nodes), edges: new Set(state.path.edges) };
    }
    if (state.selected) {
      const members = new Set([state.selected]);
      const lines = new Set();
      for (const e of outgoing.get(state.selected).concat(incoming.get(state.selected))) {
        if (!visibleEdge(e)) continue;
        lines.add(e.id);
        members.add(e.from);
        members.add(e.to);
      }
      return { kind: 'selection', nodes: members, edges: lines };
    }
    if (state.tour) {
      const members = new Set(state.tour.steps[state.at].nodes);
      const lines = new Set(data.edges.filter((e) => members.has(e.from) && members.has(e.to) && visibleEdge(e)).map((e) => e.id));
      return { kind: 'tour', nodes: members, edges: lines };
    }
    if (state.query) {
      return { kind: 'query', nodes: new Set(data.nodes.filter((n) => matches(n, state.query)).map((n) => n.id)), edges: new Set() };
    }
    return null;
  }

  function refresh() {
    const current = focus();
    for (const [id, item] of nodeEls) {
      const lit = Boolean(current) && current.nodes.has(id);
      item.classList.toggle('hidden', !visibleNode(id));
      item.classList.toggle('dim', Boolean(current) && !lit);
      item.classList.toggle('selected', state.selected === id);
      item.classList.toggle('tour', lit && current.kind === 'tour');
      item.classList.toggle('path', lit && current.kind === 'path');
      item.classList.toggle('match', lit && current.kind === 'query');
    }
    for (const e of data.edges) {
      const item = edgeEls.get(e.id);
      const shown = visibleEdge(e);
      const lit = Boolean(current) && current.edges.has(e.id);
      item.path.classList.toggle('hidden', !shown);
      item.path.classList.toggle('dim', Boolean(current) && !lit);
      item.path.classList.toggle('lit', lit);
      item.label.classList.toggle('show', shown && lit);
    }
    applyPositions();
    renderDetail();
    renderTour();
    for (const button of byId('view-list').querySelectorAll('button')) {
      button.setAttribute('aria-pressed', String(button.dataset.view === state.view));
    }
  }

  function select(id) {
    state.selected = id;
    refresh();
  }

  function reveal(id) {
    const n = nodes.get(id);
    if (state.hidden.has(n.group)) {
      state.hidden.delete(n.group);
      syncGroups();
    }
    if (!inLayout(id)) switchView(n.views[0], false);
    state.selected = id;
    refresh();
    focusNodes([id], 1);
  }

  function switchView(id, fit) {
    if (state.tour && state.tour.view !== id) state.tour = null;
    const changed = state.view !== id;
    state.view = id;
    if (state.selected && !inLayout(state.selected)) state.selected = null;
    if (state.path && !state.path.nodes.every((member) => inLayout(member))) {
      state.path = null;
      renderPath();
    }
    if (changed) {
      renderFrames();
      moveTo(id, 480);
    }
    refresh();
    if (fit) fitView(true);
  }

  function setCamera(c) {
    state.camera = c;
    viewport.setAttribute('transform', `translate(${c.x.toFixed(2)},${c.y.toFixed(2)}) scale(${c.k.toFixed(4)})`);
  }

  function frameBox(box, limit) {
    const r = svg.getBoundingClientRect();
    const side = 56;
    const top = 56;
    const bottom = 132;
    const k = Math.max(0.12, Math.min(limit, (r.width - 2 * side) / box.w, (r.height - top - bottom) / box.h));
    return {
      k,
      x: r.width / 2 - (box.x + box.w / 2) * k,
      y: top + (r.height - top - bottom) / 2 - (box.y + box.h / 2) * k,
    };
  }

  function glideTo(target, duration) {
    const from = { ...state.camera };
    const token = ++state.glide;
    const began = performance.now();
    const tick = (now) => {
      if (token !== state.glide) return;
      const t = Math.min(1, (now - began) / duration);
      const e = ease(t);
      setCamera({ x: from.x + (target.x - from.x) * e, y: from.y + (target.y - from.y) * e, k: from.k + (target.k - from.k) * e });
      if (t < 1) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }

  function focusNodes(ids, limit) {
    const spots = ids.map((id) => layout().nodes[id]).filter(Boolean);
    if (!spots.length) return;
    const xs = spots.map((p) => p[0]);
    const ys = spots.map((p) => p[1]);
    const x = Math.min(...xs) - 30;
    const y = Math.min(...ys) - 30;
    glideTo(frameBox({ x, y, w: Math.max(...xs) + W + 30 - x, h: Math.max(...ys) + H + 30 - y }, limit || 1.2), 520);
  }

  function fitView(animate) {
    const size = layout().size;
    const target = frameBox({ x: -20, y: -20, w: size[0] + 40, h: size[1] + 40 }, 1.1);
    if (animate) glideTo(target, 520);
    else setCamera(target);
  }

  function zoomBy(factor, cx, cy) {
    const r = svg.getBoundingClientRect();
    const x = cx === undefined ? r.width / 2 : cx;
    const y = cy === undefined ? r.height / 2 : cy;
    const c = state.camera;
    const k = Math.max(0.12, Math.min(3, c.k * factor));
    state.glide++;
    setCamera({ k, x: x - (x - c.x) * (k / c.k), y: y - (y - c.y) * (k / c.k) });
  }

  function renderDetail() {
    const box = byId('detail');
    box.replaceChildren();
    if (!state.selected) {
      const v = views.get(state.view);
      htmlEl('h2', null, 'View', box);
      htmlEl('h3', null, v.label, box);
      htmlEl('p', 'summary', v.summary, box);
      htmlEl('p', 'note', `${Object.keys(layout().nodes).length} nodes are in this view. Select a node to read its summary and its edges.`, box);
      return;
    }
    const n = nodes.get(state.selected);
    const group = groups.get(n.group);
    htmlEl('h2', null, 'Node', box);
    htmlEl('h3', null, n.label, box);
    const chips = htmlEl('div', 'chips', null, box);
    const groupChip = htmlEl('span', 'chip', null, chips);
    htmlEl('span', 'swatch', null, groupChip).style.background = group.color;
    groupChip.append(`Group: ${group.label}`);
    htmlEl('span', `chip ${n.kind}`, `Kind: ${n.kind}`, chips);
    htmlEl('span', `chip ${n.status}`, `Status: ${n.status}`, chips);
    htmlEl('p', 'summary', n.summary, box);
    htmlEl('h2', null, 'Views', box);
    const list = htmlEl('div', 'view-list', null, box);
    for (const id of n.views) {
      const button = htmlEl('button', null, views.get(id).label, list);
      button.type = 'button';
      button.addEventListener('click', () => {
        switchView(id, false);
        state.selected = n.id;
        refresh();
        focusNodes([n.id], 1);
      });
    }
    linkList(box, 'Edges out', outgoing.get(n.id), (e) => e.to, '→');
    linkList(box, 'Edges in', incoming.get(n.id), (e) => e.from, '←');
  }

  function linkList(box, title, list, other, arrow) {
    htmlEl('h2', null, `${title} (${list.length})`, box);
    if (!list.length) {
      htmlEl('p', 'note', 'None.', box);
      return;
    }
    const items = htmlEl('ul', 'links', null, box);
    for (const e of list) {
      const button = htmlEl('button', null, null, htmlEl('li', null, null, items));
      button.type = 'button';
      htmlEl('span', 'target', `${arrow} ${nodes.get(other(e)).label}`, button);
      htmlEl('span', 'via', `${kinds.get(e.kind).label}: ${e.label}`, button);
      button.addEventListener('click', () => reveal(other(e)));
    }
  }

  function startTour(id) {
    state.tour = id ? tours.get(id) : null;
    state.at = 0;
    state.path = null;
    renderPath();
    if (!state.tour) {
      refresh();
      return;
    }
    for (const entry of state.tour.steps) for (const member of entry.nodes) state.hidden.delete(nodes.get(member).group);
    syncGroups();
    switchView(state.tour.view, false);
    showStop(0);
  }

  function showStop(index) {
    const t = state.tour;
    if (!t) return;
    state.at = Math.max(0, Math.min(t.steps.length - 1, index));
    state.selected = null;
    refresh();
    focusNodes(t.steps[state.at].nodes, 0.8);
  }

  function renderTour() {
    const t = state.tour;
    byId('tour-select').value = t ? t.id : '';
    byId('tour-count').textContent = t ? `${state.at + 1} / ${t.steps.length}` : '';
    byId('tour-text').textContent = t ? t.steps[state.at].text : 'Choose a tour. The arrow keys move through it. Escape clears the selection.';
    byId('tour-prev').disabled = !t || state.at === 0;
    byId('tour-next').disabled = !t || state.at === t.steps.length - 1;
  }

  function shortestPath(from, to) {
    return searchPath(from, to, (e) => e.kind !== 'step') || searchPath(from, to, () => true);
  }

  function searchPath(from, to, usable) {
    if (from === to) return { nodes: [from], edges: [], hops: [] };
    const previous = new Map([[from, null]]);
    const queue = [from];
    while (queue.length) {
      const id = queue.shift();
      if (id === to) break;
      for (const e of outgoing.get(id).concat(incoming.get(id))) {
        if (!usable(e)) continue;
        const next = e.from === id ? e.to : e.from;
        if (!previous.has(next)) {
          previous.set(next, { id, e });
          queue.push(next);
        }
      }
    }
    if (!previous.has(to)) return null;
    const hops = [];
    let current = to;
    while (current !== from) {
      const back = previous.get(current);
      hops.unshift({ from: back.id, to: current, edge: back.e });
      current = back.id;
    }
    return { nodes: [from].concat(hops.map((hop) => hop.to)), edges: hops.map((hop) => hop.edge.id), hops };
  }

  function pickView(found) {
    const order = [state.view].concat(data.views.slice(1).map((v) => v.id), [overview]);
    return order.find((view) => found.nodes.every((id) => inLayout(id, view)) && found.hops.every((hop) => hop.edge.views.includes(view)));
  }

  function runPath() {
    const from = byId('path-from').value;
    const to = byId('path-to').value;
    const note = byId('path-note');
    if (!from || !to) {
      note.textContent = 'Choose a start node and an end node.';
      return;
    }
    const found = shortestPath(from, to);
    if (!found) {
      state.path = null;
      renderPath();
      note.textContent = 'No path connects these nodes.';
      refresh();
      return;
    }
    for (const id of found.nodes) state.hidden.delete(nodes.get(id).group);
    syncGroups();
    state.tour = null;
    state.selected = null;
    state.path = found;
    switchView(pickView(found), false);
    renderPath();
    note.textContent = found.hops.length === 0 ? 'The start and the end are the same node.' : found.hops.length === 1 ? 'One edge connects the nodes.' : `${found.hops.length} edges connect the nodes.`;
    refresh();
    focusNodes(found.nodes, 1.1);
  }

  function renderPath() {
    const list = byId('path-result');
    list.replaceChildren();
    if (!state.path) return;
    for (const hop of state.path.hops) {
      const button = htmlEl('button', 'hop', null, htmlEl('li', null, null, list));
      button.type = 'button';
      const arrow = hop.edge.from === hop.from ? '→' : '←';
      htmlEl('span', 'target', `${nodes.get(hop.from).label} ${arrow} ${nodes.get(hop.to).label}`, button);
      htmlEl('span', 'via', `${kinds.get(hop.edge.kind).label}: ${hop.edge.label}`, button);
      button.addEventListener('click', () => select(hop.to));
    }
  }

  function runSearch() {
    const q = byId('search').value.trim().toLowerCase();
    state.query = q;
    const list = byId('search-results');
    list.replaceChildren();
    if (q) {
      const hits = data.nodes.filter((n) => matches(n, q));
      for (const n of hits.slice(0, 12)) {
        const button = htmlEl('button', null, null, htmlEl('li', null, null, list));
        button.type = 'button';
        htmlEl('span', 'target', n.label, button);
        htmlEl('span', 'via', groups.get(n.group).label, button);
        button.addEventListener('click', () => reveal(n.id));
      }
      if (!hits.length) htmlEl('li', 'note', 'No node matches.', list);
      if (hits.length > 12) htmlEl('li', 'note', `${hits.length - 12} more nodes match.`, list);
    }
    refresh();
  }

  function syncGroups() {
    for (const input of byId('group-list').querySelectorAll('input')) input.checked = !state.hidden.has(input.value);
  }

  function showTip(n, event) {
    tooltip.replaceChildren();
    htmlEl('strong', null, n.label, tooltip);
    htmlEl('span', null, metaText(n), tooltip);
    tooltip.hidden = false;
    placeTip(event);
  }

  function placeTip(event) {
    const r = svg.getBoundingClientRect();
    tooltip.style.left = `${event.clientX - r.left + 14}px`;
    tooltip.style.top = `${event.clientY - r.top + 14}px`;
  }

  function hideTip() {
    tooltip.hidden = true;
  }

  function clearFocus() {
    if (state.selected) state.selected = null;
    else if (state.path) {
      state.path = null;
      renderPath();
      byId('path-note').textContent = '';
    } else if (state.tour) state.tour = null;
    refresh();
  }

  function buildControls() {
    byId('stats').textContent = `${data.nodes.length} nodes · ${data.edges.length} edges · ${data.tours.length} tours · ${data.views.length - 1} views`;
    for (const v of data.views) {
      const button = htmlEl('button', null, v.label, byId('view-list'));
      button.type = 'button';
      button.dataset.view = v.id;
      button.title = v.summary;
      button.addEventListener('click', () => switchView(v.id, true));
    }
    for (const g of data.groups) {
      const count = data.nodes.filter((n) => n.group === g.id).length;
      if (!count) continue;
      const row = htmlEl('label', 'group-row', null, byId('group-list'));
      const input = htmlEl('input', null, null, row);
      input.type = 'checkbox';
      input.checked = true;
      input.value = g.id;
      input.addEventListener('change', () => {
        if (input.checked) state.hidden.delete(g.id);
        else state.hidden.add(g.id);
        if (state.selected && state.hidden.has(nodes.get(state.selected).group)) state.selected = null;
        refresh();
      });
      htmlEl('span', 'swatch', null, row).style.background = g.color;
      htmlEl('span', null, g.label, row);
      htmlEl('span', 'count', String(count), row);
    }
    const legend = byId('legend');
    for (const [text, dash] of [['Solid border: core part', ''], ['Dashed border: option', '7 4'], ['Dotted border: planned, not built', '1.5 4.5']]) {
      const row = htmlEl('div', 'legend-row', null, legend);
      const icon = svgEl('svg', { width: 34, height: 18, viewBox: '0 0 34 18', 'aria-hidden': 'true' }, row);
      const rect = svgEl('rect', { x: 2, y: 2, width: 30, height: 14, rx: 4, fill: 'none', stroke: data.colors.text, 'stroke-width': 1.8, 'stroke-linecap': 'round' }, icon);
      if (dash) rect.setAttribute('stroke-dasharray', dash);
      htmlEl('span', null, text, row);
    }
    for (const k of data.edgeKinds) {
      const row = htmlEl('div', 'legend-row', null, legend);
      const icon = svgEl('svg', { width: 34, height: 18, viewBox: '0 0 34 18', 'aria-hidden': 'true' }, row);
      const line = svgEl('line', { x1: 2, y1: 9, x2: 32, y2: 9, stroke: k.color, 'stroke-width': 2 }, icon);
      if (k.dash) line.setAttribute('stroke-dasharray', k.dash);
      htmlEl('span', null, `Edge: ${k.label}`, row);
    }
    const tourSelect = byId('tour-select');
    htmlEl('option', null, 'Choose a tour', tourSelect).value = '';
    for (const t of data.tours) htmlEl('option', null, `${t.label} (${t.steps.length})`, tourSelect).value = t.id;
    tourSelect.addEventListener('change', () => startTour(tourSelect.value));
    byId('tour-prev').addEventListener('click', () => showStop(state.at - 1));
    byId('tour-next').addEventListener('click', () => showStop(state.at + 1));
    const sorted = data.nodes.slice().sort((a, b) => a.label.localeCompare(b.label, 'en') || a.id.localeCompare(b.id, 'en'));
    for (const [id, text] of [['path-from', 'Start node'], ['path-to', 'End node']]) {
      const choice = byId(id);
      htmlEl('option', null, text, choice).value = '';
      for (const n of sorted) htmlEl('option', null, n.label, choice).value = n.id;
    }
    byId('path-find').addEventListener('click', runPath);
    byId('path-clear').addEventListener('click', () => {
      state.path = null;
      renderPath();
      byId('path-note').textContent = '';
      refresh();
    });
    const search = byId('search');
    search.addEventListener('input', runSearch);
    search.addEventListener('keydown', (event) => {
      if (event.key !== 'Enter') return;
      const first = data.nodes.find((n) => state.query && matches(n, state.query));
      if (first) reveal(first.id);
    });
    byId('zoom-in').addEventListener('click', () => zoomBy(1.25));
    byId('zoom-out').addEventListener('click', () => zoomBy(0.8));
    byId('zoom-fit').addEventListener('click', () => fitView(true));
  }

  svg.addEventListener('pointerdown', (event) => {
    if (event.button !== 0) return;
    drag.active = true;
    drag.moved = false;
    drag.x = event.clientX;
    drag.y = event.clientY;
    drag.camera = { ...state.camera };
  });
  window.addEventListener('pointermove', (event) => {
    if (!drag.active) return;
    const dx = event.clientX - drag.x;
    const dy = event.clientY - drag.y;
    if (!drag.moved && Math.abs(dx) + Math.abs(dy) < 4) return;
    drag.moved = true;
    state.glide++;
    setCamera({ x: drag.camera.x + dx, y: drag.camera.y + dy, k: drag.camera.k });
  });
  window.addEventListener('pointerup', () => {
    drag.active = false;
  });
  svg.addEventListener('click', () => {
    if (drag.moved || !state.selected) return;
    state.selected = null;
    refresh();
  });
  svg.addEventListener('wheel', (event) => {
    event.preventDefault();
    const r = svg.getBoundingClientRect();
    zoomBy(Math.exp(-event.deltaY * 0.0015), event.clientX - r.left, event.clientY - r.top);
  }, { passive: false });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      clearFocus();
      return;
    }
    const tag = event.target?.tagName;
    if (tag === 'INPUT' || tag === 'SELECT' || tag === 'TEXTAREA') return;
    const forward = event.key === 'ArrowRight' || event.key === 'ArrowDown';
    const back = event.key === 'ArrowLeft' || event.key === 'ArrowUp';
    if (!forward && !back) return;
    event.preventDefault();
    if (!state.tour) {
      const t = data.tours.find((candidate) => candidate.view === state.view);
      if (t && forward) startTour(t.id);
      return;
    }
    showStop(state.at + (forward ? 1 : -1));
  });

  buildControls();
  renderFrames();
  moveTo(state.view, 0);
  refresh();
  fitView(false);
})();
"""


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
