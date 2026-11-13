# Reply suggestion experiment

Historical initial spot checks; superseded by the [grounded evaluation](reply-suggestions-grounding.md).

2026-11-12, local Apple Foundation Models on this Mac. Three synthetic coding
conversations; these are prompt spot checks, not a quality benchmark.

The existing writer called `OnDeviceText.clean`, which takes only the first line.
Even when the model generated three replies, only one reached the chip parser.
The suggestions also received no earlier user messages, so they could not see
constraints such as "don't commit yet".

Compared the original instructions and last-message-only prompt against the
production revision: recent conversation, two distinct alternatives, concrete
examples, eight words per reply, and preservation of all response lines.

| Scenario | Original usable chips | Revised usable chips | Revised output |
| --- | --- | --- | --- |
| Login fix complete; user said not to commit | 1 | 2 | Review the login redirect fix / Check auth test coverage |
| Agent offers two startup optimizations | 1 | 2 | Defer cache loading after first frame / Add index for faster cache reads |
| CSV export test fails on timezone formatting | 1 | 2 | Fix date formatting to UTC / Check export with UTC timestamps |

In this run, revised generation took 0.99–1.18 seconds. The original first case
suggested committing and deploying despite the user's constraint (which it had
not been given). The revision respected that constraint. Results vary between
runs; the model can still produce weak, duplicate, or invalid suggestions.
The app requests two useful alternatives and keeps its existing behavior of
showing no suggestions when the model is unavailable. It does not pad the list
with generic fallback replies.

Run the current broader comparison from the repository root with Apple Intelligence enabled:

```sh
swiftc -parse-as-library Shared/OnDeviceText.swift \
  bergr/Intelligence/GuidedReplySuggestions.swift \
  bergr/Intelligence/ReplySuggestions.swift \
  scripts/experiment_reply_suggestions.swift -o /tmp/bergr-reply-experiment
/tmp/bergr-reply-experiment
```

The script uses the production instructions, prompt builder, response cleanup,
and chip parser, and prints raw responses plus the number of usable chips.
