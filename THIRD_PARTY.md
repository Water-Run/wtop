# Third-Party Components

wtop itself is EUPL-1.2. These are the components that ship with it or build
it; the repository carries no other third-party runtime code.

| Component | Version | License | Role |
| --- | --- | --- | --- |
| [PUC Lua](https://www.lua.org/) | 5.5.1 | MIT © 1994–2026 Lua.org, PUC-Rio | The runtime. Bundled with the onedir/onefile and platform development bundles |
| [luainstaller](https://luarocks.org/modules/) | 1.3.0 | LGPL-3.0-or-later | Build-time packaging tool for the onedir/onefile bundles; not present in the produced executables |

Throughout this file, a path in `backticks` is one the release actually
contains. A path in quotes is being talked about, not shipped.

The Lua license text ships inside the onedir bundle at
`.luai/licenses/Lua-MIT.txt`, placed there by the packaging tool. This file
previously said the text travelled "as part of the Lua source distribution
under lua-src/doc/", which was not true of any release: no bundle has ever
contained a lua-src directory, and the sentence had never been checked against
one. It is the same defect this file's neighbours had — a statement about the
artifacts that no artifact agreed with. The luainstaller payload is locked by
hash in `tools/luainstaller-1.3.0.sha256` and runs only during packaging.

## What a release actually carries

`make bundle-dir` copies this project's own `LICENSE` into `dist/wtop/`, so the
onedir bundle carries the EUPL-1.2 text beside the program it governs. The
`make sbom` document records, for every licence it declares, the file holding
that text, that file's SHA-256, and which artifact forms contain it — and it
refuses to write the document at all if a declared text is missing.

The **onefile does not carry the EUPL-1.2 text.** The packaging tool has no
supported way to add a non-Lua file to it, and the SBOM says so in
`wtop:licence-text:present-in` rather than leaving a redistributor to find out.
Anyone redistributing the onefile has to carry this project's terms forward
themselves. The Lua, LGPL and GPL texts do travel inside the onefile's own
bytes, so that one is covered by the executable's hash.

The notices are inside the `SHA256SUMS` manifest, and CI publishes them beside
the SBOM. `make test-release-notices` checks all of that.
