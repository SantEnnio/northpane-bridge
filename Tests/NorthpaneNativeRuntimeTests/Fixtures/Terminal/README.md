# Terminal recordings

Recorded through Northpane's own PTY, at 80 columns by 24 rows, using an empty
temporary home and a generated `example.txt` containing 100 numbered Unicode
lines. The shell uses `PS1=probe$ `. No user configuration or credentials were
loaded. The `-exit` files contain the subsequent output after closing the UI.

- `shell`: `/bin/sh -i`, initial prompt.
- `vim`: `vim -Nu NONE -n -i NONE example.txt`, then `:q!`.
- `less`: `less -R example.txt`, then `q`.

The tests compare visible cells, attributes, cursor and modes before and after
replay, then feed the exit recording to both terminals. These are replay tests,
not full application certifications. Agent UI and htop recordings are still
required before the native runtime can be enabled.
