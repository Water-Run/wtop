# Git workflow

- Keep `main` as the only local and remote branch. Commit and push work directly to `main`.
- Do not create pull requests or development branches unless the user explicitly requests them.

# Documentation style

The user-facing doc is a single plain-text `README.txt`: English first,
Chinese below, one file. It is written for people, not for agents. Keep it
that way when editing:

- Write for the current version only. No changelogs, release attestations, or
  "since vX.Y" history. Git history is the log. The released version and the
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
- It is plain text, not Markdown: no tables, `<details>` or badge rows. Keep
  the English and Chinese halves structurally in sync; English is the source,
  the Chinese follows it. Lead with the product's positioning — compatibility
  with old devices, especially the classic Windows CMD console.
- Lead with compatibility: Linux, macOS and Windows (32-bit, XP target),
  old hardware and consoles without ANSI. State honestly which platforms
  are released (Linux) and which are development builds, and don't
  call XP or classic-CMD support tested until a real run exists.
- Test evidence, validation matrices and dated host results belong in
  `docs/CROSS_PLATFORM.md` or release notes, not in the README.
- Machine-only instructions live here, not in the user docs.
