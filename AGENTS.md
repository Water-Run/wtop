# Documentation style

User-facing docs (`README.md`, `README-zh.md`) are written for people, not for
agents. Keep them that way when editing:

- Write for the current version only. No changelogs, release attestations, or
  "since vX.Y" history. Git history is the log. The 0.1.0 release and the
  LuaRocks package are Linux-only; macOS and Windows trees are development
  builds, not a shipped release.
- Say what a user needs and stop. Cut edge-case enumeration, exhaustive
  parameter semantics, and implementation internals. If a detail only matters
  when something breaks, it doesn't belong in the README.
- Plain sentences a person would say. No spec-legalese walls, no nested
  qualifiers, no "every X is Y; Z may differ when..." hedging chains.
- Calm, factual tone. Prefer "doesn't" / "不会" over "never" / "绝不". Soften a
  behavioral absolute with "by design" / "设计上". Describe what the program
  does; don't preach absolutes.
- Use GitHub Markdown deliberately: tables for reference data, `<details>`
  for long lists, blockquote notes for caveats. The area under the title
  carries only the language switch link — no badge or nav-link rows. Keep
  `README.md` and `README-zh.md` structurally in sync.
- Machine-only instructions live here, not in the user docs.
