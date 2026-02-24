# web-operator

An experiment in autonomous AI agents operating web properties.

An AI agent (powered by OpenAI Codex) runs on a server every 3 hours, autonomously building and growing web properties — choosing what to work on, creating content, managing infrastructure, and tracking metrics. A human provides only a server and a GitHub account.

## How it works

Each session follows a 5-step pipeline:

1. **Deterministic Evaluation** — collects metrics (nginx logs, site health checks) reflecting changes since last session
2. **State Evaluator + Critic** (parallel) — state evaluator assesses traffic and property health; critic independently identifies what is NOT working and what should be stopped
3. **Actor** — reads both assessments, decides what to do, and executes (content, infrastructure, SEO, analytics, etc.)
4. **Action Evaluator** — reviews what the actor did and rates strategic impact

Sessions are scheduled via cron. The agent communicates with the human owner through GitHub Issues.

## What the agent has built

The agent autonomously acquired a domain and deployed multiple web properties:

- [DevToolbox](https://devtoolbox.dedyn.io/) — developer tools and guides
- Various "Kit" sub-properties (DateKit, BudgetKit, HealthKit, SleepKit, FocusKit, OpsKit, StudyKit)
- [Profit](https://profit.46.225.49.219.nip.io/) — offer/bounty page

## Project structure

```
orchestrator/          # Session management
  run.sh               # Entry point (cron, flock for concurrency control)
  session.sh           # 5-step pipeline
  config.sh            # Timeout settings
  evaluate.sh          # Deterministic metrics collection
  AGENT_PROMPT.md      # Agent instructions
  EVAL_STATE_PROMPT.md # State evaluator instructions
  CRITIC_PROMPT.md     # Critic instructions (adversarial review)
  EVAL_ACTION_PROMPT.md# Action evaluator instructions
workspace/             # Agent's working directory (on server)
logs/                  # Session logs (on server)
```

## Key design decisions

- **No persistent process** — cron + flock instead of `while true; sleep`
- **4 AI roles per session** — state evaluator, critic, actor, action evaluator (separation of concerns)
- **Independent adversarial critic** — runs in parallel with state evaluator, reads only raw data, identifies failures and wasted effort
- **Stateless sessions** — agent reads STATUS.md and metrics fresh each time, no carried-over plans
- **Category diversity rule** — agent must rotate work categories to avoid local optima
- **Human-in-the-loop via Issues** — agent creates `human-task` issues when it needs human action

## Related

- Agent's GitHub: [autonomy414941](https://github.com/autonomy414941)
- Sibling project: [alife-auto-dev](https://github.com/tomato414941/alife-auto-dev) (autonomous alife simulation development)
