Fixtures shared byte-for-byte with the Android repo.

| File | Android counterpart |
|---|---|
| `backup-v2-golden.json` | `core-data/src/test/resources/backup-v2-golden.json` |
| `backup-v2-from-android.json` | produced by Android's encoder, read here |

The backup fixtures keep format 2 portable: a change that breaks one platform's
reader fails a test on that platform rather than showing up as a mangled restore
on someone's new phone.

The AI prompt fixture lives with the app target instead — see
`IoniqTelemetryTests/Fixtures/ai-prompts-golden.txt`, mirrored at
`app/src/test/resources/ai-prompts-golden.txt` on Android.
