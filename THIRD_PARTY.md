# Third-Party Components

wtop itself is EUPL-1.2. These are the components that ship with it or build
it; the repository carries no other third-party runtime code.

| Component | Version | License | Role |
| --- | --- | --- | --- |
| [PUC Lua](https://www.lua.org/) | 5.5.1 | MIT © 1994–2026 Lua.org, PUC-Rio | The runtime. Bundled with the onedir/onefile and platform development bundles |
| [NVIDIA NVML interface declarations](https://github.com/NVIDIA/go-nvml) | 13.4.92 | NVIDIA NVML header license | Runtime API declarations and SDK test excerpts; the NVIDIA implementation is loaded from the host |
| [AMD SMI public interface declarations](https://github.com/ROCm/amdsmi) | ROCm 5.7.1–7.2.4 | MIT © Advanced Micro Devices, Inc. | Complete versioned ABI declarations; the vendor library is loaded from the host |
| [Level Zero Sysman interface declarations](https://github.com/oneapi-src/level-zero) | 1.5.0–1.34.0 | MIT © 2019–2026 Intel Corporation | Complete ABI layouts and SDK test declarations; the implementation is loaded in the isolated reader |
| [luainstaller](https://github.com/Water-Run/luainstaller/releases/tag/v1.5.0) | 1.5.0 | LGPL-3.0-or-later | Packaging tool; generated launchers and license notices ship in the onedir/onefile bundles |

Throughout this file, a path in `backticks` is one the release actually
contains. A path in quotes is being talked about, not shipped.

The Level Zero interface notice is embedded in the Linux native module and
reader, and ships at `.luai/licenses/Level-Zero-MIT.txt` in the onedir bundle.
The Intel runtime itself is not bundled.

The Lua license text ships inside the onedir bundle at
`.luai/licenses/Lua-MIT.txt`, placed there by the packaging tool. This file
previously said the text travelled "as part of the Lua source distribution
under lua-src/doc/", which was not true of any release: no bundle has ever
contained a lua-src directory, and the sentence had never been checked against
one. It is the same defect this file's neighbours had — a statement about the
artifacts that no artifact agreed with. The luainstaller payload is locked by
hash in `tools/luainstaller-1.5.0.sha256` and runs only during packaging.

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

The AMD interface notice ships at `.luai/licenses/AMD-SMI-MIT.txt` in the Linux
onedir bundle and inside the native module in both Linux bundle forms. The
AMD SMI implementation is not bundled. Its public declarations and the fake
SDK test excerpts retain AMD's MIT notice in the source tree.

The NVML interface notice ships in the Linux native module and at
`.luai/licenses/NVML-NVIDIA.txt` in the onedir bundle. NVIDIA's implementation
is not bundled. The disclaimer and U.S. Government notice also follow here.

<details>
<summary>NVIDIA NVML header notice</summary>

Copyright 1993-2026 NVIDIA Corporation.  All rights reserved.

NOTICE TO USER:

This source code is subject to NVIDIA ownership rights under U.S. and
international Copyright laws.  Users and possessors of this source code
are hereby granted a nonexclusive, royalty-free license to use this code
in individual and commercial software.

NVIDIA MAKES NO REPRESENTATION ABOUT THE SUITABILITY OF THIS SOURCE
CODE FOR ANY PURPOSE.  IT IS PROVIDED "AS IS" WITHOUT EXPRESS OR
IMPLIED WARRANTY OF ANY KIND.  NVIDIA DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOURCE CODE, INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY, NONINFRINGEMENT, AND FITNESS FOR A PARTICULAR PURPOSE.
IN NO EVENT SHALL NVIDIA BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL,
OR CONSEQUENTIAL DAMAGES, OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
OF USE, DATA OR PROFITS,  WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE
OR OTHER TORTIOUS ACTION,  ARISING OUT OF OR IN CONNECTION WITH THE USE
OR PERFORMANCE OF THIS SOURCE CODE.

U.S. Government End Users.   This source code is a "commercial item" as
that term is defined at  48 C.F.R. 2.101 (OCT 1995), consisting  of
"commercial computer  software"  and "commercial computer software
documentation" as such terms are  used in 48 C.F.R. 12.212 (SEPT 1995)
and is provided to the U.S. Government only as a commercial end item.
Consistent with 48 C.F.R.12.212 and 48 C.F.R. 227.7202-1 through
227.7202-4 (JUNE 1995), all U.S. Government End Users acquire the
source code with only those rights set forth herein.

Any use of this source code in individual and commercial software must
include, in the user documentation and internal comments to the code,
the above Disclaimer and U.S. Government End Users Notice.

</details>
