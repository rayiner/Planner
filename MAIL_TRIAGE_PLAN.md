# Recent Mail

Planner presents Outlook mail in **Recent Mail** and **Hidden** fields.
Planner no longer persists mail, creates mail folders, threads saved messages,
or links saved messages to tasks.

## Current behavior

- Recent Mail is a rolling Outlook window with selectable day ranges.
- Messages are shown chronologically and grouped by day.
- Search is handled by the Outlook mail source.
- Selecting a message lazily loads its body and headers.
- Hiding adds Outlook's `Hide` category; unhiding removes only that category.
- Hide-tagged messages appear only in Hidden within the selected rolling window.
- Planner keeps envelopes in memory only and stores no per-message state in Core Data.
- CloudKit continues to sync projects, tasks, and day notes.

Any future organization model should be designed independently of the removed
folder and saved-message implementation.
