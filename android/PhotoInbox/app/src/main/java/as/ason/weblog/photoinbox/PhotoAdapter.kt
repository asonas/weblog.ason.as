package com.asonas.weblog.photoinbox

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.util.Size
import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.lifecycle.LifecycleCoroutineScope
import androidx.recyclerview.widget.RecyclerView
import com.asonas.weblog.photoinbox.databinding.ItemPhotoBinding
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class PhotoAdapter(
    private val context: Context,
    private val scope: LifecycleCoroutineScope,
    private val status: (String) -> PhotoSelectionStatus,
    private val toggle: (String) -> Unit,
) : RecyclerView.Adapter<PhotoAdapter.PhotoViewHolder>() {
    private var photos: List<LibraryPhoto> = emptyList()

    fun submitList(values: List<LibraryPhoto>) {
        val previousSize = photos.size
        photos = values
        if (previousSize > 0) notifyItemRangeRemoved(0, previousSize)
        if (values.isNotEmpty()) notifyItemRangeInserted(0, values.size)
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): PhotoViewHolder {
        val binding = ItemPhotoBinding.inflate(LayoutInflater.from(parent.context), parent, false)
        binding.root.layoutParams.width = parent.resources.displayMetrics.widthPixels / 3
        binding.root.layoutParams.height = binding.root.layoutParams.width
        return PhotoViewHolder(binding)
    }

    override fun getItemCount(): Int = photos.size

    override fun onBindViewHolder(holder: PhotoViewHolder, position: Int) {
        holder.bind(photos[position])
    }

    inner class PhotoViewHolder(private val binding: ItemPhotoBinding) : RecyclerView.ViewHolder(binding.root) {
        fun bind(photo: LibraryPhoto) {
            val uri = photo.uri.toString()
            binding.photo.tag = uri
            binding.photo.setImageDrawable(null)
            renderStatus(uri)
            binding.root.setOnClickListener {
                toggle(uri)
                renderStatus(uri)
            }
            scope.launch {
                val bitmap = withContext(Dispatchers.IO) { thumbnail(photo) }
                if (binding.photo.tag == uri) binding.photo.setImageBitmap(bitmap)
            }
        }

        private fun renderStatus(uri: String) {
            when (status(uri)) {
                PhotoSelectionStatus.SELECTED -> {
                    binding.status.setText(R.string.selected)
                    binding.photo.alpha = 1f
                    binding.root.isEnabled = true
                }
                PhotoSelectionStatus.EXCLUDED -> {
                    binding.status.setText(R.string.excluded)
                    binding.photo.alpha = 0.55f
                    binding.root.isEnabled = true
                }
                PhotoSelectionStatus.UPLOADED -> {
                    binding.status.setText(R.string.uploaded)
                    binding.photo.alpha = 0.55f
                    binding.root.isEnabled = false
                }
            }
        }

        private fun thumbnail(photo: LibraryPhoto): Bitmap? = if (Build.VERSION.SDK_INT >= 29) {
            context.contentResolver.loadThumbnail(photo.uri, Size(360, 360), null)
        } else {
            context.contentResolver.openInputStream(photo.uri)?.use(BitmapFactory::decodeStream)
        }
    }
}
