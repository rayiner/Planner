# Recent Mail Search

The search box above Recent Mail sends the complete query to the Outlook mail
source and displays the matching messages in the same chronological, day-grouped
list as the normal Recent Mail window.

- Typing is debounced.
- Empty search text restores the current Recent Mail window.
- Search loading, no-results, and failure states are distinct.
- A selected message is cleared if it is absent from completed search results.
- Search does not query Core Data or affect CloudKit synchronization.
