package io.github.hientrannt.hmacviewer

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast

/** Connection form: UltraViewer ID, or a VNC/RDP address, with recent targets. */
class MainActivity : Activity() {
    private lateinit var protocolGroup: RadioGroup
    private lateinit var targetField: EditText
    private lateinit var userField: EditText
    private lateinit var passwordField: EditText
    private lateinit var recentList: LinearLayout
    private var protocol = Protocol.ULTRAVIEWER

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
            setPadding(0, (4 * dp).toInt(), 0, (20 * dp).toInt())
        })
        protocolGroup = RadioGroup(this).apply { orientation = RadioGroup.HORIZONTAL; gravity = Gravity.CENTER_HORIZONTAL }
        for (p in Protocol.entries) {
            protocolGroup.addView(RadioButton(this).apply {
                id = View.generateViewId(); text = p.label; tag = p; isChecked = p == protocol
                setPadding(0, 0, (12 * dp).toInt(), 0)
            })
        }
        protocolGroup.setOnCheckedChangeListener { group, checked ->
            protocol = group.findViewById<RadioButton>(checked).tag as Protocol
            updateFields()
        }
        column.addView(protocolGroup)
        targetField = EditText(this).apply { textSize = 20f; imeOptions = EditorInfo.IME_ACTION_NEXT; isSingleLine = true }
        userField = EditText(this).apply {
            hint = getString(R.string.user_name); textSize = 20f; isSingleLine = true
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            imeOptions = EditorInfo.IME_ACTION_NEXT
        }
        passwordField = EditText(this).apply {
            hint = getString(R.string.password); textSize = 20f; isSingleLine = true
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            imeOptions = EditorInfo.IME_ACTION_GO
            setOnEditorActionListener { _, action, _ -> (action == EditorInfo.IME_ACTION_GO).also { if (it) connect() } }
        }
        column.addView(targetField)
        column.addView(userField)
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
        updateFields()
    }

    override fun onResume() {
        super.onResume()
        showRecent()
    }

    private fun updateFields() {
        targetField.hint = getString(if (protocol == Protocol.ULTRAVIEWER) R.string.partner_id else R.string.address_hint)
        targetField.inputType = if (protocol == Protocol.ULTRAVIEWER) InputType.TYPE_CLASS_NUMBER
            else InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
        userField.visibility = if (protocol == Protocol.RDP) View.VISIBLE else View.GONE
    }

    private fun connect() {
        val target = targetField.text.toString().trim()
        val password = passwordField.text.toString()
        val user = userField.text.toString().trim()
        val valid = when (protocol) {
            Protocol.ULTRAVIEWER -> target.filter { !it.isWhitespace() }.let { it.isNotEmpty() && it.all(Char::isDigit) } && password.isNotEmpty()
            Protocol.VNC -> target.isNotEmpty()
            Protocol.RDP -> target.isNotEmpty() && user.isNotEmpty()
        }
        if (!valid) {
            Toast.makeText(this, if (protocol == Protocol.ULTRAVIEWER) R.string.enter_id_password else R.string.enter_address,
                Toast.LENGTH_SHORT).show()
            return
        }
        val entry = Recent(protocol, if (protocol == Protocol.ULTRAVIEWER) target.filter { !it.isWhitespace() } else target, user)
        remember(entry)
        startActivity(Intent(this, SessionActivity::class.java)
            .putExtra(SessionActivity.EXTRA_PROTOCOL, protocol.code)
            .putExtra(SessionActivity.EXTRA_ID, entry.target)
            .putExtra(SessionActivity.EXTRA_USER, user)
            .putExtra(SessionActivity.EXTRA_PASSWORD, password))
    }

    /** A recent target; old entries stored as bare IDs are UltraViewer ones. */
    private data class Recent(val protocol: Protocol, val target: String, val user: String) {
        fun encode() = "${protocol.code}|$target|$user"

        companion object {
            fun decode(text: String): Recent? {
                val parts = text.split('|')
                if (parts.size == 1) return parts[0].takeIf { it.isNotEmpty() }?.let { Recent(Protocol.ULTRAVIEWER, it, "") }
                val protocol = Protocol.entries.firstOrNull { it.code == parts[0].toIntOrNull() } ?: return null
                return Recent(protocol, parts.getOrElse(1) { "" }, parts.getOrElse(2) { "" })
            }
        }
    }

    private fun recent(): List<Recent> = getPreferences(MODE_PRIVATE).getString(RECENT_KEY, "").orEmpty()
        .split(',').mapNotNull(Recent::decode)

    private fun remember(entry: Recent) {
        val list = (listOf(entry) + recent().filter { it != entry }).take(8)
        getPreferences(MODE_PRIVATE).edit().putString(RECENT_KEY, list.joinToString(",") { it.encode() }).apply()
    }

    private fun showRecent() {
        recentList.removeAllViews()
        val list = recent()
        if (list.isEmpty()) return
        recentList.addView(TextView(this).apply { text = getString(R.string.recent); setTextColor(Color.GRAY) })
        for (entry in list) {
            val shown = if (entry.protocol == Protocol.ULTRAVIEWER) entry.target.chunked(3).joinToString(" ") else entry.target
            recentList.addView(Button(this, null, android.R.attr.borderlessButtonStyle).apply {
                text = "${entry.protocol.label} · $shown" + if (entry.user.isNotEmpty()) " (${entry.user})" else ""
                textSize = 16f; isAllCaps = false; gravity = Gravity.START or Gravity.CENTER_VERTICAL
                setOnClickListener {
                    protocolGroup.check((0 until protocolGroup.childCount).map { protocolGroup.getChildAt(it) }
                        .first { it.tag == entry.protocol }.id)
                    targetField.setText(entry.target); userField.setText(entry.user)
                    passwordField.text.clear(); passwordField.requestFocus()
                }
            })
        }
    }

    private companion object {
        const val RECENT_KEY = "recentIds"
    }
}

/** Connection protocols; `code` is what the native layer and recents store. */
enum class Protocol(val code: Int, val label: String) {
    ULTRAVIEWER(0, "UltraViewer"), VNC(1, "VNC"), RDP(2, "RDP"),
}
