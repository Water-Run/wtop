# UI and Interaction

> This document reflects current `0.1.0-dev` behavior. Items labeled “future” or “goal” are not delivered features.

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
┌ wtop  [Overview]  Processes  Compute  Storage & I/O  Network  GPU   Refresh: Medium
│ responsive widget tree for the active tab
│ …
└ 1–8 tabs   Space pause   f refresh   e layout   ? help   q quit
```

The frame has only three layers:

1. One top row shows the brand, every tab that fits, and a clickable “Refresh” control. A PAUSED state is appended while paused, and an elevated invocation is visibly marked. Narrow screens retain the current tab and refresh control first, hiding distant tabs with `‹`/`›` indicators.
2. The center contains the active tab's layout tree.
3. One bottom row shows contextual shortcuts, process search/sort state, persistence errors, and short messages.

There is currently one overlay, with no overlay stack, toast center, or command palette.

## 3. Eight Fixed Tabs

| Number / ID | Current content | Current limitations |
| --- | --- | --- |
| `1` `overview` | CPU, memory, PSI, disk, network, GPU, CPU frequency, maximum hwmon temperature, and CPU power summary | Not a clickable resource drill-down page |
| `2` `processes` | Process table, text search, fixed sort cycle, PPID tree, selected-item detail, and confirmed `SIGTERM` | No thread rows, column configuration, PSS/USS, namespace, or combined filters |
| `3` `compute` | CPU identity/heterogeneous core types/topology/cache, aggregate/per-core CPU, load, memory summary, CPUFreq policies, powercap zones, and general hwmon table | No NUMA distance, frequency residency, or full vendor firmware inventory |
| `4` `storage` | Block-device rate/latency estimates, mountinfo/statvfs capacity, and SMART entry | Network/autofs/FUSE/fuseblk/virtiofs skip statvfs by default; other calls share a 50 ms admission budget but individual calls cannot be preempted |
| `5` `network` | Interface rate/link summary and TCP/TCP6/UDP/UDP6/Unix socket table | No route/address detail, connection filters, or endpoint-masking switch |
| `6` `gpu` | DRM device, PCI vendor/model/link metadata, driver/busy/VRAM, hwmon temperature/power, frequency, and fdinfo-mapped processes, engines, utilization, and memory | No client/frequency-domain/memory-region drill-down or vendor API; unmatched sensors remain `—` |
| `7` `workloads` | cgroup v2 path-tree summaries for CPU, memory, I/O, process count, PSI, and quality | No expand/collapse, selected-item detail, systemd-unit, or container semantics |
| `8` `insights` | Collector availability, process/GPU counts from background snapshots, and SMART/RAM-bandwidth/sshd entry summary | Does not foreground-sample process/GPU at 1 Hz for counts; `Enter` opens only the sshd Inspector; no automatic inference |

Tabs cannot currently be added, removed, renamed, or reordered.

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

When both children do not fit on a split's original axis, the solver tries the other axis. If they still do not fit, it retains the focused/higher-priority side and hides the other. Hidden widgets remain in the layout tree and reappear as the window grows. Flow compares the richness of forms retained by candidate column counts, preventing unconditional single/multi-column jumps at adjacent sizes solely because of a mode threshold. Panel minimum sizes include borders. Tables first assign minimum widths to every visible essential column, then share remaining space. The footer reports responsive hiding as `visible/total`.

The TUI solves actual placements first, then passes the visible-widget set to the scheduler and ViewModel. Hidden high-cardinality tables do not build row models. A collector unneeded by any placement uses its background interval rather than continuing at the active tab's foreground interval. Shared collectors may remain foreground for another visible component: for example, a GPU summary can continue device updates, but `/proc/<pid>/fdinfo` is scanned only when `gpu_process_table` is actually visible. The single Insights summary widget does not promote process or GPU collection to 1 Hz foreground sampling.

### 5.1 High-Cardinality Table Limits

- The process collector enumerates at most 8192 PIDs by default. The process page searches/sorts the collected set, the ViewModel retains at most 2048 rows, and collection-limit and display truncation are reported separately.
- Connection, mount, workload, and GPU-process tables each build at most 512 rows. Connections, mounts, and GPU processes use bounded priority sets; workloads use the first 512 rows in collector order. Connection status shows the collector's total socket count and GPU-process status shows visible/total. Mount and workload tables currently have no separate ViewModel-cap truncation indicator.
- A missing table row is not proof that the object does not exist. Collectors that hit their scan budget use `partial`/`truncated`; a ViewModel-only row limit does not fabricate collector quality. This is especially important for mount/workload tables, which currently lack a visible display-cap indicator.

## 6. Key Bindings

### 6.1 Global

| Key | Current behavior |
| --- | --- |
| `1`–`8` | Select one of the eight tabs directly |
| `←` / `→` | Cycle to the previous/next tab; move widgets in layout edit mode |
| `Tab` / `Shift+Tab` | Move widget focus forward/backward |
| `Space` | Pause/resume collector scheduling |
| `f` | Cycle through nine refresh rates |
| `e` | Enter/leave layout edit mode |
| `r` / `Ctrl+L` | Make collectors required by actual placements immediately due, and force one complete renderer redraw |
| `?` / `F1` | Open the help overlay |
| `s` | Open the SMART/NVMe device selector |
| `b` | Run the RAM-bandwidth Inspector |
| `d` | Run the sshd Inspector |
| `q` | Quit the main UI; close the current overlay/SMART selector |
| `Ctrl+C` | Always quit from the main UI, search, confirmation, or any overlay |

### 6.2 Processes Page

| Key | Current behavior |
| --- | --- |
| `↑` / `↓` | Move process selection |
| `/` | Edit a case-insensitive substring search over PID, name, command, user, and state |
| `Enter` / `Esc` | Confirm/cancel active search editing; `Esc` clears an already confirmed search |
| `o` | Cycle CPU descending → memory descending → PID ascending → name ascending → I/O read descending → I/O write descending |
| `t` | Toggle the PPID tree; search retains ancestors of direct matches |
| `Enter` | Open the selected-process detail overlay when not editing search |
| `k` | Create a `SIGTERM` confirmation for the selected process; only `y` executes it, while any other key cancels |

I/O and cgroup details are collected on demand only for the selected process, so I/O sorting is not equivalent to continuous `iotop`-style sampling of every process.

### 6.3 Overlays and Mouse

- Ordinary overlay: scroll with `↑`/`↓`, `PgUp`/`PgDn`, `Home`/`End`, or the wheel; close with `Esc`, `Enter`, `q`, `?`, or `F1`.
- SMART selector: the same navigation keys change devices; `Enter` inspects, and `Esc`/`q` closes.
- Mouse: click visible top tabs and the top-right refresh control; wheel-scroll the process table and overlays/SMART selector. Row clicking, split dragging, and widget drag-and-drop are unsupported.

`h j k l`, `:`, `Ctrl+K`, a command palette, global search, and key rebinding are not implemented.

## 7. Data Representation and Accessibility

- Metric widgets use timestamped history and one-line block sparklines. Each column always represents one second and aggregates samples in that interval, up to 240 seconds. ASCII is used when Unicode is unavailable. There is currently no Braille, zoomable time axis, legend, or multi-series interaction.
- Nonnumeric samples are gap points, never zero-filled. Collectors stop periodic sampling while paused, and the header shows PAUSED.
- The renderer measures terminal cells rather than Lua byte length, including CJK, combining characters, emoji, and variation selectors. Differences in terminal `wcwidth` tables can still cause isolated alignment errors.
- `NO_COLOR` and `--no-color` are supported. There is no `--no-animation`, RTL mirroring, pseudolocale, or stable-language screenshot regression matrix yet.

## 8. Current Validation and Future Acceptance

`make test` currently runs 41 Lua unit/fixture test files and real PTY cases at `40×10`, `60×20`, `80×24/25`, `80×50`, `160×24`, `200×22`, and `180×45`. It checks Chinese rendering, the canonical Lua-blue default, real mouse clicks on the top-right refresh control, tab/process/help/pause/refresh/layout paths, alternate-screen restoration, layout schema v2 writes, and mode `0600`. The final large case pauses reads to fill the PTY output queue and confirms that the entire bottom row is delivered, preventing a partial frame from being mistaken for success. The responsive solver and layout tree also have pure-Lua unit/randomized invariant tests. Additional PTY profiles assert truecolor, 256-color, 16-color, and colorless ASCII output and cover Water Light, High Contrast, and Colorblind themes. Processes, Compute, Storage, Network, GPU, Workloads, and Insights each remain as the final frame of an individual `180×45` case, with cell-by-cell complete-render checks and page-specific titles, so a later clear screen cannot hide an intermediate stale frame.

Release evidence is still missing for continuous resize, tmux/SSH, more extreme dimensions, screenshots for each stable language, pseudolocale/RTL, broad terminal compatibility, layout recovery after crashes, and unified resource navigation on detail pages.
