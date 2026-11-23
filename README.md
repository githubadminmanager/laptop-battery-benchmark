# Laptop Battery Benchmark

A single PowerShell script that estimates how long a Windows laptop battery really lasts.
It runs a repeatable "simulated user" workload while logging the battery every minute,
then rates the result, adjusted for how old the PC is.

> Early version. The numbers are only comparable with other runs of this same script,
> not with PCMark or review-site figures.

## What it does

- Closes your open apps first (asks before it does, never force-kills anything).
- Opens Notepad, Calculator and Chrome (Edge if there is no Chrome) with website tabs.
- Acts like a person: types, scrolls, switches tabs, and moves the mouse every few seconds.
- Keeps the PC awake and the screen on, sets brightness (default 65%) and restores it afterwards.
- Logs charge, power draw and CPU every minute to a CSV and a text log.
- Prints a rating, estimated time left, battery health and an age-adjusted verdict.

## Use

1. Charge to about 100%, then **unplug the charger**.
2. Run in a normal PowerShell or Windows Terminal window (not ISE):

```powershell
powershell -ExecutionPolicy Bypass -File .\battery_test.ps1
```

With no options it shows a **settings menu** (tabs, browser, websites, mouse activity, brightness,
stop level and more). Type a number to change something, `S` to save your choices as the default
(stored in `%APPDATA%\battery_benchmark_settings.json`), `R` to reset, or press Enter to start.
Any option typed on the command line skips the menu, e.g. a 10-tab run:

```powershell
powershell -ExecutionPolicy Bypass -File .\battery_test.ps1 -Tabs 10 -MouseActivity High
```

Don't touch the laptop while it runs; it controls the mouse and keyboard.
Stop any time with `Q` or Ctrl+C (you get 20 seconds to press `R` to resume).

If the battery died before the report appeared, rebuild it from the CSV:

```powershell
powershell -ExecutionPolicy Bypass -File .\battery_test.ps1 -ReportFrom "$env:USERPROFILE\Desktop\battery_benchmark_YYYYMMDD_HHMM.csv"
```

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `-Tabs` | one per site | Number of browser tabs, 1-30 (extra ordinary sites are added if needed). |
| `-Sites` | 5 sites | Websites to open as tabs. |
| `-Browser` | Auto | `Auto` (Chrome, else Edge), `Chrome`, `Edge` or `None`. |
| `-NoNotepad`, `-NoCalculator` | off | Leave those apps out. |
| `-MouseActivity` | Normal | `Low` (~8 s), `Normal` (~3 s) or `High` (1-2 s) between mouse moves. |
| `-TabSwitchEvery` | 3 | Switch tab every N page visits. 0 = never. |
| `-Brightness` | 65 | Screen brightness during the test. 0 = leave alone. |
| `-StopAt` | 10 | Stop at this battery %. 0 = run until empty. |
| `-Minutes` | 0 | Time limit in minutes. 0 = none. |
| `-KeepApps` | off | Don't close your open apps first. |
| `-NoWorkload` | off | No simulated user; use the laptop yourself. |
| `-PcAgeYears` | auto | Age of the PC. Default comes from the BIOS date (approximate). |
| `-Customize` | | Open the settings menu even when other options are given. |
| `-ReportFrom` | | Build the report from a saved CSV and exit. |
| `-OutputPath` | Desktop | Where the log and CSV go. |

## How the rating works

Full-charge life is worked out from how long each 1% takes (1 min per 1% = 100 min; 3 min per 1% = 5 h),
with real power draw (when the laptop reports it) shown as a cross-check. The scale is a rough rule of thumb for a new laptop:
10h+ Excellent, 7-10h Good, 5-7h Average, 3-5h Poor, under 3h Bad.
For older PCs the scale shrinks: 100% up to 2 years old, then 6.25 points per year
(50% at 10 years, never below 40%). The report shows both the age-adjusted and the new-laptop rating.
These thresholds are a judgement call, not an industry standard.

## Status

Syntax-checked and tested piece by piece (workload, settings menu, report, CSV replay). A full run to an
empty battery has not been validated end to end.

## License

MIT. See [LICENSE](LICENSE).
