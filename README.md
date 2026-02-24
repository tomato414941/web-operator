# web-operator

An experiment in autonomous AI agents operating web properties.

An AI agent (powered by OpenAI Codex) runs on a server every 3 hours, autonomously building and growing web properties — choosing what to work on, creating content, managing infrastructure, and tracking metrics. A human provides only a server and a GitHub account.

## How it works

Each session follows a multi-agent pipeline with **information isolation** — agents only see what they need:

1. **Deterministic Evaluation** — collects organic referral metrics per property from nginx logs
2. **State Evaluator + Critic + Demand Analyst** (parallel) — state evaluator assesses property health; critic identifies failures; demand analyst maps where real traffic exists
3. **Strategist** — reads all three analyses, produces a concrete work order. Cannot see the property list — decides based on demand data only
4. **Worker** — executes the work order. Follows instructions, does not make strategic decisions
5. **Action Evaluator** — reviews what the worker did, rates strategic impact and work order compliance

Sessions are scheduled via cron. The agent communicates with the human owner through GitHub Issues.

## What the agent has built

The agent autonomously acquired a domain and deployed multiple web properties:

- [DevToolbox](https://devtoolbox.dedyn.io/) — developer tools and guides
- Various "Kit" sub-properties (DateKit, BudgetKit, HealthKit, SleepKit, FocusKit, OpsKit, StudyKit)
- [Profit](https://profit.46.225.49.219.nip.io/) — offer/bounty page

## Project structure

```
orchestrator/            # Session management
  run.sh                 # Entry point (cron, flock for concurrency control)
  session.sh             # Multi-agent pipeline
  config.sh              # Timeout settings
  evaluate.sh            # Deterministic metrics collection
  DEMAND_PROMPT.md       # Demand analyst instructions
  STRATEGIST_PROMPT.md   # Strategist instructions
  WORKER_PROMPT.md       # Worker instructions
  EVAL_STATE_PROMPT.md   # State evaluator instructions
  CRITIC_PROMPT.md       # Critic instructions (adversarial review)
  EVAL_ACTION_PROMPT.md  # Action evaluator instructions
workspace/               # Agent's working directory (on server)
logs/                    # Session logs (on server)
```

## Key design decisions

- **Information isolation** — the strategist cannot see the property list, preventing anchoring to existing properties. It decides based on demand data only
- **6 AI roles per session** — demand analyst, state evaluator, critic, strategist, worker, action evaluator
- **Separation of judgment and execution** — strategist decides what to do, worker executes. Worker cannot override strategic constraints
- **Independent adversarial critic** — runs in parallel, reads only raw data, identifies failures and wasted effort
- **No persistent process** — cron + flock instead of `while true; sleep`
- **Stateless sessions** — agents read metrics fresh each time, no carried-over plans
- **Human-in-the-loop via Issues** — agents create `human-task` issues when they need human action

## Related

- Agent's GitHub: [autonomy414941](https://github.com/autonomy414941)
- Sibling project: [alife-auto-dev](https://github.com/tomato414941/alife-auto-dev) (autonomous alife simulation development)
