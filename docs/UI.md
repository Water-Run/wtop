# UI and Interaction

> This document reflects current `0.1.0` behavior. Items labeled “future” or “goal” are not delivered features.

## 1. Current Visual Baseline

wtop's visual language is called **Waterline**: compact monospace typography, semantic color, short sparklines, and limited borders. Five themes are built in—Lua Blue, Water Dark, Water Light, High Contrast, and Colorblind—with fallback to truecolor, 256-color, 16-color, or colorless modes. Lua Blue is the default and anchors its background to the official Lua logo blue, `#000080`, while using lighter related accents for legibility.

Widgets use semantic tokens and never make color the sole status signal. Data quality is also represented by `+`, `!`, `~`, `×`, `-`, or `·`.

| Token | Lua Blue | Purpose |
| --- | --- | --- |
| `surface.base` | `#000080` | Main background and space between panels |
| `surface.raised` | `#070743` | Panels and overlays |
| `surface.header` | `#0B1252` | Header hierarchy |
| `surface.row_alt` | `#090948` | Low-contrast alternating table rows |
| `surface.selected` | `#173C99` | Selected table row |
| `text.primary` | `#F3F6FF` | Primary text |
| `text.muted` | `#ABB7D8` | Secondary labels and unavailable values |
| `accent.primary` | `#80AFFF` | Focus, active tabs, and selected content |
| `metric.good` | `#4CD8B1` | fresh/ok |
| `metric.warn` | `#FFD166` | stale/estimated/confirmation state |
| `metric.critical` | `#FF6B88` | denied/error |

Focus strengthens only a panel's border and title instead of tinting the whole panel. Active tabs use a low-luminance background with accent foreground rather than a high-contrast inverse block. Headers, alternating rows, and selected rows use three independent surfaces, avoiding large black/blue stripes while retaining redundant bold, border, and textual cues in 256/16-color modes.

## 2. Global Frame

```text
┌ wtop ubuntu-jp  [Overview]  Processes  Compute  Memory  Storage & I/O  › Update rate: High
│ responsive widget tree for the active tab
│ …
└ 1–0 Tabs · Space Pause · f Update rate · e Layout · T Theme · ? Help · q Quit   ▦ 8/11 · 10:33:35
```

The frame has only three layers:

1. One top row shows the brand with the host name, every tab that fits, and a clickable update-rate control. A PAUSED state is appended while paused, an alert count appears when a collector is denied or a resource crosses its critical threshold, and an elevated invocation is visibly marked. Narrow screens retain the current tab and rate control first, hiding distant tabs with `‹`/`›` indicators; the host name is the first thing to yield.
2. The center contains the active tab's layout tree.
3. One bottom row shows contextual shortcuts — each of which is clickable — plus responsive hiding as `visible/total`, the active search filter, persistence errors, short messages, and a clock.

There is currently one overlay at a time, with no overlay stack, toast center,
or command palette. The overlay dims the page behind it, wraps long lines, and
shows a scrollbar and a `shown/total` counter when its content does not fit.

## 3. Ten Fixed Tabs

| Number / ID | Current content | Current limitations |
| --- | --- | --- |
| `1` `overview` | CPU, memory, per-core bars, host identity (hostname, OS, kernel, uptime, load, virtualization), PSI, disk, network, GPU, CPU frequency, maximum hwmon temperature, and CPU power | Not a clickable resource drill-down page |
| `2` `processes` | Process table with PID, user name, PRI/NI, virtual and resident memory, state, CPU, TIME+, thread count and full command; text search, eleven sort columns in both directions, PPID tree, full-path toggle, selected-item detail, and a confirmed signal menu | No thread rows, user-configurable column set, PSS/USS, namespace, or combined filters |
| `3` `compute` | CPU identity/heterogeneous core types/topology/cache as an aligned key/value list, aggregate CPU, a per-core bar array, per-core table, load and kernel-wide counters, CPUFreq policies, powercap zones, and the hwmon table | No NUMA distance, frequency residency, or full vendor firmware inventory |
| `4` `memory` | Utilization with history, a stacked composition bar (used/shared/buffers/cache/free), full meminfo detail with per-field share, swap totals and devices, memory PSI, and paging/fault counters | No per-process PSS/USS attribution or NUMA node breakdown |
| `5` `storage` | Block-device rate/latency/queue with model, size, medium and scheduler; mountinfo/statvfs capacity with inode usage; I/O pressure; SMART entry | Network/autofs/FUSE/fuseblk/virtiofs skip statvfs by default; other calls share a 50 ms admission budget but individual calls cannot be preempted |
| `6` `network` | Interface rate/link/MTU/MAC/error summary, IPv4 and IPv6 addresses with netmask and default-route marking, and the TCP/TCP6/UDP/UDP6/Unix socket table | No route table detail, connection filters, or endpoint-masking switch |
| `7` `gpu` | DRM device, PCI vendor/model/link metadata, driver/busy/VRAM, hwmon temperature/power, frequency, and fdinfo-mapped processes, engines, utilization, and memory | No client/frequency-domain/memory-region drill-down or vendor API; unmatched sensors remain `—` |
| `8` `workloads` | cgroup v2 path-tree summaries for CPU, memory, I/O, process count, PSI, and quality, plus a detail panel that explains why nodes are partial | No expand/collapse, selected-item detail, systemd-unit, or container semantics |
| `9` `system` | Host name/domain/architecture/time zone, distribution, kernel release and build, boot time and busy-since-boot, virtualization and container detection, SELinux/AppArmor/lockdown, DMI machine/board/firmware, descriptor and PID/thread limits, entropy, kernel-wide counters, and power supplies | DMI is frequently root-only; serial numbers, asset tags and the product UUID are deliberately never read, and secret or machine-identifying kernel parameters are redacted |
| `0` `insights` | Per-collector availability, status, quality, source and reason; deep-inspector readiness with its key binding; and actionable findings for denied or absent sources | Does not foreground-sample process/GPU at 1 Hz for counts; no automatic inference |

Tabs cannot currently be added, removed, renamed, or reordered. `1`–`9` select
the first nine; `0` selects the tenth, following the familiar browser ordering.

### 3.1 Widget Vocabulary

| Kind | Used for |
| --- | --- |
| `metric` | A scalar with history. Renders a value, a gauge, and — when the panel is at least three rows tall — a multi-row column chart with min/max axis labels. Colour encodes severity against configurable thresholds; the leading symbol independently encodes data quality. |
| `table` | Rows with per-column priority, per-cell colour, and optional in-cell proportional bars. Reports the columns it had to drop and the geometry it drew, which is what the event loop uses for hit-testing and scrolling. |
| `key_value` | Label/value pairs with section headings, aligned by measured display width. Scrolls while focused and announces the remainder it could not fit. |
| `bars` | A labelled bar array: per-core CPU, power supplies. Spends panel height before width so bars stay long. |
| `segments` | One stacked bar plus a legend for a quantity that partitions exactly, such as memory composition. |
| `text` | Plain preformatted blocks. Retained for fixed content only; anything tabular should use `key_value`. |

## 4. Layout Tree and Schema v2

Primary configuration at `$XDG_CONFIG_HOME/wtop/config.yml` uses configuration schema v1. The separate `$XDG_CONFIG_HOME/wtop/layout.yml` is written as layout schema v2 in the current release. Do not conflate the two `schema_version` values.

```yaml
schema_version: 2
pages:
  gpu:
    type: split
    axis: horizontal
    ratio_micros: 666667
    gap: 1
    children:
      - type: split
        axis: vertical
        ratio_micros: 500000
        gap: 1
        children:
          - type: leaf
            widget_id: "gpu_summary"
          - type: leaf
            widget_id: "gpu_table"
      - type: leaf
        widget_id: "gpu_process_table"
```

Schema v2 rules:

- A node is either a `leaf` or binary `split`; `split.children` must contain exactly two entries.
- `axis` is either `horizontal` or `vertical`.
- `ratio_micros` is an integer from `1..999999`; `gap` is an integer from `0..16`.
- Maximum depth is 32, maximum node count 511, and maximum file size 1 MiB.
- Each page accepts only its fixed widget IDs; duplicate widgets and unknown pages/keys are rejected.
- New default widgets missing from a saved page are appended. A wholly missing page uses its default tree.
- The reader still accepts the schema v1 ordered widget list. A layout is atomically rewritten as v2 with mode `0600` only after the user edits it and the event loop exits cleanly through `q`, `Ctrl+C`, or a captured exit signal.

The current editor operates only on existing leaves:

- `Tab`/`Shift+Tab` selects a widget.
- Arrow keys move the focused leaf before/after its neighbor in the current leaf order and rebuild the corresponding split according to direction; this does not search for the geometrically closest on-screen widget.
- `[`/`]` adjusts the nearest parent split of the focused leaf in steps of 0.05, constrained interactively to 0.10..0.90.
- `u`/`U` undo/redo up to 50 in-memory steps per page. Nothing is persisted until the event loop exits; a crash or `SIGKILL` loses edits from the current session.

Adding/removing/replacing widgets, independent split tools, dragging, named layouts, import/export, cross-page moves, and post-crash recovery are not implemented.

## 5. Responsive Modes

Layout uses `(columns, rows)`, widget minimum sizes, priority, and focus:

| Condition | Mode | Current behavior |
| --- | --- | --- |
| columns `>=120` and rows `<30` | `wide-short` | Up to four columns; low, ultrawide terminals prefer this mode instead of incorrectly collapsing to tiny |
| not wide-short, and columns `<70`, rows `<=12`, or `<=80×<=24` | `tiny` | Switch axes/reflow by minimum size; hide by focus and priority only if space is still insufficient |
| columns `<120` (and not tiny) | `narrow-tall` | Prefer a single vertical column |
| columns `>=180` and rows `>=45` | `wide-tall` | Up to three columns, preferring full forms |
| otherwise | `standard` | Up to two columns, preferring full forms |

A split first checks whether both children fit on its authored axis. It then
checks something stronger: whether each child reaches the size at which it
renders its *full* form. When the authored axis satisfies the minimum but not
the full form, and the other axis would satisfy more children, the split
reflows. This is what stops a 120-column terminal from cutting four tables down
to three visible columns each merely because the mode's nominal column count is
four; the column count is driven by what the content needs, and the mode now
only sets an upper bound. If neither axis fits, the solver retains the
focused/higher-priority side and hides the other. Hidden widgets remain in the layout tree and reappear as the window grows. Flow compares the richness of forms retained by candidate column counts, preventing unconditional single/multi-column jumps at adjacent sizes solely because of a mode threshold. Panel minimum sizes include borders. Tables first assign minimum widths to every visible essential column, then share remaining space. The footer reports responsive hiding as `visible/total`.

The TUI solves actual placements first, then passes the visible-widget set to the scheduler and ViewModel. Hidden high-cardinality tables do not build row models. A collector unneeded by any placement uses its background interval rather than continuing at the active tab's foreground interval. Shared collectors may remain foreground for another visible component: for example, a GPU summary can continue device updates, but `/proc/<pid>/fdinfo` is scanned only when `gpu_process_table` is actually visible. The single Insights summary widget does not promote process or GPU collection to 1 Hz foreground sampling.

### 5.1 High-Cardinality Table Limits

- The process collector enumerates at most 8192 PIDs by default. The process page searches/sorts the collected set, the ViewModel retains at most 2048 rows, and collection-limit and display truncation are reported separately.
- Connection, mount, workload, and GPU-process tables each build at most 512 rows. Connections, mounts, and GPU processes use bounded priority sets; workloads use the first 512 rows in collector order. Connection status shows the collector's total socket count and GPU-process status shows visible/total. Mount and workload tables currently have no separate ViewModel-cap truncation indicator.
- A missing table row is not proof that the object does not exist. Collectors that hit their scan budget use `partial`/`truncated`; a ViewModel-only row limit does not fabricate collector quality. This is especially important for mount/workload tables, which currently lack a visible display-cap indicator.

## 6. Key Bindings

### 6.1 Global

| Key | Current behavior |
| --- | --- |
| `1`–`9`, `0` | Select one of the ten tabs directly (`0` is the tenth) |
| `←` / `→` | Cycle to the previous/next tab; move widgets in layout edit mode |
| `Tab` / `Shift+Tab` | Move widget focus forward/backward across **visible** widgets only |
| `↑` / `↓` / `PgUp` / `PgDn` | Scroll the focused panel when its content exceeds its rectangle |
| `Space` | Pause/resume collector scheduling |
| `f` | Cycle through nine refresh rates |
| `T` | Cycle the colour theme at runtime |
| `L` | Cycle the interface language at runtime |
| `v` | Show/hide virtual block devices and pseudo filesystems |
| `e` | Enter/leave layout edit mode (`Esc` also leaves) |
| `r` / `Ctrl+L` | Make collectors required by actual placements immediately due, and force one complete renderer redraw |
| `?` / `F1` | Open the help overlay |
| `s` | Open the SMART/NVMe device selector |
| `b` | Run the RAM-bandwidth Inspector |
| `d` | Run the sshd Inspector |
| `q` | Quit the main UI; close the current overlay/selector |
| `Ctrl+C` | Always quit from the main UI, search, signal menu, or any overlay |

### 6.2 Processes Page

| Key | Current behavior |
| --- | --- |
| `↑` / `↓` | Move process selection |
| `PgUp` / `PgDn` | Move selection one visible page |
| `Home` / `End` | Jump to the first or last row |
| `/` | Edit a case-insensitive search over PID, name, command, user, and state |
| `←` `→` `Home` `End` | Move the cursor inside the query while editing |
| `Ctrl+W` / `Ctrl+U` / `Ctrl+K` | Delete the previous word / to the start / to the end |
| `Enter` / `Esc` | Confirm/cancel active search editing; `Esc` clears an already confirmed search |
| `o` | Cycle the sort column: CPU, memory, PID, name, CPU time, threads, virtual memory, state, user, I/O read, I/O write |
| `O` | Reverse the current sort direction |
| `t` | Toggle the PPID tree; search retains ancestors of direct matches |
| `p` | Toggle full executable paths against bare command names |
| `Enter` | Open the selected-process detail overlay when not editing search |
| `k` | Open the signal menu for the selected process: `SIGTERM`, `SIGKILL`, `SIGSTOP`, `SIGCONT`. `Enter` sends, any other key cancels |

### 6.2.1 Search Syntax

Whitespace separates terms and every term must match, so adding a word can only
narrow the result.

| Term | Meaning |
| --- | --- |
| `root` | Substring, matched against PID, name, command, user and state |
| `user:root` | Restrict the term to one field: `pid`, `ppid`, `user`, `state`, `name`, `cmd` |
| `!kernel` | Negate the term |
| `/^systemd%-/` | A **Lua pattern**, not a PCRE regular expression: `%` escapes, not `\` |
| `user:root state:D` | Several terms, all of which must match |

At most sixteen terms are honoured. A malformed pattern is demoted to a literal
substring rather than raised, so a half-typed expression narrows the table
instead of interrupting the render loop. Matching literal substrings are
highlighted in the PID, user and command columns; negated and pattern terms are
not highlighted because they have no single literal to point at.

Process names come from `/proc/<pid>/cmdline`, so they are not limited to the
fifteen characters the kernel keeps in `comm`. `/proc/<pid>/io` counters are
cumulative since exec and are labelled as totals, not rates, because the
collector samples them on demand rather than continuously.

The signal menu re-verifies the target's start time while holding a pidfd, so a
recycled PID is never signalled.

### 6.3 Overlays and Mouse

- Ordinary overlay: scroll with `↑`/`↓`, `PgUp`/`PgDn`, `Home`/`End`, or the
  wheel; close with `Esc`, `Enter`, `q`, `?`, or `F1`. The page behind an
  overlay is dimmed, long lines wrap to the overlay width, and a scrollbar plus
  a `shown/total` counter appear whenever the content does not fit.
- SMART selector: the same navigation keys change devices; `Enter` inspects,
  and `Esc`/`q` closes.
- Mouse: click visible top tabs, the top-right refresh control, any footer
  shortcut, a process table row to select it, or a process column header to
  sort by it (clicking the active column reverses it). The wheel scrolls the
  process viewport three rows at a time and scrolls focused panels and
  overlays. Split dragging and widget drag-and-drop are unsupported.

`h j k l`, `:`, `Ctrl+K`, a command palette, global search, and key rebinding
are not implemented.

## 7. Data Representation and Accessibility

- Metric widgets use timestamped history. A panel of three rows or more renders a multi-row block column chart with min/max axis labels; shorter panels keep the familiar one-line sparkline. Each column always represents one second and aggregates samples in that interval, up to 240 seconds. Chart and sparkline share one bucketing routine, so the two always agree column for column. ASCII is used when Unicode is unavailable. There is currently no Braille, zoomable time axis, legend, or multi-series interaction.
- Colour and symbol carry two independent signals. Colour encodes severity against per-metric thresholds (and inverted thresholds for quantities where low is bad, such as battery charge); the leading symbol encodes data quality. A metric whose series holds no finite sample at all says so in words instead of drawing an axis over an empty plot.
- Every label/value alignment is computed from measured display width. Nothing pads by byte length, and no translated string carries its own column layout.
- Nonnumeric samples are gap points, never zero-filled. Collectors stop periodic sampling while paused, and the header shows PAUSED.
- The renderer measures terminal cells rather than Lua byte length, including CJK, combining characters, emoji, and variation selectors. Differences in terminal `wcwidth` tables can still cause isolated alignment errors.
- `NO_COLOR` and `--no-color` are supported. There is no `--no-animation`, RTL mirroring, pseudolocale, or stable-language screenshot regression matrix yet.

## 8. Current Validation and Future Acceptance

`make test` runs 47 Lua unit/fixture test files and real PTY cases at `40×10`,
`60×20`, `80×24/25`, `80×50`, `160×24`, `200×22`, and `180×45`. It checks
Chinese rendering, the canonical Lua-blue default, real mouse clicks on the
top-right refresh control, tab/process/help/pause/refresh/layout paths,
alternate-screen restoration, layout schema v2 writes, and mode `0600`. The
interactive case drives more than thirty bindings in one session: layout edit
and undo/redo, a live resize, search entry and cancellation, sort cycling and
reversal, the tree and full-path toggles, keyboard paging and Home/End, the
detail overlay, the signal menu opened and cancelled, the theme cycle, the
virtual-device toggle, and the help overlay. Each scripted input declares the
markers that must already be on screen before it is sent, so the script can be
reordered without the harness waiting on an overlay that was never opened.

Every one of the ten pages is asserted as the final frame of an individual
`180×45` case, with cell-by-cell complete-render checks and page-specific
titles, so a later clear screen cannot hide an intermediate stale frame. The
final large case pauses reads to fill the PTY output queue and confirms that
the entire bottom row is delivered. Additional PTY profiles assert truecolor,
256-color, 16-color, and colorless ASCII output and cover Water Light, High
Contrast, and Colorblind themes. The responsive solver, layout tree, chart,
key/value, bar and segment widgets, table column policy, the process query
grammar, and the system and power-supply collectors all have pure-Lua unit
tests; the same suite also runs under Lua 5.4.

One test is deliberately not hermetic. `test_live_consistency.lua` cross-checks
the assembled collector view against procfs on the machine running the tests:
the memory figures and the stacked composition against `/proc/meminfo`, the
block-device set against `/proc/diskstats`, the interface set and its monotonic
counters against `/proc/net/dev`, and uptime, hostname, boot time and descriptor
usage against their own files. Fixtures prove the parsers; this proves the
assembled view still corresponds to the kernel's numbers. It reads only procfs,
needs no external command and no native module, and skips whatever a given
kernel does not expose rather than failing.

`make test-all` additionally builds both luainstaller artifact forms and runs
the whole PTY matrix against the onedir and onefile executables, plus an
isolated LuaRocks installation whose CLI output is checked against the snapshot
and agent JSON contracts.

All ten shipped catalogs now translate every message, and the i18n test asserts
`missing_messages == 0` for each of them, so a UI string added without a
translation fails the build rather than reaching a user as English mid-sentence.
The fallback chain is still covered, against a deliberately partial catalog
constructed in the test.

Release evidence is still missing for continuous resize, tmux/SSH, more extreme
dimensions, screenshots for each stable language, pseudolocale/RTL, broad
terminal compatibility, layout recovery after crashes, and unified resource
navigation on detail pages.
