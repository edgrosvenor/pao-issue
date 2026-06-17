# pao swallows phpstan output when phpstan fails to start

Minimal, self-contained reproduction of a bug in
[`laravel/pao`](https://packagist.org/packages/laravel/pao) `v1.1.1` (the package
also published as the now-abandoned [`nunomaduro/pao`](https://packagist.org/packages/nunomaduro/pao),
which carries the identical code).

This is a **stock, default Laravel app**. `laravel/pao` already ships in the
default Laravel skeleton's `require-dev`, so the only thing added here is
`phpstan/phpstan` and a 3-line `phpstan.neon`. The point is to show that a stock
app + pao + phpstan is sufficient to trigger the problem — it is not specific to
any custom configuration.

## Summary

`laravel/pao` activates when it detects an AI-agent session (env vars such as
`AI_AGENT`, `CLAUDECODE`, `CURSOR_AGENT`, `CODEX_*`, ...) and reshapes `phpstan`
output into JSON for the agent. On the normal paths this works well:

- phpstan **succeeds** → `{"tool":"phpstan","result":"passed","errors":0}`
- phpstan reports **lint errors** → `{"tool":"phpstan","result":"failed","errors":N,...}`

But whenever phpstan does **not** produce parseable JSON containing a `totals` key
— a config error, a fatal, an OOM, a missing `--configuration`/`scanFiles` target,
a PHP error before analysis — pao emits **completely empty output and exits
non-zero**. The real error message is gone. For an agent (or a human) this is a
silent failure with zero diagnostics: the command "fails" with nothing printed.

## Reproduce

```bash
composer create-project laravel/laravel pao-issue   # laravel/pao is already in require-dev
cd pao-issue
composer require --dev phpstan/phpstan
printf 'parameters:\n    level: 0\n    paths:\n        - app\n' > phpstan.neon
./reproduce.sh
```

> pao is dormant in normal shells/CI; it only activates when an agent env var is
> present. `reproduce.sh` sets `AI_AGENT=1` explicitly per scenario (and strips any
> inherited agent vars first) so the comparison is clean wherever you run it,
> including inside an existing agent session.

The minimal, deterministic trigger is simply pointing phpstan at a config file
that does not exist:

```bash
AI_AGENT=1 ./vendor/bin/phpstan analyse --configuration=/tmp/does-not-exist.neon
```

## Expected vs actual

| Scenario | Expected | Actual |
| --- | --- | --- |
| phpstan succeeds, pao active | `{"tool":"phpstan","result":"passed","errors":0}` | correct ✅ |
| phpstan lint error, pao active | `{"tool":"phpstan","result":"failed",...}` | correct ✅ |
| phpstan **startup error** (missing config), pao active | the phpstan error, or pao's raw fallback | **empty output, exit 1** ❌ |
| same startup error, `PAO_DISABLE=1` | the real phpstan error | the real phpstan error ✅ |

## Observed output (from `reproduce.sh`)

**A (control) — phpstan SUCCESS, pao active (`AI_AGENT=1`)**
```
$ AI_AGENT=1 ./vendor/bin/phpstan analyse --configuration=phpstan.neon
{"tool":"phpstan","result":"passed","errors":0}
exit code: 0
```

**B (bug) — missing config, pao active (`AI_AGENT=1`)**
```
$ AI_AGENT=1 ./vendor/bin/phpstan analyse --configuration=/tmp/does-not-exist.neon
(no output)
exit code: 1
```

**C (proof it is pao) — missing config, `PAO_DISABLE=1`**
```
$ AI_AGENT=1 PAO_DISABLE=1 ./vendor/bin/phpstan analyse --configuration=/tmp/does-not-exist.neon
Project config file at path /tmp/does-not-exist.neon does not exist.
exit code: 1
```

The only difference between **B** and **C** is `PAO_DISABLE=1`. B is empty; C shows
the real error. That isolates pao as the cause.

**D / D' (bonus) — for contrast, the lint-error path works under pao**
A file containing `$undefinedVariable` produces, with pao active:
```
{"tool":"phpstan","result":"failed","errors":1,"error_details":{...}}
```
and with `PAO_DISABLE=1`, the normal phpstan error table. So pao is functioning;
it is specifically the **non-`totals` / startup-failure path** that is swallowed.

## Root cause

Two cooperating issues in pao's phpstan driver
(`vendor/laravel/pao/src/...`, line numbers from `v1.1.1`):

1. **The raw-output fallback is defeated by an early `reset()`.**
   `src/Autoload.php` (lines 42-44) registers a shutdown handler that first calls
   the driver's `parse()`, then reads the capture buffer as a fallback so that
   unparseable output is still surfaced:

   ```php
   $result   = $execution->driver->parse() ?: [];                   // Autoload.php:42
   $captured = trim(UserFilters\CaptureFilter::output());           // Autoload.php:44  (fallback)
   ```

   But `src/Drivers/Phpstan/Starter::parse()` (lines 41-46) reads the buffer and
   then **clears it before returning**:

   ```php
   $captured = trim(CaptureFilter::output());     // Starter.php:41
   CaptureFilter::reset();                         // Starter.php:43  <- buffer wiped here
   if ($captured === '') {
       return null;                                // Starter.php:46
   }
   ...
   if (! is_array($data) || ! isset($data['totals'])) {
       return null;                                // Starter.php:59  <- non-JSON => null
   }
   ```

   On any non-JSON output, `parse()` returns `null` **and** has already emptied the
   buffer. Back in the shutdown handler `$captured` is therefore `''`, the
   `$result['raw'] = $lines` fallback branch never runs, `$result` stays `[]`, and
   the final `if ($result !== [])` guard (`Autoload.php:67`) skips the write.
   Nothing is printed.

2. **stderr is silenced.** `Starter::start()` (`Starter.php:25`) calls
   `silenceStderr()` (`src/Drivers/Starter.php:39`, which appends the `agent_output_null`
   filter to `STDERR`), so phpstan's real error message — which it writes to stderr
   on a config/startup failure — is discarded too. With the stdout fallback wiped
   *and* stderr nulled, there is no remaining channel for the error.

Net effect: `parse()` returns `null` → `$result === []` → the write is skipped →
**empty output, non-zero exit, no diagnostics.**

### Suggested fix direction

Let the shutdown handler own the fallback: don't `reset()` the capture buffer
inside `parse()` before the handler has read it, and/or surface the captured
stderr/stdout when `parse()` returns `null`, so a failed run still prints
*something*. Even a minimal `{"tool":"phpstan","result":"error","raw":[...]}`
fallback would turn a silent failure into an actionable one.

## CI demo

`.github/workflows/reproduce.yml` runs `reproduce.sh` with `AI_AGENT=1` exported,
so the swallow is visible directly in the Actions logs. (Without an agent env var
pao is dormant, so the workflow exports it explicitly.)

## Versions

| Package | Version |
| --- | --- |
| `laravel/pao` (demoed) | v1.1.1 |
| `nunomaduro/pao` (same bug, abandoned alias) | v1.0.4 |
| `phpstan/phpstan` | 2.2.2 |
| `laravel/agent-detector` (pao dep) | v2.0.2 |
| `laravel/framework` | v13.16.1 |
| PHP | 8.4.21 |

### Note on `nunomaduro/pao` vs `laravel/pao`

The bug was originally found via `nunomaduro/pao` v1.0.4. That package is now
abandoned and redirects to `laravel/pao`; the buggy phpstan driver code (the
`CaptureFilter::reset()` before the fallback read, the `totals` guard, and the
`if ($result !== [])` skip) is byte-for-byte the same in both. Installing *both*
packages at once is not viable — each registers its own `Autoload.php` via
Composer `files` autoloading, so both shutdown handlers run and the second
`Execution::start()` throws `ShouldNotHappenException`. This repo therefore demos
the maintained `laravel/pao` in isolation, which gives the cleanest A/B/C.
