#!/usr/bin/env python3
"""Validate Super-C skill references and report skills affected by source changes."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SKILLS = ROOT / "skills"

SOURCE_PATH_RE = re.compile(r"(?<![A-Za-z0-9_./-])((?:src|std|ffi|tests)/[A-Za-z0-9_./-]+)(?::\d+)?")
LINK_RE = re.compile(r"\[[^]]+\]\(([^)]+)\)")
FLAG_RE = re.compile(r"(?<![A-Za-z0-9_])--[a-z][a-z0-9-]*")
ENV_RE = re.compile(r"\bSC_[A-Z0-9_]+\b")
ATTRIBUTE_RE = re.compile(r"(?<![A-Za-z0-9_])@[a-z][a-z0-9_.]*(?:\([^\n)]*\))?")
EXTERNAL_FLAGS = {"--rate"}

SKILL_BY_PREFIX = {
    "src/build_system/": "super-c-binary",
    "src/main.spc": "super-c-binary",
    "src/lsp/": "super-c-binary",
    "src/driver/": "super-c-compiler-internals",
    "src/ast/": "super-c-compiler-internals",
    "src/hir/": "super-c-compiler-internals",
    "src/ir/": "super-c-compiler-internals",
    "src/emit/": "super-c-compiler-internals",
    "src/borrowck/": "super-c-compiler-internals",
    "src/typechecker/": "super-c-language",
    "std/parallel/": "super-c-concurrency",
    "std/": "super-c-language",
    "ffi/": "super-c-ffi",
    "tests/": "super-c-testing",
    "skills/": "super-c-skill-maintenance",
}


def git(*args: str) -> str:
    result = subprocess.run(
        ["git", *args], cwd=ROOT, text=True, capture_output=True, check=False
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "git command failed")
    return result.stdout.strip()


def markdown_files() -> list[Path]:
    return sorted(SKILLS.rglob("*.md"))


def source_text() -> str:
    paths = [ROOT / "src", ROOT / "std", ROOT / "ffi", ROOT / "tests", ROOT / "bench", ROOT / "ci"]
    return "\n".join(
        path.read_text(encoding="utf-8")
        for root in paths
        if root.exists()
        for pattern in ("*.spc", "*.sh")
        for path in sorted(root.rglob(pattern))
    )


def check_links(errors: list[str]) -> None:
    for doc in markdown_files():
        text = doc.read_text(encoding="utf-8")
        for target in LINK_RE.findall(text):
            if target.startswith(("http://", "https://", "#")):
                continue
            target_path = target.split("#", 1)[0]
            resolved = (doc.parent / target_path).resolve()
            if not resolved.exists():
                errors.append(f"{doc.relative_to(ROOT)}: missing link target {target}")


def check_source_references(errors: list[str]) -> None:
    for doc in markdown_files():
        text = doc.read_text(encoding="utf-8")
        for match in SOURCE_PATH_RE.finditer(text):
            line_start = text.rfind("\n", 0, match.start()) + 1
            line_end = text.find("\n", match.end())
            line = text[line_start:line_end if line_end >= 0 else len(text)]
            context = text[max(0, match.start() - 48):match.start()].lower()
            if (line.lstrip().startswith("//") or "no `" in context or "no " in context
                    or "example" in line.lower() or "default" in line.lower()):
                continue
            if match.group(1).endswith("/X.spc"):
                continue
            path = ROOT / match.group(1)
            if not path.exists():
                errors.append(f"{doc.relative_to(ROOT)}: missing source path {match.group(1)}")


def check_claims(errors: list[str]) -> None:
    binary = (SKILLS / "super-c-binary/SKILL.md").read_text(encoding="utf-8")
    source = source_text()
    main_source = (ROOT / "src/main.spc").read_text(encoding="utf-8")

    for flag in sorted(set(FLAG_RE.findall(binary))):
        if flag not in main_source and flag not in EXTERNAL_FLAGS:
            errors.append(f"super-c-binary: documented flag is absent from src/main.spc: {flag}")

    documented_env = set(ENV_RE.findall(binary))
    source_env = set(ENV_RE.findall(source))
    for name in sorted(documented_env - source_env):
        errors.append(f"super-c-binary: documented environment variable is absent from source: {name}")

    language = (SKILLS / "super-c-language/SKILL.md").read_text(encoding="utf-8")
    documented_attributes = {
        match.split("(", 1)[0]
        for match in ATTRIBUTE_RE.findall(language)
        if match.startswith("@")
    }
    source_attributes = {
        match.split("(", 1)[0]
        for match in ATTRIBUTE_RE.findall(source)
        if match.startswith("@")
    }
    for attribute in sorted(documented_attributes):
        if attribute in source_attributes or attribute[1:] in source:
            continue
        errors.append(f"super-c-language: documented attribute is absent from source: {attribute}")

    internals = (SKILLS / "super-c-compiler-internals/SKILL.md").read_text(encoding="utf-8")
    required_symbols = ("run_package_i", "platform_filter", "hir::lower_module", "cemit_package")
    for symbol in required_symbols:
        if symbol not in source and symbol not in internals:
            errors.append(f"super-c-compiler-internals: missing pipeline symbol: {symbol}")


def check_tag(errors: list[str], expected_tag: str | None) -> None:
    policy = (SKILLS / "README.md").read_text(encoding="utf-8")
    match = re.search(r"Verified against git tag: `([^`]+)`", policy)
    if match is None:
        errors.append("skills/README.md: missing verified git tag")
        return
    declared = match.group(1)
    tag = expected_tag or declared
    tags = set(git("tag", "--list", tag).splitlines())
    if tag not in tags:
        errors.append(f"skills/README.md: git tag does not exist: {tag}")
    if expected_tag is not None and declared != expected_tag:
        errors.append(f"skills/README.md: declared tag is {declared}, expected {expected_tag}")


def changed_files() -> list[str]:
    output = git("diff", "--name-only", "HEAD")
    staged = git("diff", "--cached", "--name-only")
    untracked = git("ls-files", "--others", "--exclude-standard")
    return sorted(set(filter(None, output.splitlines() + staged.splitlines() + untracked.splitlines())))


def report() -> None:
    files = changed_files()
    affected: dict[str, list[str]] = {}
    for path in files:
        skill = next(
            (name for prefix, name in SKILL_BY_PREFIX.items() if path.startswith(prefix)),
            "super-c-skill-maintenance",
        )
        affected.setdefault(skill, []).append(path)
    if not affected:
        print("No changed files require a stale-skill review.")
        return
    print("Skills that need review after the current diff:\n")
    reasons = {
        "super-c-binary": "Review CLI flags, environment variables, manifest behavior, and LSP capabilities.",
        "super-c-compiler-internals": "Review pipeline order, IR records, freeze rules, and emitted output invariants.",
        "super-c-language": "Review syntax, type rules, ownership, standard-library contracts, and attributes.",
        "super-c-testing": "Review test discovery, fixture lifecycle, isolation, and leak behavior.",
        "super-c-ffi": "Review extern syntax, C symbols, headers, ownership, and link behavior.",
        "super-c-concurrency": "Review scheduler, synchronization, Send/Sync, and shutdown behavior.",
        "super-c-skill-maintenance": "Review documentation links, source references, and the declared verification tag.",
    }
    for skill in sorted(affected):
        print(f"- {skill}")
        for path in affected[skill]:
            print(f"  - {path}")
        print(f"  {reasons.get(skill, 'Review claims covered by this skill.')}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", help="require this documentation verification tag")
    parser.add_argument("--report", action="store_true", help="report skills affected by the git diff")
    args = parser.parse_args()

    errors: list[str] = []
    check_links(errors)
    check_source_references(errors)
    check_claims(errors)
    check_tag(errors, args.tag)
    if args.report:
        report()
    if errors:
        print("Skill validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("Skill validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
