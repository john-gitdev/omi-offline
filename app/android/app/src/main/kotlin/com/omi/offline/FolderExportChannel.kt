package com.omi.offline

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors

/**
 * The `com.omi.offline/folderExport` channel: copies finished recordings into a folder the
 * user picked with the system folder picker, and renames those copies when the app corrects a
 * recording's date. It never deletes a finished copy: once saved, a copy is the user's. The
 * only files it deletes are its own unfinished partials.
 *
 * Storage Access Framework rather than a path, because since Android 11 an app cannot write
 * into shared storage by path at all, and a path cannot name a folder on an SD card. The
 * grant is persisted ([Context.getContentResolver]`.takePersistableUriPermission`), so the
 * folder stays writable across app and phone restarts until the user removes it in the app
 * or clears its data. `file_picker`'s directory picker does not persist that grant, which is
 * why this is not done through it.
 *
 * Engine-scoped, like [AacEncoderChannel]: copies are made by the auto-upload sweep, which
 * runs in background syncs with no Activity. Only `pickFolder` needs one — it shows the
 * picker — and it reports NO_UI when there is none.
 *
 * Error codes Dart acts on: NO_ACCESS (the grant is gone, or the folder itself is — deleted,
 * or on an SD card that is not mounted), SOURCE_GONE (the recording was deleted before the
 * copy began), GONE (the copy being renamed is no longer in the folder). Anything else is IO.
 */
class FolderExportChannel(private val context: Context, messenger: BinaryMessenger) {
    companion object {
        private const val TAG = "OmiFolderExport"
        private const val CHANNEL = "com.omi.offline/folderExport"

        /** Distinct from OmiCompanionManager.COMPANION_REQUEST_CODE (42). */
        const val REQUEST_PICK_FOLDER = 4207

        /**
         * A copy is written under this prefix and renamed only once complete, so nothing
         * watching the folder — a music app, a sync client — ever sees half a recording.
         * A leading dot also keeps it out of media scans. One left by a process that died
         * mid-copy is removed before the next copy starts.
         */
        private const val PARTIAL_PREFIX = ".omi-partial-"

        private const val GRANT = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION

        /** The live instance, for MainActivity to hand the picker's result to. */
        @Volatile
        var instance: FolderExportChannel? = null
    }

    private class Failure(val code: String, message: String) : Exception(message)

    /** Single thread: copies are large and serialized on the Dart side anyway. */
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val resolver get() = context.contentResolver

    /** The picker's pending result. Main thread only. */
    private var pendingPick: MethodChannel.Result? = null

    init {
        instance = this
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickFolder" -> pickFolder(result)
                "releaseFolder" -> run(result) {
                    releaseFolder(call.argument<String>("treeUri")!!)
                    null
                }
                "hasAccess" -> run(result) { hasAccess(Uri.parse(call.argument<String>("treeUri")!!)) }
                "copyInto" -> run(result) {
                    copyInto(
                        Uri.parse(call.argument<String>("treeUri")!!),
                        File(call.argument<String>("sourcePath")!!),
                        call.argument<String>("name")!!,
                        call.argument<String>("mimeType")!!,
                    ).toString()
                }
                "rename" -> run(result) {
                    rename(
                        Uri.parse(call.argument<String>("treeUri")!!),
                        Uri.parse(call.argument<String>("docUri")!!),
                        call.argument<String>("name")!!,
                    ).toString()
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun run(result: MethodChannel.Result, body: () -> Any?) {
        executor.execute {
            try {
                val value = body()
                main.post { result.success(value) }
            } catch (f: Failure) {
                main.post { result.error(f.code, f.message, null) }
            } catch (e: Exception) {
                Log.w(TAG, "folder operation failed: $e")
                main.post { result.error("IO", e.toString(), null) }
            }
        }
    }

    // --- Picking -----------------------------------------------------------------------

    private fun pickFolder(result: MethodChannel.Result) {
        val activity = MyApp.currentActivity
        if (activity == null) {
            result.error("NO_UI", "No screen to show the folder picker on", null)
            return
        }
        if (pendingPick != null) {
            result.error("BUSY", "The folder picker is already open", null)
            return
        }
        pendingPick = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                GRANT or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )
            activity.startActivityForResult(intent, REQUEST_PICK_FOLDER)
        } catch (e: Exception) {
            pendingPick = null
            result.error("IO", "Could not open the folder picker: $e", null)
        }
    }

    /** From MainActivity. Main thread. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_PICK_FOLDER) return
        val result = pendingPick ?: return
        pendingPick = null
        val tree = data?.data
        if (resultCode != Activity.RESULT_OK || tree == null) {
            result.success(null) // cancelled
            return
        }
        executor.execute {
            try {
                resolver.takePersistableUriPermission(tree, GRANT)
                val label = displayName(rootOf(tree)) ?: tree.lastPathSegment ?: tree.toString()
                main.post { result.success(mapOf("treeUri" to tree.toString(), "label" to label)) }
            } catch (e: Exception) {
                Log.w(TAG, "could not keep access to $tree: $e")
                main.post { result.error("NO_ACCESS", "Could not keep access to that folder: $e", null) }
            }
        }
    }

    private fun releaseFolder(treeUri: String) {
        try {
            resolver.releasePersistableUriPermission(Uri.parse(treeUri), GRANT)
        } catch (e: SecurityException) {
            // Not held any more — nothing to release.
        }
    }

    // --- Access --------------------------------------------------------------------------

    private fun rootOf(tree: Uri): Uri =
        DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))

    private fun hasAccess(tree: Uri): Boolean {
        val granted = resolver.persistedUriPermissions.any { it.uri == tree && it.isWritePermission }
        return granted && exists(rootOf(tree))
    }

    private fun requireAccess(tree: Uri) {
        if (!hasAccess(tree)) throw Failure("NO_ACCESS", "No access to the export folder")
    }

    // --- Documents -----------------------------------------------------------------------

    private fun exists(doc: Uri): Boolean = try {
        resolver.query(doc, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null)
            ?.use { it.moveToFirst() } ?: false
    } catch (e: Exception) {
        false
    }

    private fun displayName(doc: Uri): String? = try {
        resolver.query(doc, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null }
    } catch (e: Exception) {
        null
    }

    private fun supportsRename(doc: Uri): Boolean = try {
        resolver.query(doc, arrayOf(DocumentsContract.Document.COLUMN_FLAGS), null, null, null)?.use {
            it.moveToFirst() && (it.getInt(0) and DocumentsContract.Document.FLAG_SUPPORTS_RENAME) != 0
        } ?: false
    } catch (e: Exception) {
        false
    }

    /** (document uri, display name) of every child of [tree]'s root. */
    private fun children(tree: Uri): List<Pair<Uri, String>> {
        val listing = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val out = mutableListOf<Pair<Uri, String>>()
        resolver.query(
            listing,
            arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null, null, null
        )?.use {
            while (it.moveToNext()) {
                val name = it.getString(1) ?: continue
                out += DocumentsContract.buildDocumentUriUsingTree(tree, it.getString(0)) to name
            }
        }
        return out
    }

    /**
     * [desired], or `name (2).ext`, `name (3).ext`, … when a file already holds it. Checked
     * here rather than trusting the provider to de-duplicate: not every provider does on a
     * rename, and one that renames onto an existing file replaces it — someone else's copy.
     * Case-insensitive, because the shared storage and SD cards this lands on are.
     */
    private fun uniqueName(tree: Uri, desired: String, except: Uri? = null): String {
        val taken = children(tree).filter { it.first != except }.map { it.second.lowercase() }.toSet()
        if (desired.lowercase() !in taken) return desired
        val dot = desired.lastIndexOf('.')
        val base = if (dot > 0) desired.substring(0, dot) else desired
        val ext = if (dot > 0) desired.substring(dot) else ""
        for (n in 2..9999) {
            val candidate = "$base ($n)$ext"
            if (candidate.lowercase() !in taken) return candidate
        }
        throw IOException("No free name for $desired")
    }

    private fun copyInto(tree: Uri, source: File, name: String, mimeType: String): Uri {
        requireAccess(tree)
        if (!source.exists()) throw Failure("SOURCE_GONE", "The recording is no longer on the phone")
        val root = rootOf(tree)

        // Left by a process that died mid-copy. Nothing else writes these, and the Dart side
        // runs one folder operation at a time, so none of them is in progress.
        for ((doc, childName) in children(tree)) {
            if (childName.startsWith(PARTIAL_PREFIX)) deleteQuietly(doc)
        }

        var target = DocumentsContract.createDocument(resolver, root, mimeType, PARTIAL_PREFIX + name)
            ?: throw IOException("The folder refused a new file")
        val renameable = supportsRename(target)
        if (!renameable) {
            // A provider that cannot rename gets the file under its final name directly; the
            // only cost is that a reader can see it while it is still being written.
            deleteQuietly(target)
            target = DocumentsContract.createDocument(resolver, root, mimeType, uniqueName(tree, name))
                ?: throw IOException("The folder refused a new file")
        }
        try {
            val out = resolver.openOutputStream(target, "w") ?: throw IOException("Could not write into the folder")
            out.use { stream -> source.inputStream().use { it.copyTo(stream, 256 * 1024) } }
            if (!renameable) return target
            return DocumentsContract.renameDocument(resolver, target, uniqueName(tree, name, except = target)) ?: target
        } catch (e: Exception) {
            deleteQuietly(target)
            throw e
        }
    }

    private fun rename(tree: Uri, doc: Uri, name: String): Uri {
        requireAccess(tree)
        if (!exists(doc)) throw Failure("GONE", "The copy is no longer in the folder")
        if (displayName(doc)?.equals(name, ignoreCase = true) == true) return doc
        return DocumentsContract.renameDocument(resolver, doc, uniqueName(tree, name, except = doc)) ?: doc
    }

    /** Only ever for the channel's own partial files — never a finished copy. */
    private fun deleteQuietly(doc: Uri) {
        try {
            DocumentsContract.deleteDocument(resolver, doc)
        } catch (e: Exception) {
            Log.w(TAG, "could not delete $doc: $e")
        }
    }
}
