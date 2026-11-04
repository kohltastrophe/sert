"""sert: the Roblox and Luau test toolkit's command line (stdlib only, Python 3.11+).

VERSION is the single source of sert's own release version: `sert pack` names the assets after it, and the tag a
release workflow creates must be `v<VERSION>`.
"""

VERSION = "0.1.1"
__version__ = VERSION

# The luau and luau-lsp versions sert is developed and tested against: `sert init` pins them in a new sert.toml, and
# they must equal sert's own [tools] (sert.toml) and rokit.toml pins (a unittest checks that).
LUAU = "0.724"
LUAU_LSP = "1.70.0"
