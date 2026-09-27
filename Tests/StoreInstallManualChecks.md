# Store installation on a physical iPhone

These device checks require a real iPhone and are not marked as completed by CI.

1. Open Store directly after closing AnderStore. Apps appear without expanding sources. No refresh/add buttons; pull to refresh still works. Apps tab has no total counter, and an empty list still explains how to install.
2. Tap Download: the AnderStore sheet shows the real app, available version/size/developer, install explanation and cancel. Cancelling starts no download. Details use the same confirmation.
3. Confirm: stay in Store, with progress in that app row and no blocking download overlay. Switch to Settings/Device/Apps: the same active operation appears in the common status. Return to Store and to app details.
4. Pause/resume on a throttled connection, including before the first bytes and near completion. Check unknown Content-Length: spinner, never a fabricated percentage. Check VoiceOver labels. Cancel while paused, then retry; late callbacks cannot finish or fail the next request.
5. Wait for thirty seconds without progress: delay text appears, but not while paused. Actual byte/preparation progress resets the delay. Preparation/signing/replacement cannot be paused or cancelled using the download control.
6. Tap other rows repeatedly: a second installation does not start. A row from a different source with the same bundle identifier does not show the active operation. Ambiguous replacement asks which copy to replace; cancelling changes none. Hidden/locked copies still require authentication.
7. Test no internet, HTTP failures, mismatched checksum, incompatible/encrypted IPA and invalid signature. Instructions are readable in Russian/English. Signature failures offer Device. Update an existing app and verify its containers, data and settings survive.
8. After success, the row says Open. No automatic tab switch. Home Screen icon is optional and uses the existing guide. Open uses the global launcher and respects protected apps and the selected container.
9. Force-close during download, preparation and replacement. Relaunch: no false success/resume promise or stale progress. Interrupted replacement rolls back before models load; a committed version stays installed. Hidden backup folders never appear as apps. Retry is possible afterwards.
10. Enable Advanced Functions in Settings: Manage Sources opens there, sources persist and existing source links still work. Try light/dark mode, maximum text size, VoiceOver and more than fifty apps.
