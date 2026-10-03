package com.asonas.weblog.photoinbox

import android.Manifest
import android.app.AlertDialog
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.LayoutInflater
import android.widget.Toast
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.view.View
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.GridLayoutManager
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import com.asonas.weblog.photoinbox.databinding.ActivityMainBinding
import com.asonas.weblog.photoinbox.databinding.DialogPairingBinding
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrl

class MainActivity : ComponentActivity() {
    private lateinit var binding: ActivityMainBinding
    private lateinit var selection: PhotoSelectionStore
    private var photos: List<LibraryPhoto> = emptyList()
    private lateinit var adapter: PhotoAdapter
    private var failures: Map<String, UploadFailure> = emptyMap()
    private var pendingCount = 0
    private var isSending = false
    private val permission = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { grants ->
        if (grants.values.any { it }) loadPhotos() else renderPermissionRequired()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        binding = ActivityMainBinding.inflate(layoutInflater)
        val memoPanel = MemoPanel(this) { showPairing() }.apply { visibility = View.GONE }
        val pages = FrameLayout(this).apply {
            addView(binding.root)
            addView(memoPanel, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        }
        val tabs = LinearLayout(this)
        tabs.addView(Button(this).apply {
            text = "写真"
            setOnClickListener { binding.root.visibility = View.VISIBLE; memoPanel.visibility = View.GONE }
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        tabs.addView(Button(this).apply {
            text = "メモ"
            setOnClickListener { binding.root.visibility = View.GONE; memoPanel.visibility = View.VISIBLE }
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(pages, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
            addView(tabs)
        }
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, windowInsets ->
            val insets = windowInsets.getInsets(
                WindowInsetsCompat.Type.systemBars() or
                    WindowInsetsCompat.Type.displayCutout() or
                    WindowInsetsCompat.Type.ime(),
            )
            view.setPadding(insets.left, insets.top, insets.right, insets.bottom)
            WindowInsetsCompat.CONSUMED
        }
        setContentView(root)
        ViewCompat.requestApplyInsets(root)
        selection = PhotoSelectionStore(this)
        adapter = PhotoAdapter(this, lifecycleScope, selection::status, { failures[it] }, { isSending }) {
            if (failures.containsKey(it)) showFailure(it) else {
                selection.toggle(it)
                renderSelectionCount()
            }
        }
        binding.photoGrid.layoutManager = GridLayoutManager(this, 3)
        binding.photoGrid.adapter = adapter
        binding.photoGrid.addOnLayoutChangeListener { view, _, _, _, _, oldLeft, _, oldRight, _ ->
            val grid = binding.photoGrid.layoutManager as GridLayoutManager
            val columns = maxOf(1, (view.width / (112 * resources.displayMetrics.density)).toInt())
            if (grid.spanCount != columns || view.width != oldRight - oldLeft) {
                grid.spanCount = columns
                adapter.notifyItemRangeChanged(0, adapter.itemCount)
            }
        }
        binding.settingsButton.setOnClickListener { showPairing() }
        binding.sendButton.setOnClickListener { enqueueSelected() }
        binding.failureButton.setOnClickListener { showFailures() }
        WorkManager.getInstance(this).getWorkInfosForUniqueWorkLiveData(UploadWorker.UNIQUE_WORK_NAME)
            .observe(this) { work ->
                isSending = work.any { it.state == WorkInfo.State.RUNNING }
                loadPhotos()
            }
        ensurePermission()
        scheduleUploads()
    }

    override fun onResume() {
        super.onResume()
        if (::selection.isInitialized && hasPhotoPermission()) loadPhotos()
    }

    private fun ensurePermission() {
        if (hasPhotoPermission()) loadPhotos() else permission.launch(photoPermissions())
    }

    private fun loadPhotos() {
        if (!hasPhotoPermission()) {
            renderPermissionRequired()
            return
        }
        lifecycleScope.launch {
            photos = withContext(Dispatchers.IO) { PhotoRepository(this@MainActivity).loadRecentPhotos() }
            selection.updatePhotos(photos)
            val queue = UploadWorker.queueStore(this@MainActivity).items()
            pendingCount = queue.size
            failures = queue.mapNotNull { item -> item.failure?.let { item.assetUri to it } }.toMap()
            adapter.submitList(photos)
            binding.photoGrid.visibility = android.view.View.VISIBLE
            binding.emptyMessage.visibility = if (photos.isEmpty()) android.view.View.VISIBLE else android.view.View.GONE
            if (photos.isEmpty()) binding.emptyMessage.setText(R.string.no_recent_photos)
            renderSelectionCount()
        }
    }

    private fun enqueueSelected() {
        if (isSending) return
        val selected = selection.selectedUris()
        val items = photos.filter { it.uri.toString() in selected }.map {
            UploadItem(assetUri = it.uri.toString(), capturedAt = it.capturedAt, capturedAtSource = it.capturedAtSource)
        }
        lifecycleScope.launch {
            UploadWorker.queueStore(this@MainActivity).enqueue(items)
            scheduleUploads()
            loadPhotos()
            Toast.makeText(this@MainActivity, getString(R.string.queued_photos, items.size), Toast.LENGTH_SHORT).show()
        }
    }

    private fun scheduleUploads() {
        val request = OneTimeWorkRequestBuilder<UploadWorker>()
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        WorkManager.getInstance(this).enqueueUniqueWork(
            UploadWorker.UNIQUE_WORK_NAME,
            ExistingWorkPolicy.APPEND_OR_REPLACE,
            request,
        )
    }

    private fun showPairing() {
        val dialogBinding = DialogPairingBinding.inflate(LayoutInflater.from(this))
        val credentials = Credentials(this)
        dialogBinding.pairingStatus.setText(if (credentials.loadToken() == null) R.string.not_connected else R.string.connected)
        val dialog = AlertDialog.Builder(this)
            .setTitle(UploadWorker.API_BASE_URL.removeSuffix("/"))
            .setView(dialogBinding.root)
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.connect, null)
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val code = dialogBinding.pairingCode.text.toString().filter(Char::isLetterOrDigit)
                if (code.length != 12) {
                    dialogBinding.pairingCode.error = getString(R.string.pairing_code_error)
                    return@setOnClickListener
                }
                dialog.getButton(AlertDialog.BUTTON_POSITIVE).isEnabled = false
                lifecycleScope.launch {
                    try {
                        val deviceName = Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)
                            ?: Build.MODEL
                        val paired = MobileApiClient(UploadWorker.API_BASE_URL.toHttpUrl(), null)
                            .exchangePairing(code, deviceName)
                        credentials.saveToken(paired.token)
                        renderSelectionCount()
                        dialog.dismiss()
                        scheduleUploads()
                        Toast.makeText(this@MainActivity, R.string.pairing_succeeded, Toast.LENGTH_SHORT).show()
                    } catch (_: Exception) {
                        dialogBinding.pairingStatus.setText(R.string.pairing_failed)
                        dialog.getButton(AlertDialog.BUTTON_POSITIVE).isEnabled = true
                    }
                }
            }
        }
        dialog.show()
    }

    private fun renderSelectionCount() {
        val count = selection.selectedUris().size
        binding.selectionCount.text = getString(R.string.photo_count, count)
        binding.sendButton.isEnabled = count > 0 && Credentials(this).loadToken() != null && !isSending
        binding.sendButton.setText(if (isSending) R.string.sending else R.string.send_all)
        binding.uploadStatus.text = getString(R.string.upload_status, selection.uploadedCount(photos), maxOf(0, pendingCount - failures.size))
        binding.failureButton.text = getString(R.string.failed_count, failures.size)
        binding.failureButton.isEnabled = failures.isNotEmpty() && !isSending
    }

    private fun showFailures() {
        val entries = failures.entries.sortedBy { it.key }
        AlertDialog.Builder(this)
            .setTitle(getString(R.string.failed_count, entries.size))
            .setItems(entries.mapIndexed { index, entry -> "${index + 1}: ${entry.value.message}" }.toTypedArray()) { _, index -> showFailure(entries[index].key) }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    private fun showFailure(uri: String) {
        if (isSending) return
        val failure = failures[uri] ?: return
        val message = failure.message + (failure.requestId?.let { "\n${getString(R.string.request_id, it)}" } ?: "")
        AlertDialog.Builder(this)
            .setTitle(R.string.upload_failed)
            .setMessage(message)
            .setPositiveButton(R.string.retry) { _, _ ->
                lifecycleScope.launch {
                    val store = UploadWorker.queueStore(this@MainActivity)
                    store.items().firstOrNull { it.assetUri == uri }?.let { store.retry(it.clientUploadId) }
                    loadPhotos()
                    scheduleUploads()
                }
            }
            .setNeutralButton(R.string.exclude_upload) { _, _ ->
                lifecycleScope.launch {
                    val store = UploadWorker.queueStore(this@MainActivity)
                    store.items().firstOrNull { it.assetUri == uri }?.let { item ->
                        item.preparedFilePath?.let { java.io.File(it).delete() }
                        store.remove(item.clientUploadId)
                    }
                    selection.exclude(uri)
                    loadPhotos()
                }
            }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    private fun renderPermissionRequired() {
        binding.photoGrid.visibility = android.view.View.GONE
        binding.emptyMessage.visibility = android.view.View.VISIBLE
        binding.emptyMessage.setText(R.string.photo_permission_required)
    }

    private fun hasPhotoPermission() = photoPermissions().any {
        ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
    }

    private fun photoPermissions() = when {
        Build.VERSION.SDK_INT >= 34 -> arrayOf(
            Manifest.permission.READ_MEDIA_IMAGES,
            Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
        )
        Build.VERSION.SDK_INT >= 33 -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES)
        else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
    }
}
