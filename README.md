# agent-lock

A checkout lock for agents sharing one Git checkout, supported by [AgentTerm](https://github.com/albertwujj/agent-term). Agents using the lock take turns changing files and running work that shares resources such as test ports. Read-only work can continue.

## Adding it

Ask your agent:

```text
Clone the repository below into ai/ in this project, and leave ai/ out
of .gitignore.
https://github.com/yunxin/agent-lock
```

Other locations work too ([placement](https://github.com/albertwujj/agent-term/blob/main/docs/conventions.md#placement)).

## Using it

Name [`proceed-by-lock-and-branch.md`](proceed-by-lock-and-branch.md) in your prompt; `@proceed-b` completes to it. The agent takes the lock and creates a task branch before editing, then releases the lock when its local work is done.

AgentTerm shows which session holds the checkout. See [the checkout lock guide](https://github.com/albertwujj/agent-term/blob/main/docs/lock.md) for use from the terminal.

<a name="how-it-works"></a>
<a name="conventions"></a>
<a name="integrating-it"></a>

## The mechanics

The scripts also work in other terminals and automation. See [integration](docs/integration.md), [lock mechanics](lock-mechanics.md), and [configuration](CONFIG.md) for details.
