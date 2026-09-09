# Live Pi footer: Codex credential-store indicator

Captured 2026-09-09 on the installed Pi 0.84.4, in tmux at 200 columns, from the
worktree under test, with `--no-session` so no session file was written.
Account emails visible in the pre-existing quota widget are redacted here; the
indicator itself never renders them.

Full pane captures: `pi-footer-personal.txt`, `pi-footer-geris.txt`.

## Personal store (default agent directory, `~/.pi/agent`)

```sh
pi --no-session -e .pi/extensions/fm-codex-account.ts
```

```text
 cl personal                   5h ●○○○○○○○  10%  (4h 29m)                │ 7d ●●○○○○○○  20%  (14.6%/d) (Mon 19:59)
 cl geris                      5h ●●○○○○○○  26%  (4h 29m)                │ 7d ●○○○○○○○  17%  (13.6%/d) (Tue 10:59)
 cx <redacted-account-email>   5h --                                     │ 7d ●○○○○○○○  12%  (15.1%/d) (Tue 04:07)
 cx <redacted-account-email>   5h ●●●○○○○○  39%  (4h 39m)                │ 7d ●○○○○○○○  11%  (14.7%/d) (Tue 09:55)
~/.no-mistakes/worktrees/cf62ac6bfd91/01M22CXN69KHH8ECW387N9AHVF (detached)
$0.000 (sub) 0.0%/272k (auto)                                    (openai-codex) gpt-5.5 • medium
codex@.pi
```

## Geris store (`PI_CODING_AGENT_DIR=/home/daan/.pi-geris/agent`)

```sh
PI_CODING_AGENT_DIR=/home/daan/.pi-geris/agent pi --no-session -e .pi/extensions/fm-codex-account.ts
```

```text
 cl personal                   5h ●○○○○○○○  10%  (4h 29m)                │ 7d ●●○○○○○○  20%  (14.6%/d) (Mon 19:59)
 cl geris                      5h ●●○○○○○○  26%  (4h 29m)                │ 7d ●○○○○○○○  17%  (13.6%/d) (Tue 10:59)
 cx <redacted-account-email>   5h --                                     │ 7d ●○○○○○○○  12%  (15.1%/d) (Tue 04:07)
 cx <redacted-account-email>   5h ●●●○○○○○  39%  (4h 38m)                │ 7d ●○○○○○○○  11%  (14.7%/d) (Tue 09:55)
~/.no-mistakes/worktrees/cf62ac6bfd91/01M22CXN69KHH8ECW387N9AHVF (detached)
$0.000 (sub) 0.0%/272k (auto)                                                   gpt-5.5 • medium
codex@.pi-geris
```

The two homes render distinct labels on their own footer line beneath the
token/cost/context/model row, and the quota block above is unchanged in both
runs. The second run also shows the label following the credential store rather
than the model: Pi reported no provider tag there and the store was still named.
