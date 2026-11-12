# LumaWall benchmarks

Microbenchmarks for the hot paths changed by the performance pass. They run
without launching the app or touching the person's wallpaper.

```sh
Tools/Benchmarks/run.sh before   # writes results/before-*.json
# make changes
Tools/Benchmarks/run.sh after    # writes results/after-*.json
Tools/Benchmarks/compare.py before after
```

Each run writes three files:

- `<label>-core.json` — occlusion math, library disk usage, energy-log write,
  accessibility/theme reads, window-server list, IOKit power read, variant
  existence checks.
- `<label>-poster.json` — cold 4K poster load and the first draw that forces
  the JPEG decode, plus the decoded pixel dimensions.
- `<label>-bmp.json` — 4K BMP snapshot encode time, byte count, and a checksum
  that must match before and after (byte-identical output).

`swiftc` compiles the poster and BMP benchmarks against the real source files,
so they also act as a standalone compile check for `PosterCache.swift`,
`Brand.swift`, and `BMPEncoding.swift`.

Treat the numbers as medians on this machine, not product guarantees. The
library and energy-log cases are intentionally synthetic (600 files, 1440
samples) so runs are short and repeatable.
