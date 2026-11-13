# Grounded reply suggestions

The 0.3.0 prompt forced two replies and encouraged more checks after completed
work. In practice, that often produced duplicate or unnecessary tests and reviews.
The three original prompt spot checks did not cover those failures adequately.

The replacement uses one on-device guided-generation request. It restates the
user's request, classifies the latest agent response, quotes its evidence, and
returns either actual offered choices or one pending action. Validation then:

- shows nothing for completed work;
- requires the evidence to occur in the latest agent response;
- requires an unfinished action to cite an explicit pending/failure statement;
- copies question options from the actual response;
- limits a pending action to one chip instead of two paraphrases;
- rejects unrequested publishing or cancellation, and can trim an appended
  unrequested action when the remaining fragment names the user's requested work.

The latest user request is supplied separately so it cannot be displaced by a
long run of progress messages. All classification and generation run locally;
reasoning and evidence are discarded after validation and are not logged or
persisted. Only the resulting chips enter the existing in-memory cache.

## Local evaluation, 2026-11-12

Eight synthetic scenarios, each repeated three times, compared the deployed
0.3.0 prompt with the production writer and validator:

| Variant | Scenario checks passed |
| --- | --- |
| 0.3.0 prompt | 6 / 24 |
| Grounded generation and validation | 24 / 24 |

Checks cover reply count, required subjects, and explicitly forbidden or already
completed work. Actionable scenarios require a nonempty result, so suppressing all
suggestions cannot pass. The cases include a release awaiting external
processing, completed work, two real choice questions, a failing export test,
a requested commit/push, an explicitly forbidden deployment, and release notes
with an unrequested commit appended by the agent.

Examples from the revised implementation:

| Current state | Chips |
| --- | --- |
| Release uploaded; store still processing | Check beta upload status. |
| Stream records or use smaller batches? | stream the records / use smaller batches |
| SQLite or Postgres? | SQLite / Postgres |
| Fix complete, tests pass, no commit requested | None |
| Notes still need updating; commit not requested | Finish updating the release notes |

Revised requests took approximately 1.5–2.2 seconds in this run. These are small,
synthetic regression checks, not a measured real-world acceptance rate. The model
can still misclassify a message or produce an unsupported reply; validation then
prefers no chip. The English pending-work and permission checks are conservative,
and implicit permissions or other languages may cause useful replies to be hidden.

Run from the repository root on a Mac with Apple Intelligence enabled:

```sh
swiftc -parse-as-library Shared/OnDeviceText.swift \
  bergr/Intelligence/GuidedReplySuggestions.swift \
  bergr/Intelligence/ReplySuggestions.swift \
  scripts/experiment_reply_suggestions.swift -o /tmp/bergr-reply-experiment
/tmp/bergr-reply-experiment 3
```

Fixtures are in `scripts/fixtures/reply_suggestions.json`. They contain no real
conversation text, screenshots, hostnames, account details, or credentials.
