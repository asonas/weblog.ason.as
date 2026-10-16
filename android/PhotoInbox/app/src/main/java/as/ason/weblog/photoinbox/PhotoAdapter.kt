package com.asonas.weblog.photoinbox

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.util.Size
import android.view.LayoutInflater
import android.view.ViewGroup
import android.widget.TextView
import androidx.core.view.ViewCompat
import com.asonas.weblog.photoinbox.databinding.ItemPhotoDayBinding
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
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
    private val failure: (String) -> UploadFailure?,
    private val isSending: () -> Boolean,
    private val toggle: (String) -> Unit,
) : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
    private sealed interface Row {
        data class Day(val date: LocalDate) : Row
        data class Photo(val photo: LibraryPhoto) : Row
    }
    private var rows: List<Row> = emptyList()

    fun submitList(values: List<LibraryPhoto>) {
        val previousSize = rows.size
        rows = values.groupBy { it.capturedAt.atZone(ZoneId.systemDefault()).toLocalDate() }
            .toSortedMap(reverseOrder())
            .flatMap { (date, photos) ->
                listOf(Row.Day(date)) + photos.sortedByDescending { it.capturedAt }.map { Row.Photo(it) }
            }
        if (previousSize > 0) notifyItemRangeRemoved(0, previousSize)
        if (rows.isNotEmpty()) notifyItemRangeInserted(0, rows.size)
    }

    fun isDayHeader(position: Int): Boolean = rows[position] is Row.Day

    override fun getItemViewType(position: Int): Int = if (isDayHeader(position)) 1 else 0

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder {
        if (viewType == 1) {
            val binding = ItemPhotoDayBinding.inflate(LayoutInflater.from(parent.context), parent, false)
            return DayViewHolder(binding.root)
        }
        val binding = ItemPhotoBinding.inflate(LayoutInflater.from(parent.context), parent, false)
        binding.root.layoutParams.width = ViewGroup.LayoutParams.MATCH_PARENT
        return PhotoViewHolder(binding, parent as RecyclerView)
    }

    override fun getItemCount(): Int = rows.size

    override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
        when (val row = rows[position]) {
            is Row.Day -> (holder as DayViewHolder).bind(row.date)
            is Row.Photo -> (holder as PhotoViewHolder).bind(row.photo)
        }
    }

    private class DayViewHolder(private val label: TextView) : RecyclerView.ViewHolder(label) {
        init { ViewCompat.setAccessibilityHeading(label, true) }

        fun bind(date: LocalDate) {
            label.text = date.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.LONG))
        }
    }

    inner class PhotoViewHolder(private val binding: ItemPhotoBinding, private val grid: RecyclerView) : RecyclerView.ViewHolder(binding.root) {
        fun bind(photo: LibraryPhoto) {
            val columns = (grid.layoutManager as androidx.recyclerview.widget.GridLayoutManager).spanCount
            val width = grid.width.takeIf { it > 0 } ?: grid.measuredWidth
            val margins = binding.root.layoutParams as ViewGroup.MarginLayoutParams
            binding.root.layoutParams.height = maxOf(1, (width - grid.paddingLeft - grid.paddingRight) / columns - margins.leftMargin - margins.rightMargin)
            val uri = photo.uri.toString()
            binding.photo.tag = uri
            binding.photo.setImageDrawable(null)
            renderStatus(uri)
            val time = DateTimeFormatter.ofLocalizedDateTime(FormatStyle.SHORT).withZone(ZoneId.systemDefault()).format(photo.capturedAt)
            binding.root.contentDescription = "$time の写真、${failure(uri)?.message ?: binding.status.text}"
            binding.root.setOnClickListener {
                toggle(uri)
                renderStatus(uri)
                binding.root.contentDescription = "$time の写真、${failure(uri)?.message ?: binding.status.text}"
            }
            scope.launch {
                val bitmap = withContext(Dispatchers.IO) { thumbnail(photo) }
                if (binding.photo.tag == uri) binding.photo.setImageBitmap(bitmap)
            }
        }

        private fun renderStatus(uri: String) {
            if (failure(uri) != null) {
                binding.status.setText(R.string.upload_failed)
                binding.photo.alpha = 0.55f
                binding.root.isEnabled = !isSending()
                return
            }
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
