package com.omi.offline

import android.app.Application

class MyApp : Application() {
    override fun onCreate() {
        super.onCreate()
        // Re-register the WorkManager periodic sync task on every app start so
        // the interval stays current (UPDATE policy is idempotent if unchanged).
        BackgroundSyncWorker.scheduleFromPrefs(this)
    }
}
