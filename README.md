# skill-runner

Thin loop wrapper around `claude -p` that runs any Claude Code skill against multiple inputs sequentially. Each input gets a fresh session. Includes a live Rich dashboard.

## Setup

```bash
cp .env.example .env        # edit defaults as needed
pip install rich             # dashboard dependency
```

## Usage

```bash
# Run a skill against specific inputs
./run --skill /analyze-association --workdir ~/foundry-portal --input CR23002026 CR23002027

# Run from a file (one input per line)
./run --skill /analyze-association --workdir ~/foundry-portal --file ~/registrations.txt

# Limit, resume, dry-run
./run --skill /analyze-association --workdir ~/foundry-portal --file ~/list.txt --limit 10
./run --skill /analyze-association --workdir ~/foundry-portal --resume
./run --skill /analyze-association --workdir ~/foundry-portal --input CR23002026 --dry-run

# Override defaults
./run --skill /test-echo --workdir ~/foundry-portal --input CR23002026 --model sonnet --effort high
```

## Dashboard

Start in a second terminal — auto-discovers runs, shows live progress, subscription usage, and output log.

```bash
python3 dashboard.py                  # auto-finds latest run
python3 dashboard.py runs/<run-dir>   # specific run
```

## Sound Effects

Enable with `--sounds` flag or `SKILL_SOUNDS=true` in `.env`. Requires WSL2 with Windows Terminal.

## How It Works

Skills live in their project's `.claude/skills/` directory — skill-runner doesn't manage them. It just calls `claude -p "/skill-name input"` in a loop with progress tracking, resume support, and cost reporting.

Results are saved as stream-json in `runs/<skill>_<timestamp>/results/`. Progress is tracked via append-only JSONL (crash-safe, supports resume).
