## What and why



## Checklist

- [ ] Every new or changed test was shown **failing first** against the unfixed code, and the red and green numbers are in the commit message.
- [ ] lwext4 changes are numbered patches under `patches/lwext4/` with a README row; `make check-patches` is green.
- [ ] The shipping core reads no environment (`scripts/check_ship_surface.sh` is green).
- [ ] Docs touched where a fact changed (`docs/ENVELOPE.md` for policy or limits, `CHANGELOG.md` under *Unreleased*).
- [ ] Mounted-path changes: how they were exercised, and against which build id (`Ext4Mac version`), is described above — CI cannot run them.
