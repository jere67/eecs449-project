"""Build the Google Slides batchUpdate that fills one weekly-update slide.

Usage: python3 build_batch.py spec.json > batch.json

The spec names the slide's four text boxes by object ID and gives their new
content. The script computes every text index, so nothing is counted by hand.
Warnings about overflow go to stderr; fix them before sending the batch.

Spec shape:
{
  "revision": "<revisionId from a read taken after the last write>",
  "repo": "jere67/eecs449-project",
  "date":    {"id": "<date box>", "text": "October 14, 2026"},
  "summary": {"id": "<summary box>", "text": "This week: ..."},
  "prs":     {"id": "<PR list box>", "sections": [
                {"header": "Merged", "items": [{"pr": 4, "title": "docs: ..."}]},
                {"header": "Opened", "items": [...]}]},
  "issues":  {"id": "<issue list box>", "sections": [
                {"header": "Closed", "items": [{"issue": 1, "title": "..."}]},
                {"header": "Opened", "items": [
                  {"text": "Foundations: ... (#6-#15)",
                   "links": [["#6-#15", "https://github.com/<repo>/milestone/1"]]}]}]}
}

To start a new week, add a "duplicate" block. The batch then copies the source
slide (the copy lands right after it) with the given object IDs, and the boxes
above should name the new IDs:
  "duplicate": {"slide": "<latest weekly slide>",
                "ids": {"<old slide id>": "wk20261014_slide", "<old date id>": "wk20261014_date", ...}}

Any of date, summary, prs, issues may be left out to skip that box.
A section with no items is dropped, header included.
Set "has_text": false on a box that is currently empty (deleteText fails on an empty box).
"""

import json
import math
import sys

FONT = {"fontFamily": "Instrument Sans", "weight": 400}
DARK = {"opaqueColor": {"themeColor": "LIGHT1"}}
PT = lambda n: {"magnitude": n, "unit": "PT"}

SUMMARY_LEAD = "This week:"
SUMMARY_MAX_CHARS = 240  # two lines at 11pt across the slide (237 fit); a third line hits the cards
LIST_CHARS_PER_LINE = 52  # 10pt in a 4.14 in box with a 0.5 in hanging indent
LIST_MAX_LINES = 16       # 2 headers + 14 wrapped lines filled the PR card on Oct 7 with ~0.2 in to spare


def rng(a, b):
    return {"type": "FIXED_RANGE", "startIndex": a, "endIndex": b}


def replace_text(obj, text, has_text):
    reqs = [{"deleteText": {"objectId": obj, "textRange": {"type": "ALL"}}}] if has_text else []
    reqs.append({"insertText": {"objectId": obj, "insertionIndex": 0, "text": text}})
    return reqs


def item_line(item, repo):
    base = f"https://github.com/{repo}"
    if "pr" in item:
        label = f"#{item['pr']}"
        return f"{item['title']} ({label})", [(label, f"{base}/pull/{item['pr']}")]
    if "issue" in item:
        label = f"#{item['issue']}"
        return f"{item['title']} ({label})", [(label, f"{base}/issues/{item['issue']}")]
    return item["text"], [tuple(link) for link in item.get("links", [])]


def list_requests(box, repo, name):
    obj = box["id"]
    lines, kinds, links = [], [], []
    for section in box["sections"]:
        if not section["items"]:
            continue
        lines.append(section["header"]); kinds.append("h"); links.append([])
        for item in section["items"]:
            text, item_links = item_line(item, repo)
            lines.append(text); kinds.append("i"); links.append(item_links)
    if not lines:
        lines, kinds, links = ["None this week"], ["h"], [[]]

    est = sum(1 if k == "h" else math.ceil(len(t) / LIST_CHARS_PER_LINE) for t, k in zip(lines, kinds))
    if est > LIST_MAX_LINES:
        print(f"WARNING: {name} column needs ~{est} lines, fits ~{LIST_MAX_LINES}. "
              "Group items (e.g. by milestone) or shorten titles.", file=sys.stderr)

    reqs = replace_text(obj, "\n".join(lines), box.get("has_text", True))
    reqs.append({"deleteParagraphBullets": {"objectId": obj, "textRange": {"type": "ALL"}}})
    reqs.append({"updateTextStyle": {"objectId": obj, "textRange": {"type": "ALL"},
        "style": {"weightedFontFamily": FONT, "fontSize": PT(10), "foregroundColor": DARK,
                  "bold": False, "underline": False},
        "fields": "weightedFontFamily,fontSize,foregroundColor,bold,underline,link"}})
    reqs.append({"updateParagraphStyle": {"objectId": obj, "textRange": {"type": "ALL"},
        "style": {"lineSpacing": 115, "alignment": "START", "spaceAbove": PT(0), "spaceBelow": PT(0)},
        "fields": "lineSpacing,alignment,spaceAbove,spaceBelow"}})

    spans, pos = [], 0
    for line in lines:
        spans.append((pos, pos + len(line)))
        pos += len(line) + 1  # UTF-16 length equals len() for the ASCII text this deck uses

    i, first = 0, True
    while i < len(lines):
        start, end = spans[i]
        reqs.append({"updateTextStyle": {"objectId": obj, "textRange": rng(start, end),
            "style": {"bold": True}, "fields": "bold"}})
        reqs.append({"updateParagraphStyle": {"objectId": obj, "textRange": rng(start, end),
            "style": {"indentStart": PT(18), "indentFirstLine": PT(18),
                      "spaceAbove": PT(0 if first else 6), "spaceBelow": PT(2)},
            "fields": "indentStart,indentFirstLine,spaceAbove,spaceBelow"}})
        first = False
        j = i + 1
        while j < len(lines) and kinds[j] == "i":
            j += 1
        if j > i + 1:
            # Each section gets its own list so numbering restarts at 1.
            a, b = spans[i + 1][0], spans[j - 1][1]
            reqs.append({"createParagraphBullets": {"objectId": obj, "textRange": rng(a, b),
                "bulletPreset": "NUMBERED_DIGIT_ALPHA_ROMAN"}})
            reqs.append({"updateParagraphStyle": {"objectId": obj, "textRange": rng(a, b),
                "style": {"indentStart": PT(36), "indentFirstLine": PT(18)},
                "fields": "indentStart,indentFirstLine"}})
            for k in range(i + 1, j):
                for label, url in links[k]:
                    off = spans[k][0] + lines[k].rindex(label)
                    # Links stay dark: the theme's pink HYPERLINK color vanishes on the pink card.
                    reqs.append({"updateTextStyle": {"objectId": obj, "textRange": rng(off, off + len(label)),
                        "style": {"link": {"url": url}, "foregroundColor": DARK, "underline": True},
                        "fields": "link,foregroundColor,underline"}})
        i = j
    return reqs


def summary_requests(box):
    text = box["text"]
    if not text.startswith(SUMMARY_LEAD):
        sys.exit(f"summary must start with {SUMMARY_LEAD!r}")
    if len(text) > SUMMARY_MAX_CHARS:
        print(f"WARNING: summary is {len(text)} chars; over ~{SUMMARY_MAX_CHARS} it wraps to a third line "
              "and collides with the cards.", file=sys.stderr)
    obj = box["id"]
    return replace_text(obj, text, box.get("has_text", True)) + [
        {"updateTextStyle": {"objectId": obj, "textRange": {"type": "ALL"},
            "style": {"weightedFontFamily": FONT, "fontSize": PT(11), "foregroundColor": DARK, "bold": False},
            "fields": "weightedFontFamily,fontSize,foregroundColor,bold"}},
        {"updateTextStyle": {"objectId": obj, "textRange": rng(0, len(SUMMARY_LEAD)),
            "style": {"bold": True}, "fields": "bold"}},
        {"updateParagraphStyle": {"objectId": obj, "textRange": {"type": "ALL"},
            "style": {"lineSpacing": 115, "alignment": "START"}, "fields": "lineSpacing,alignment"}},
    ]


def main():
    spec = json.load(open(sys.argv[1]))
    reqs = []
    if "duplicate" in spec:
        dup = spec["duplicate"]
        if dup["slide"] not in dup["ids"]:
            sys.exit("duplicate.ids must map the source slide itself to the new slide ID")
        reqs.append({"duplicateObject": {"objectId": dup["slide"], "objectIds": dup["ids"]}})
    if "date" in spec:
        # The date is a layout placeholder; replacing its text keeps the inherited style.
        reqs += replace_text(spec["date"]["id"], spec["date"]["text"], spec["date"].get("has_text", True))
    if "summary" in spec:
        reqs += summary_requests(spec["summary"])
    if "prs" in spec:
        reqs += list_requests(spec["prs"], spec["repo"], "PRs")
    if "issues" in spec:
        reqs += list_requests(spec["issues"], spec["repo"], "Issues")
    json.dump({"requests": reqs, "writeControl": {"requiredRevisionId": spec["revision"]}}, sys.stdout)
    print(f"{len(reqs)} requests", file=sys.stderr)


if __name__ == "__main__":
    main()
