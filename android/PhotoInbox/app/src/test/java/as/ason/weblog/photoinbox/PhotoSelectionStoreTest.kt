package com.asonas.weblog.photoinbox

import android.app.Application
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class PhotoSelectionStoreTest {
    @Test
    fun deselectedPhotosStayExcludedAfterRefreshAndRelaunch() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        context.getSharedPreferences("photo-selection", 0).edit().clear().commit()
        val photos = (1..3).map { LibraryPhoto(Uri.parse("content://media/external/images/media/$it"), Instant.now(), "date_taken") }
        val excluded = photos[1].uri.toString()
        val uploaded = photos[2].uri.toString()
        val store = PhotoSelectionStore(context)
        store.updatePhotos(photos)
        store.toggle(excluded)
        PhotoSelectionStore(context).markUploaded(uploaded)
        repeat(2) { store.updatePhotos(photos) }
        val relaunched = PhotoSelectionStore(context)
        relaunched.updatePhotos(photos)
        assertEquals(PhotoSelectionStatus.EXCLUDED, relaunched.status(excluded))
        assertEquals(PhotoSelectionStatus.UPLOADED, relaunched.status(uploaded))
        assertEquals(setOf(photos[0].uri.toString()), relaunched.selectedUris())
        relaunched.toggle(excluded)
        relaunched.updatePhotos(photos)
        assertEquals(PhotoSelectionStatus.SELECTED, relaunched.status(excluded))
    }
}
