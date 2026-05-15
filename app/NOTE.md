# Notes

## Omi Cloud OAuth implementation

Full OAuth login + PCM16 upload path was implemented and is preserved at commit **21880ab36**.

What was there:
- `OmiLoginWebView`: dual-mode `_FlowMode.omiBacked` / `fallback`; OAuth flow exchanges an authorization code via `https://api.omi.me/v1/auth/token`; redirect URI `omi-ambient-companion://auth/callback`
- `OmiApiClient._syncOAuthPcm16`: decodes OpusFS320 `.bin` → length-prefixed 16 kHz PCM16 chunks, names them `audio_phone_pcm16_16000_1_fs960_<ts>.bin`, sends `X-App-Platform: android-ambient-companion`
- `OmiApiClient._doUploadBytes`: manually-framed multipart body matching the Kotlin ambient-companion client
- `SharedPreferencesUtil.omiConnectedViaFallback`: flag that routed upload to OAuth vs web-scrape path
- `integrations_page`: two login buttons (Direct / app.omi.me), account tile, Web App / Direct badge
