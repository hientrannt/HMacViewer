package io.github.hientrannt.hmacviewer

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast

/** Partner ID and password form with the recently used IDs. */
class MainActivity : Activity() {
    private lateinit var idField: EditText
    private lateinit var passwordField: EditText
    private lateinit var recentList: LinearLayout

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        NativeSession.nativeInit(filesDir.absolutePath, "${Build.MANUFACTURER} ${Build.MODEL}".trim())
        val dp = resources.displayMetrics.density
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding((24 * dp).toInt(), (32 * dp).toInt(), (24 * dp).toInt(), (24 * dp).toInt())
        }
        column.addView(ImageView(this).apply { setImageResource(R.mipmap.ic_launcher) },
            LinearLayout.LayoutParams((88 * dp).toInt(), (88 * dp).toInt()).apply { gravity = Gravity.CENTER_HORIZONTAL })
        column.addView(TextView(this).apply {
            text = getString(R.string.app_name); textSize = 26f; typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER; setPadding(0, (12 * dp).toInt(), 0, 0)
        })
        column.addView(TextView(this).apply {
            text = getString(R.string.subtitle); gravity = Gravity.CENTER; setTextColor(Color.GRAY)
            setPadding(0, (4 * dp).toInt(), 0, (24 * dp).toInt())
        })
        idField = EditText(this).apply {
            hint = getString(R.string.partner_id); inputType = InputType.TYPE_CLASS_NUMBER; textSize = 20f
            imeOptions = EditorInfo.IME_ACTION_NEXT; isSingleLine = true
        }
        passwordField = EditText(this).apply {
            hint = getString(R.string.password); textSize = 20f; isSingleLine = true
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            imeOptions = EditorInfo.IME_ACTION_GO
            setOnEditorActionListener { _, action, _ -> (action == EditorInfo.IME_ACTION_GO).also { if (it) connect() } }
        }
        column.addView(idField)
        column.addView(passwordField)
        column.addView(Button(this).apply {
            text = getString(R.string.connect); textSize = 18f
            setOnClickListener { connect() }
        }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
            .apply { topMargin = (12 * dp).toInt() })
        recentList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(0, (24 * dp).toInt(), 0, 0) }
        column.addView(recentList)
        column.addView(TextView(this).apply {
            text = getString(R.string.author); gravity = Gravity.CENTER; setTextColor(Color.GRAY); textSize = 12f
            setPadding(0, (32 * dp).toInt(), 0, 0)
        })
        setContentView(ScrollView(this).apply { addView(column) })
    }

    override fun onResume() {
        super.onResume()
        showRecent()
    }

    private fun connect() {
        val id = idField.text.toString().filter { !it.isWhitespace() }
        val password = passwordField.text.toString()
        if (id.isEmpty() || !id.all { it.isDigit() } || password.isEmpty()) {
            Toast.makeText(this, R.string.enter_id_password, Toast.LENGTH_SHORT).show()
            return
        }
        remember(id)
        startActivity(Intent(this, SessionActivity::class.java)
            .putExtra(SessionActivity.EXTRA_ID, id).putExtra(SessionActivity.EXTRA_PASSWORD, password))
    }

    private fun recentIds(): List<String> =
        getPreferences(MODE_PRIVATE).getString(RECENT_KEY, "").orEmpty().split(',').filter { it.isNotEmpty() }

    private fun remember(id: String) {
        val ids = (listOf(id) + recentIds().filter { it != id }).take(5)
        getPreferences(MODE_PRIVATE).edit().putString(RECENT_KEY, ids.joinToString(",")).apply()
    }

    private fun showRecent() {
        recentList.removeAllViews()
        val ids = recentIds()
        if (ids.isEmpty()) return
        recentList.addView(TextView(this).apply { text = getString(R.string.recent); setTextColor(Color.GRAY) })
        for (id in ids) {
            recentList.addView(Button(this, null, android.R.attr.borderlessButtonStyle).apply {
                text = id.chunked(3).joinToString(" "); textSize = 18f; gravity = Gravity.START or Gravity.CENTER_VERTICAL
                setOnClickListener { idField.setText(id); passwordField.requestFocus() }
            })
        }
    }

    private companion object {
        const val RECENT_KEY = "recentIds"
    }
}
