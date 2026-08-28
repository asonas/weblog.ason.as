package com.asonas.weblog.photoinbox

import android.Manifest
import android.app.AlertDialog
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.LayoutInflater
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
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
    private val permission = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { grants ->
        if (grants.values.any { it }) loadPhotos() else renderPermissionRequired()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        selection = PhotoSelectionStore(this)
        adapter = PhotoAdapter(this, lifecycleScope, selection::status) {
            selection.toggle(it)
            renderSelectionCount()
        }
        binding.photoGrid.layoutManager = GridLayoutManager(this, 3)
        binding.photoGrid.adapter = adapter
        binding.settingsButton.setOnClickListener { showPairing() }
        binding.sendButton.setOnClickListener { enqueueSelected() }
        WorkManager.getInstance(this).getWorkInfosForUniqueWorkLiveData(UploadWorker.UNIQUE_WORK_NAME)
            .observe(this) { work ->
                if (work.any { it.state == WorkInfo.State.SUCCEEDED }) loadPhotos()
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
        lifecycleScope.launch {
            photos = withContext(Dispatchers.IO) { PhotoRepository(this@MainActivity).loadToday() }
            selection.updatePhotos(photos)
            adapter.submitList(photos)
            binding.photoGrid.visibility = android.view.View.VISIBLE
            binding.emptyMessage.visibility = if (photos.isEmpty()) android.view.View.VISIBLE else android.view.View.GONE
            if (photos.isEmpty()) binding.emptyMessage.setText(R.string.no_photos_today)
            renderSelectionCount()
        }
    }

    private fun enqueueSelected() {
        val selected = selection.selectedUris()
        val items = photos.filter { it.uri.toString() in selected }.map {
            UploadItem(assetUri = it.uri.toString(), capturedAt = it.capturedAt, capturedAtSource = it.capturedAtSource)
        }
        lifecycleScope.launch {
            UploadWorker.queueStore(this@MainActivity).enqueue(items)
            scheduleUploads()
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
        binding.sendButton.isEnabled = count > 0 && Credentials(this).loadToken() != null
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
