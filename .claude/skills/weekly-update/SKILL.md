---
name: weekly-update
description: Update the EECS 449 Group 12 Google Slides deck with this week's PRs, issues, and a short summary. Run with /weekly-update, optionally followed by the slide date.
argument-hint: "[slide date, e.g. October 14, 2026]"
disable-model-invocation: true
---

# Weekly update slide

The course requires a slide each week that records the team's GitHub PRs and issues.
This skill fills that slide in the deck [[EECS 449] Group 12](https://docs.google.com/presentation/d/1i_tVM1zBoN1IY6EEjWofZCMQmG-8VRm3lF36HZNN7FQ/edit) from the repo's real GitHub activity.

- Presentation ID: `1i_tVM1zBoN1IY6EEjWofZCMQmG-8VRm3lF36HZNN7FQ`
- Repo: `jere67/eecs449-project`
- Arguments: `$ARGUMENTS` (a slide date such as "October 14, 2026"; empty means the next Wednesday on or after today, since the class meets Wednesdays)

## Prerequisites

Edit through the Google Slides connector (`read_presentation`, `read_slide_page`, `read_slide_page_thumbnail`, `update_presentation`).
Load those tools with ToolSearch in one call.
If they are missing, stop and ask the user to turn on the Google Slides connector; Google Drive alone can only read the deck.
Do not fall back to Claude in Chrome, and do not use Drive's PDF export (this deck is too large for the MCP).
`gh` must be authenticated for the repo.

## The slide layout

Every weekly slide from October 7, 2026 on uses the same layout. Keep it exactly:

- "Group 12" top left and the slide date top right (a SUBTITLE layout placeholder).
- A summary strip under the header: a text box in Instrument Sans 11pt that starts with a bold "This week:" and is at most two lines (about 240 characters). A third line collides with the cards.
- Two cards starting 1.20 in from the top. The left one has a pill reading "PRs", the right one a pill reading "Issues", each 0.17 in below the card's top edge, with the list starting just under the pill.
  Duplicating the latest weekly slide carries this geometry over; don't move or resize anything unless text reaches a card's bottom edge.
- PRs column: bold sub-headers "Merged" and "Opened", each with its own numbered list.
- Issues column: bold sub-headers "Closed" and "Opened", each with its own numbered list.
- Each line reads `<title> (#N)` in Instrument Sans 10pt. `#N` links to GitHub and is underlined in the dark text color (LIGHT1), never the theme's pink HYPERLINK color, which disappears on the pink card.

Slide 4 (September 30) predates this layout. Never edit older weekly slides unless the user asks.

## Steps

### 1. Read the deck

Call `read_presentation` with this mask:

```
["revisionId,slides(objectId,pageElements(objectId,transform(translateX),shape(shapeType,placeholder.type,text.textElements.textRun.content)))"]
```

Weekly slides are the ones with a shape whose text is "PRs".
The latest weekly slide is the last of them.
On it, identify the four boxes you will fill:

| Role | How to find it |
|---|---|
| date | SUBTITLE placeholder whose text is a date such as "October 7, 2026" |
| summary | TEXT_BOX whose text starts with "This week:" |
| prs | TEXT_BOX whose text starts with "Merged" or "Opened", with `translateX` under 4572000 (left half) |
| issues | TEXT_BOX whose text starts with "Closed" or "Opened", with `translateX` of 4572000 or more (right half) |

For reference, the October 7 slide is `hcaa0b8f71d99b43_1_33`, with date `hcaa0b8f71d99b43_1_38`, summary `s5_summary`, prs `hcaa0b8f71d99b43_1_36` and issues `hcaa0b8f71d99b43_1_42`.
Later slides use IDs named `wk<YYYYMMDD>_<role>`.

Decide the target date from the arguments.
If the latest weekly slide already has that date, fill it in place.
Otherwise you will duplicate it in step 4, and the previous slide is the latest weekly slide.

### 2. Gather GitHub activity

```
gh pr list --repo jere67/eecs449-project --state all --limit 200 --json number,title,state,createdAt,mergedAt,closedAt
gh issue list --repo jere67/eecs449-project --state all --limit 200 --json number,title,state,createdAt,closedAt,milestone,labels
```

The window runs from the previous weekly slide's date (inclusive) to now.
When updating a slide in place, the window starts at the weekly slide before it.
Sort items into sections like this:

- PRs "Merged": `mergedAt` in the window.
- PRs "Opened": `createdAt` in the window and still open. A PR opened and merged in the same window goes under "Merged" only.
- Issues "Closed": `closedAt` in the window.
- Issues "Opened": `createdAt` in the window and still open. An issue opened and closed in the same window goes under "Closed" only.
- Skip an item the previous slide already shows in the same section.
- PRs closed without merging are left off the columns; mention them in the summary if they matter.

Use the PR or issue title verbatim.

### 3. Fit the columns

Each column holds about 16 lines at 10pt (two sub-headers plus 14 wrapped lines), and a title wraps after about 52 characters.
Eight PRs with typical titles fill the PR card, so the script warns past that; still check the render, because its estimate is rough.
When the Opened issues would not fit (more than about six, as a rule), group them by milestone, one line each:
`<Milestone name>: <short comma-separated topics> (#a-#b)`, with the range linked to `https://github.com/jere67/eecs449-project/milestone/<number>`.
If a milestone's numbers are not contiguous, list them (`#6, #9, #12`) and link each one.
Epics can share one line linked to `https://github.com/jere67/eecs449-project/issues?q=is%3Aissue+label%3Aepic`.
List PRs one per line; if a week has too many, ask the user how to trim before grouping them.

### 4. Write the spec and build the batch

Write the summary: one or two sentences in the team's voice ("we"), starting with "This week:", at most 240 characters, built only from facts in the GitHub data.
Plain dashes only, never an em dash.

Save a spec in the session scratchpad and run the builder, which computes every text index:

```
python3 -I .claude/skills/weekly-update/scripts/build_batch.py <spec.json> > <batch.json>
```

The script's docstring documents the spec format.
Set `revision` to the `revisionId` from step 1.
For a new week, add the `duplicate` block mapping the latest weekly slide and its four boxes to `wk<YYYYMMDD>_slide`, `_date`, `_summary`, `_prs` and `_issues`, and point each box at its new ID.
The copy lands right after the source slide, which is where it belongs.
Fix every warning the script prints before sending.

Send the batch with `update_presentation`, passing its `requests` and `writeControl` exactly.
If Google rejects the revision, read again, rebuild, and resend; never drop `writeControl`.

### 5. Verify

Call `read_slide_page_thumbnail` with `thumbnailSize: "LARGE"`, download the image URL with `curl` into the scratchpad, and look at it with Read.
Check that the summary is two lines and clears the cards, both columns end inside their cards, numbering restarts at 1 under each sub-header, and every `#N` is dark and underlined.
Fix anything off and check again.

### 6. Report

Tell the user which slide you filled or added, with the deck link, and say the link stays the same.
List what went into each section and any judgment calls, such as groupings or skipped items.
This skill only edits the deck. It never commits, comments on GitHub, or edits issues.
