# Icon sources

| file            | source                                                        | licence      |
| --------------- | ------------------------------------------------------------- | ------------ |
| claudecode.svg  | lobehub/lobe-icons (`@lobehub/icons-static-svg`)               | MIT          |
| codex.svg       | lobehub/lobe-icons (`@lobehub/icons-static-svg`)               | MIT          |
| grok.svg        | selfhst/icons                                                  | CC-BY-4.0    |
| terminal.svg    | homarr-labs/dashboard-icons                                    | Apache-2.0   |

The asset licences are permissive, but the marks themselves belong to Anthropic,
OpenAI and xAI. Fine for identifying what a pane is running; not a licence to
put them on anything that looks like a product of theirs.

`solid.svg` is generated, not downloaded — see `Resources-src/make-solid-icon.py`.
It takes the `s.` monogram from solidmon's own wordmark script (same JetBrains
Mono Bold outlines, same `-0.04em` tracking, same `#D71500` accent) and sets it
on the tile from `docs/brand/logo.png`.

## Ghostty resources

`Sources/zmxterm/Resources/ghostty/themes` and `Resources/terminfo` are copied
from [Ghostty](https://github.com/ghostty-org/ghostty) (MIT). The colour schemes
originate from [iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes)
(MIT).

They are shipped so that a `theme =` line resolves, and so `xterm-ghostty`
exists, on a machine with no Ghostty installed. An installed Ghostty is always
preferred — its copies will be newer than ours.
