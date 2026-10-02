#!/usr/bin/env python3
"""Turn the opt-in suggestion usage log into eval cases scored on real writing.

Cotabby Dev (or Cotabby) writes one JSON line per suggestion outcome to
  ~/Library/Application Support/<bundle id>/suggestion-usage.jsonl
once "Keep a private record of suggestions" is on (Settings > Context). Each line holds the text
before the caret, what was shown (or why nothing was), and what the writer actually typed next.

This script makes each such caret position a `positive` eval case whose reference continuation is
the words the writer really typed. `LlamaSuggestionEvalTests/test_reportUsageSuite` then scores the
current pipeline on them, so a prompt, filter, or model change is measured against the writer's own
text instead of hand-written cases.

The output holds private text. It goes to build/eval/usage-cases.json, which is gitignored, and is
read from there only. Do not copy it into CotabbyTests/Fixtures.

Usage:
  scripts/usage_log_to_eval_cases.py                       # Cotabby Dev's log
  scripts/usage_log_to_eval_cases.py --bundle com.jacobfu.tabby
  scripts/usage_log_to_eval_cases.py --log path/to/suggestion-usage.jsonl
"""

import argparse
import collections
import json
import os
import re
import sys

REFERENCE_WORDS = 6
TYPED_AFTER_LIMIT = 160  # SuggestionUsageRecord.typedAfterLimit


def default_logs(bundle):
    base = os.path.expanduser(f"~/Library/Application Support/{bundle}")
    # Oldest first, so ids stay stable as the log grows.
    return [os.path.join(base, "suggestion-usage.previous.jsonl"), os.path.join(base, "suggestion-usage.jsonl")]


def read_records(paths):
    records = []
    for path in paths:
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    continue  # a line cut by a crash; skip it rather than fail the whole run
    return records


def reference(typed_after):
    """The first few words the writer typed, dropping a last word the log may have cut short."""
    words = typed_after.split()
    if len(typed_after) >= TYPED_AFTER_LIMIT and not typed_after[-1].isspace() and len(words) > 1:
        words = words[:-1]
    words = words[:REFERENCE_WORDS]
    if not words:
        return None
    text = " ".join(words)
    # Keep the writer's own leading space: it is the word boundary the scorer checks mid-word.
    if typed_after[:1].isspace():
        text = " " + text
    return text


def to_case(index, record):
    typed_after = record.get("typedAfter", "")
    if not re.search(r"\w", typed_after):
        return None  # nothing typed afterwards: no reference continuation to score against
    ref = reference(typed_after)
    if ref is None:
        return None
    preceding = record["precedingText"]
    tags = ["usage", record["outcome"]]
    if preceding[-1:].isalpha() and typed_after[:1].isalpha():
        tags.append("midword")
    if record.get("isRetry"):
        tags.append("retried")
    app = record.get("applicationName") or "App"
    tags.append("app:" + app)
    return {
        "id": f"usage-{index:05d}",
        "tags": tags,
        "applicationName": app,
        "bundleIdentifier": record.get("bundleIdentifier", "com.example.TestApp"),
        "precedingText": preceding,
        "trailingText": record.get("trailingText", ""),
        "isMultiLineEnabled": False,
        "expectation": {"kind": "positive", "acceptable": [ref]},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--bundle", default="com.jacobfu.tabby.dev")
    parser.add_argument("--log", action="append", help="log file(s); overrides --bundle")
    parser.add_argument("--output", default=None, help="default: <repo>/build/eval/usage-cases.json")
    args = parser.parse_args()

    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    output = os.path.abspath(args.output or os.path.join(repo, "build", "eval", "usage-cases.json"))
    records = read_records(args.log or default_logs(args.bundle))
    if not records:
        sys.exit("No usage records found. Turn on Settings > Context > Suggestion usage log and type for a while.")

    cases, seen = [], set()
    for record in records:
        case = to_case(len(cases) + 1, record)
        if case is None:
            continue
        key = (case["precedingText"], case["expectation"]["acceptable"][0])
        if key in seen:
            continue
        seen.add(key)
        cases.append(case)

    os.makedirs(os.path.dirname(output), exist_ok=True)
    with open(output, "w", encoding="utf-8") as handle:
        json.dump(cases, handle, ensure_ascii=False, indent=1)
        handle.write("\n")
    os.chmod(output, 0o600)

    outcomes = collections.Counter(r.get("outcome") for r in records)
    shown = sum(outcomes[o] for o in ("accepted", "acceptedPartially", "typedThrough", "ignored", "abandoned"))
    right = outcomes["accepted"] + outcomes["acceptedPartially"] + outcomes["typedThrough"]
    print(f"{len(records)} records -> {len(cases)} cases in {output}")
    print("outcomes: " + ", ".join(f"{k} {v}" for k, v in outcomes.most_common()))
    if shown:
        print(f"accepted {outcomes['accepted'] + outcomes['acceptedPartially']}/{shown} shown; "
              f"typed through by hand {outcomes['typedThrough']}; right either way {right}/{shown} "
              f"({100 * right / shown:.1f}%)")
    # What a confidence floor would cost and buy: for suggestions the writer saw and reacted to,
    # how often they were right at each confidence level. A floor belongs where "right" collapses.
    rated = [r for r in records if r.get("averageLogprob") is not None
             and r["outcome"] in ("accepted", "acceptedPartially", "typedThrough", "ignored")]
    if rated:
        print("confidence (mean token logprob) -> right / reacted-to:")
        edges = [-0.5, -1.0, -1.5, -2.0, -2.5, -3.0, float("-inf")]
        upper = 0.0
        for lower in edges:
            bucket = [r for r in rated if lower <= r["averageLogprob"] < upper or (upper == 0.0 and r["averageLogprob"] >= 0)]
            if bucket:
                right_count = sum(r["outcome"] != "ignored" for r in bucket)
                print(f"  [{lower:>5}, {upper:>5}): {right_count}/{len(bucket)} ({100 * right_count / len(bucket):.0f}%)")
            upper = lower

    # Instant suggestions from the writer's own history, shown without the model.
    for source, label in (("phrase", "learned phrases"), ("words", "word habits")):
        fast = [r for r in records if r.get("source") == source]
        if fast:
            fast_right = [r for r in fast if r["outcome"] in ("accepted", "acceptedPartially", "typedThrough")]
            fast_reacted = [r for r in fast if r["outcome"] != "abandoned"]
            print(f"instant {label}: {len(fast)} shown, {len(fast_right)}/{len(fast_reacted)} right when reacted to")

    retried = [r for r in records if r.get("isRetry")]
    if retried:
        retried_shown = [r for r in retried if r.get("shownText") is not None]
        retried_right = [r for r in retried_shown if r["outcome"] in ("accepted", "acceptedPartially", "typedThrough")]
        print(f"retries: {len(retried)} ({len(retried_shown)} shown, {len(retried_right)} right)")


if __name__ == "__main__":
    main()
