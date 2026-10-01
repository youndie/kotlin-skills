#!/usr/bin/env python3
"""Check that what this repository ships is what an install will get.

Every rule here was a sentence in the README or in somebody's notes before it was a check, and each
was broken while it was only a sentence:

* **A change to a plugin raises its version.** `claude plugin update` compares version strings and
  nothing else, so a merged change under an unchanged version never reaches an install. Six pull
  requests in a row once shipped under 0.6.0; two days after that was written down, a fix for a
  memory leak merged under 0.7.0 and stayed out of every install, including its author's.
  Files under `evals/` are exempt: nothing at runtime reads them.
* **A SKILL.md stays under its line budget** (`MAX_SKILL_LINES`). The body is paid in tokens every
  time the skill fires; past the budget, detail moves to `references/` or `examples/`.
* **A description fits the platform's limit** (`MAX_DESCRIPTION_CHARS`), and the frontmatter name is
  the directory's name. The description is paid in every session whether the skill fires or not.
* **Relative links resolve**, anchors included. Moving a section into `references/` is the usual
  way a budget is met, and the usual way a pointer is left dangling.
* **`evals/evals.json` parses.**

`--base <ref>` turns on the version rule against that ref (a pull request's base branch, or the
commit before a push). `--selftest` builds small trees that must fail each rule and one that must
pass, and fails if any of them does not: a check that cannot be shown to fire is not a check.

Standard library only, so CI needs nothing but a Python.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

MAX_SKILL_LINES = 400
MAX_DESCRIPTION_CHARS = 1024
EXEMPT_FROM_VERSION = re.compile(r"(^|/)evals/")

FENCE = re.compile(r"^\s*(```|~~~)")
LINK = re.compile(r"\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
INLINE_CODE = re.compile(r"`+[^`]*`+")


def frontmatter(text: str) -> dict[str, str]:
    """The `key: value` pairs between the leading `---` lines; quoted and folded values unwrapped."""
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return {}
    out: dict[str, str] = {}
    key = None
    for line in lines[1:]:
        if line.strip() == "---":
            break
        m = re.match(r"^([A-Za-z_][\w-]*):\s*(.*)$", line)
        if m:
            key, value = m.group(1), m.group(2).strip()
            if value in (">", "|", ">-", "|-"):
                value = ""
            elif len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1].replace('\\"', '"')
            out[key] = value
        elif key and line.startswith((" ", "\t")):
            out[key] = (out[key] + " " + line.strip()).strip()
    return out


def slug(heading: str) -> str:
    """GitHub's anchor for a heading: link text kept, lower case, punctuation dropped, spaces to hyphens."""
    heading = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", heading)
    return re.sub(r"[^\w\- ]", "", heading.strip().lower()).replace(" ", "-")


def anchors(path: Path) -> set[str]:
    """Every anchor GitHub would give the file's headings, ATX and setext, with `-1`, `-2` for repeats."""
    out, seen, fenced, previous = set(), {}, False, ""
    for line in path.read_text().split("\n"):
        if FENCE.match(line):
            fenced, previous = not fenced, ""
            continue
        if fenced:
            continue
        m = re.match(r"^#{1,6}\s+(.*?)\s*#*\s*$", line)
        text = m.group(1) if m else (previous if previous.strip() and re.match(r"^(=+|-+)\s*$", line) else None)
        if text is not None:
            base = slug(text)
            n = seen.get(base, 0)
            out.add(base if n == 0 else f"{base}-{n}")
            seen[base] = n + 1
        previous = line
    return out


def links(path: Path) -> list[str]:
    out, fenced = [], False
    for line in path.read_text().split("\n"):
        if FENCE.match(line):
            fenced = not fenced
            continue
        if not fenced:
            out += LINK.findall(INLINE_CODE.sub("", line))
    return out


def check_links(md: Path) -> list[str]:
    errors = []
    for target in links(md):
        if re.match(r"^[a-z]+:", target) or target.startswith("/"):
            continue
        file_part, _, anchor = target.partition("#")
        resolved = (md.parent / file_part) if file_part else md
        if not resolved.exists():
            errors.append(f"{md}: link to a missing file: {target}")
        elif anchor and resolved.suffix == ".md" and anchor not in anchors(resolved):
            errors.append(f"{md}: link to a missing heading: {target}")
    return errors


def check_skill(skill_dir: Path) -> list[str]:
    errors = []
    skill = skill_dir / "SKILL.md"
    if not skill.exists():
        return [f"{skill_dir}: no SKILL.md"]
    text = skill.read_text()
    fm = frontmatter(text)
    if fm.get("name") != skill_dir.name:
        errors.append(f"{skill}: frontmatter name {fm.get('name')!r} is not the directory's {skill_dir.name!r}")
    description = fm.get("description", "")
    if not description:
        errors.append(f"{skill}: no description")
    elif len(description) > MAX_DESCRIPTION_CHARS:
        errors.append(f"{skill}: description is {len(description)} characters, the limit is {MAX_DESCRIPTION_CHARS}")
    lines = text.count("\n") + (0 if text.endswith("\n") else 1)
    if lines > MAX_SKILL_LINES:
        errors.append(f"{skill}: {lines} lines, the budget is {MAX_SKILL_LINES}; move detail into references/ or examples/")
    for md in sorted(skill_dir.rglob("*.md")):
        if "evals" in md.relative_to(skill_dir).parts:
            continue
        errors += check_links(md)
    evals = skill_dir / "evals" / "evals.json"
    if evals.exists():
        try:
            json.loads(evals.read_text())
        except json.JSONDecodeError as e:
            errors.append(f"{evals}: not JSON: {e}")
    return errors


def version_tuple(v: str) -> tuple[int, ...]:
    if not re.fullmatch(r"\d+(\.\d+)*", v):
        raise ValueError(f"not a dotted version: {v!r}")
    return tuple(int(x) for x in v.split("."))


def git(root: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], cwd=root, capture_output=True, text=True)


def check_version(root: Path, plugin_dir: Path, base: str) -> list[str]:
    rel = plugin_dir.relative_to(root).as_posix()
    manifest = f"{rel}/.claude-plugin/plugin.json"
    # --no-renames: a shipped file moved into evals/ is a deletion from what ships, and needs a bump.
    diff = git(root, "diff", "--no-renames", "--name-only", f"{base}...HEAD", "--", rel)
    if diff.returncode != 0:
        return [f"cannot diff against {base}: {diff.stderr.strip()}"]
    shipped = [f for f in diff.stdout.split() if not EXEMPT_FROM_VERSION.search(f[len(rel) + 1:])]
    if not shipped:
        return []
    before = git(root, "show", f"{base}:{manifest}")
    if before.returncode != 0:
        return []  # a plugin the base does not have yet: its first version is whatever it says
    old = json.loads(before.stdout)["version"]
    new = json.loads((root / manifest).read_text())["version"]
    try:
        if version_tuple(new) > version_tuple(old):
            return []
    except ValueError as e:
        return [f"{manifest}: {e}"]
    return [
        f"{manifest}: version {new} is not above {old} on {base}, but {len(shipped)} shipped file(s) changed "
        f"(first: {shipped[0]}); `claude plugin update` would not see this change"
    ]


def check(root: Path, base: str | None) -> list[str]:
    errors = []
    marketplace = root / ".claude-plugin" / "marketplace.json"
    if not marketplace.exists():
        return [f"{marketplace}: missing"]
    plugins = json.loads(marketplace.read_text()).get("plugins", [])
    if not plugins:
        errors.append(f"{marketplace}: lists no plugins")
    for entry in plugins:
        if not isinstance(entry.get("source"), str):
            continue  # a plugin fetched from elsewhere is checked in its own repository
        plugin_dir = (root / entry["source"]).resolve()
        manifest = plugin_dir / ".claude-plugin" / "plugin.json"
        if not manifest.exists():
            errors.append(f"{entry['name']}: no {manifest}")
            continue
        if json.loads(manifest.read_text()).get("name") != entry["name"]:
            errors.append(f"{manifest}: name differs from the marketplace entry {entry['name']!r}")
        skills = sorted(p for p in (plugin_dir / "skills").iterdir() if p.is_dir())
        if not skills:
            errors.append(f"{plugin_dir}: ships no skills")
        for skill_dir in skills:
            errors += check_skill(skill_dir)
        if base:
            errors += check_version(root.resolve(), plugin_dir, base)
    return errors


# --- self-test: every rule is shown firing on a tree built to trip it -------------------------------

def _tree(root: Path, *, lines: int = 10, name: str = "demo", description: str = "Does a thing.",
          link: str = "references/more.md#a-heading", evals: str | None = None) -> None:
    (root / ".claude-plugin").mkdir(parents=True, exist_ok=True)
    (root / ".claude-plugin" / "marketplace.json").write_text(json.dumps(
        {"name": "m", "plugins": [{"name": "p", "source": "./plugins/p"}]}))
    plugin = root / "plugins" / "p"
    (plugin / ".claude-plugin").mkdir(parents=True, exist_ok=True)
    (plugin / ".claude-plugin" / "plugin.json").write_text(json.dumps({"name": "p", "version": "1.0.0"}))
    skill = plugin / "skills" / "demo"
    (skill / "references").mkdir(parents=True, exist_ok=True)
    body = f"---\nname: {name}\ndescription: \"{description}\"\n---\n\nSee [more]({link}).\n"
    body += "x\n" * max(0, lines - body.count("\n"))
    (skill / "SKILL.md").write_text(body)
    (skill / "references" / "more.md").write_text(
        "# More\n\n## A heading\n\n## A heading\n\nUnder a line\n------------\n\nSee `[x](nowhere.md)`.\n")
    if evals is not None:
        (skill / "evals").mkdir(exist_ok=True)
        (skill / "evals" / "evals.json").write_text(evals)


def _git_init(root: Path) -> None:
    for args in (["init", "-q", "-b", "main"], ["add", "-A"],
                 ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base"]):
        git(root, *args)


def selftest() -> int:
    cases = {
        "a clean tree passes": (dict(), None, False),
        "a SKILL.md over budget fails": (dict(lines=MAX_SKILL_LINES + 1), None, True),
        "a SKILL.md exactly at budget passes": (dict(lines=MAX_SKILL_LINES), None, False),
        "a name that is not the directory fails": (dict(name="other"), None, True),
        "an over-long description fails": (dict(description="d" * (MAX_DESCRIPTION_CHARS + 1)), None, True),
        "a link to a missing file fails": (dict(link="references/gone.md"), None, True),
        "a link to a missing heading fails": (dict(link="references/more.md#nope"), None, True),
        "broken evals.json fails": (dict(evals="{"), None, True),
        "a link with a title resolves": (dict(link='references/more.md#a-heading "title"'), None, False),
        "a missing file behind a title fails": (dict(link='references/gone.md "title"'), None, True),
        "a repeated heading's second anchor resolves": (dict(link="references/more.md#a-heading-1"), None, False),
        "a setext heading resolves": (dict(link="references/more.md#under-a-line"), None, False),
    }
    failures = []
    for title, (kwargs, _, should_fail) in cases.items():
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            _tree(root, **kwargs)
            errors = check(root, None)
            if bool(errors) != should_fail:
                failures.append(f"{title}: got {errors or 'no errors'}")

    # the version rule, against a real base commit
    def version_case(change: str, bump: str | None) -> list[str]:
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            _tree(root)
            skill = root / "plugins" / "p" / "skills" / "demo"
            if change == "MOVE":  # a shipped file nothing links to, so only the move is under test
                (skill / "references" / "extra.md").write_text("# Extra\n")
            _git_init(root)
            if change == "MOVE":
                (skill / "evals").mkdir(exist_ok=True)
                (skill / "references" / "extra.md").rename(skill / "evals" / "extra.md")
            else:
                target = root / "plugins" / "p" / change
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(target.read_text() + "\nchanged\n" if target.exists() else "new\n")
            if bump:
                (root / "plugins" / "p" / ".claude-plugin" / "plugin.json").write_text(
                    json.dumps({"name": "p", "version": bump}))
            git(root, "add", "-A")
            git(root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "change")
            return check(root, "HEAD~1")

    for title, change, bump, should_fail in [
        ("a skill change without a bump fails", "skills/demo/SKILL.md", None, True),
        ("a reference change without a bump fails", "skills/demo/references/more.md", None, True),
        ("a skill change with a bump passes", "skills/demo/SKILL.md", "1.0.1", False),
        ("a bump that goes down fails", "skills/demo/SKILL.md", "0.9.9", True),
        ("an evals-only change needs no bump", "skills/demo/evals/README.md", None, False),
        ("a shipped file moved into evals/ needs a bump", "MOVE", None, True),
    ]:
        errors = version_case(change, bump)
        if bool(errors) != should_fail:
            failures.append(f"{title}: got {errors or 'no errors'}")

    for f in failures:
        print(f"SELFTEST FAILED: {f}", file=sys.stderr)
    total = len(cases) + 6
    print(f"selftest: {total - len(failures)}/{total} cases behave")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--base", help="ref to compare plugin versions against (enables the version rule)")
    parser.add_argument("--selftest", action="store_true", help="prove every rule fires, then exit")
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    root = Path(__file__).resolve().parent.parent
    errors = check(root, args.base)
    for e in errors:
        print(e.replace(f"{root}/", ""), file=sys.stderr)
    print(f"{'FAILED' if errors else 'ok'}: {len(errors)} problem(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
