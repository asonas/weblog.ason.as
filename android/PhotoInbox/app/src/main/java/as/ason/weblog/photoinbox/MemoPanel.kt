package com.asonas.weblog.photoinbox

import android.app.AlertDialog
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.Gravity
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import java.io.File
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import okhttp3.HttpUrl.Companion.toHttpUrl

class MemoPanel(private val activity: ComponentActivity, settings: () -> Unit) : LinearLayout(activity) {
    private val store = MemoStore(File(activity.noBackupFilesDir, "inbox-memos.json"))
    private val status = TextView(activity)
    private val content = LinearLayout(activity).apply { orientation = VERTICAL }
    private var selected: String? = null
    private var scheduled: Job? = null
    private var writes: Job? = null
    private var localSaveFailed = false

    init {
        orientation = VERTICAL
        setPadding(16, 12, 16, 12)
        val toolbar = LinearLayout(activity)
        toolbar.addView(Button(activity).apply { text = "メモを追加"; setOnClickListener { activity.lifecycleScope.launch { perform { open(store.add()) }; schedule() } } })
        toolbar.addView(Button(activity).apply { text = "同期"; setOnClickListener { activity.lifecycleScope.launch { sync() } } })
        toolbar.addView(Button(activity).apply { text = "設定"; setOnClickListener { settings() } })
        addView(toolbar)
        addView(status)
        addView(content, LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f))
        activity.lifecycleScope.launch {
            activity.repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch { store.memos.collect { if (selected == null) showList() } }
                launch { while (true) {
                    if (visibility == android.view.View.VISIBLE || store.memos.value.any { it.needsSave || it.flight != null }) sync()
                    delay(10_000)
                } }
            }
        }
    }

    private fun api(): MobileApiClient {
        val token = Credentials(activity).loadToken() ?: error("設定から接続してください。メモは端末に保持しています。")
        return MobileApiClient(UploadWorker.API_BASE_URL.toHttpUrl(), token)
    }

    private suspend fun perform(action: suspend () -> Unit) {
        try { action() }
        catch (error: Exception) {
            if (error is kotlinx.coroutines.CancellationException) throw error
            status.text = if (error is MobileApiException && error.status == 401) "接続が解除されています。設定を確認してください。メモは端末に保持しています。"
                else "保存を確認できません。入力した文章を保持しています。${error.localizedMessage.orEmpty()}"
        }
    }

    private suspend fun sync() {
        perform {
            store.sync(api())
            if (!localSaveFailed) status.text = if (store.memos.value.any { it.needsSave || it.flight != null }) "端末に保存済み・送信待ち" else store.notice.ifEmpty { "保存済み" }
        }
    }

    private fun schedule() {
        scheduled?.cancel()
        scheduled = activity.lifecycleScope.launch { delay(800); sync() }
    }

    private fun showList() {
        selected = null
        content.removeAllViews()
        val rows = LinearLayout(activity).apply { orientation = VERTICAL }
        val scroll = ScrollView(activity).apply { addView(rows) }
        content.addView(scroll)
        for (memo in store.memos.value) {
            rows.addView(Button(activity).apply {
                text = memo.body.ifEmpty { "空のメモ" }.take(160)
                gravity = Gravity.START or Gravity.CENTER_VERTICAL
                setOnClickListener { open(memo.id) }
            })
        }
        if (store.memos.value.isEmpty()) rows.addView(TextView(activity).apply { text = "思いついたことをメモできます。" })
    }

    private fun open(id: String) {
        selected = id
        content.removeAllViews()
        val actions = LinearLayout(activity)
        actions.addView(Button(activity).apply { text = "一覧へ"; setOnClickListener { showList() } })
        actions.addView(Button(activity).apply {
            text = "削除"
            setOnClickListener {
                AlertDialog.Builder(activity).setMessage("このメモを削除しますか？").setNegativeButton("キャンセル", null)
                    .setPositiveButton("削除") { _, _ -> activity.lifecycleScope.launch { perform { writes?.join(); selected?.let { store.delete(it, api()) }; showList() } } }.show()
            }
        })
        content.addView(actions)
        var localId = id
        val editor = EditText(activity).apply {
            hint = "メモ本文"
            contentDescription = "メモ本文"
            gravity = Gravity.TOP
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            setText(store.memos.value.find { it.id == id }?.body.orEmpty())
        }
        var previous = editor.text.toString()
        editor.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
            override fun afterTextChanged(s: Editable?) {
                val body = s.toString()
                val before = previous
                previous = body
                val prior = writes
                status.text = "端末に保存中"
                writes = activity.lifecycleScope.launch {
                    prior?.join()
                    perform {
                        localSaveFailed = true
                        localId = store.edit(localId, body, before)
                        localSaveFailed = false
                        if (selected != null) selected = localId
                        status.text = "端末に保存済み・送信待ち"
                        schedule()
                    }
                }
            }
        })
        content.addView(editor, LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f))
        editor.requestFocus()
        editor.post {
            if (editor.isAttachedToWindow && editor.hasFocus()) {
                WindowInsetsControllerCompat(activity.window, editor).show(WindowInsetsCompat.Type.ime())
            }
        }
    }
}
