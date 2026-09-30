# lwext4, as open_ext4_for_mac carries it

This directory is a fork of [lwext4](https://github.com/gkostka/lwext4), not
upstream's lwext4. Bugs in it are this project's to fix, here.

- **Base.** Upstream commit `58bcf89a121b72d4fb66334f1693d3b30e4cb9c5`
  (2022-09-22, `lwext4-0.8.0-659-g58bcf89`). The commit tagged
  `lwext4-upstream-58bcf89a` in this repository holds upstream's tree exactly.
- **Changes.** [docs/lwext4-changes.md](../../docs/lwext4-changes.md) has one
  row per change and the rules for making one; `make lwext4-diff` summarises
  the difference from upstream.
- **Licences.** Upstream's [LICENSE](LICENSE) is kept verbatim. Every file keeps
  its own header: 47 files are BSD-3-Clause, and `src/ext4_extent.c` and
  `src/ext4_xattr.c` are GPL-2.0-or-later. Both are compatible with this
  project's GPL-3.0-or-later. A binary distribution must carry the BSD
  copyright notices and disclaimer.
- **Taking a fix from upstream or another fork.** Fetch it
  (`git fetch https://github.com/gkostka/lwext4 pull/N/head:refs/lwext4-pr/N`),
  apply its diff against the base with
  `git diff 58bcf89a refs/lwext4-pr/N | git apply -3 --directory=Core/lwext4`,
  review it like any other change, and commit it as the next `lwext4 NNNN:`
  with a ledger row and an `Upstream-PR:` trailer.
