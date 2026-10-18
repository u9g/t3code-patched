# Build ledger

The publish job commits one `<tag>.json` here per published release, and the release's tag
points at that commit. Each record names the upstream commit, the commit of every patch
branch that was applied, the resulting patched source commit, and the run that built it.
