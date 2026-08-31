# Super-C skill policy

The skills in this directory are the operational documentation for the Super-C
compiler and language.

Verified against git tag: `v0.14.1`

## Precedence

1. The current user request.
2. `AGENTS.md` for repository-wide rules.
3. The skill selected for the task.
4. References linked by that skill.
5. Current source code when documentation and code disagree.

Report a disagreement. Do not add a workaround to make stale documentation appear
correct.

## Skill layout

- `SKILL.md` contains routing, hard constraints, and the agent checklist.
- `references/` contains focused procedures and domain detail.
- `scripts/` contains deterministic validation or analysis tools.

Read only the selected skill and the references needed for the task. The compiler
source is authoritative for volatile details such as flags, environment variables,
pipeline order, and file paths.

## Update policy

Use git tags instead of dates for documentation baselines. Update the verification tag
after a release tag changes the documented behavior. Do not record untagged commits as
verification baselines.

Keep stable contracts separate from current implementation details. Replace exact
counts and historical dates with commands or source references that produce current
values.

Every change to compiler, language, build, standard-library, or tooling behavior must
end with a stale-skill review. The review must name the affected skill, section, stale
claim, and corrected claim. If no skill is stale, say so.

## Validation

Run the skill validator from the repository root:

```sh
python3 skills/scripts/validate_skills.py
```

Use `--report` to map changed source files to skills that require review. Use
`--tag TAG` to validate the declared documentation baseline.

The validator checks local links, source references, documented CLI flags,
environment variables, attributes, pipeline symbols, and the declared git tag. It
does not replace code review.

## Agent checklist

- Read `AGENTS.md` and the selected skill before changing code.
- Read only the linked references required by the task.
- Treat source as authoritative when a volatile claim differs.
- Preserve the self-hosting fixpoint for compiler changes.
- Run the focused validation required by the selected skill.
- Review the diff for stale skills before handoff.
