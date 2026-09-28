# Third-Party Components

wtop itself is EUPL-1.2. These are the components that ship with it or build
it; the repository carries no other third-party runtime code.

| Component | Version | License | Role |
| --- | --- | --- | --- |
| [PUC Lua](https://www.lua.org/) | 5.5.1 | MIT © 1994–2026 Lua.org, PUC-Rio | The runtime. Bundled with the onedir/onefile and platform development bundles |
| [luainstaller](https://luarocks.org/modules/) | 1.3.0 | LGPL-3.0-or-later | Build-time packaging tool for the onedir/onefile bundles; not present in the produced executables |

The Lua license text ships inside every bundle as part of the Lua source
distribution under `lua-src/doc/`. The luainstaller payload is locked by hash
in `tools/luainstaller-1.3.0.sha256` and runs only during packaging.
