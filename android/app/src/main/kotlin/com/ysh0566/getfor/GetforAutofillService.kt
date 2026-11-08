package com.ysh0566.getfor

import android.app.PendingIntent
import android.app.assist.AssistStructure
import android.content.Intent
import android.os.CancellationSignal
import android.service.autofill.AutofillService
import android.service.autofill.Dataset
import android.service.autofill.FillCallback
import android.service.autofill.FillRequest
import android.service.autofill.FillResponse
import android.service.autofill.SaveCallback
import android.service.autofill.SaveRequest
import android.text.InputType
import android.view.autofill.AutofillId
import android.view.autofill.AutofillValue
import android.widget.RemoteViews

class GetforAutofillService : AutofillService() {
    override fun onFillRequest(
        request: FillRequest,
        cancellationSignal: CancellationSignal,
        callback: FillCallback,
    ) {
        val context = request.fillContexts.lastOrNull()
        val fields = context?.let { AutofillFields.from(it.structure, it.focusedId) }
        if (fields == null || fields.ids.isEmpty()) {
            callback.onSuccess(null)
            return
        }

        val authentication = PendingIntent.getActivity(
            this,
            AUTH_REQUEST_CODE,
            Intent(this, AutofillAuthenticationActivity::class.java)
                .putExtra(AutofillAuthenticationActivity.EXTRA_FOCUSED_ID, context?.focusedId),
            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_MUTABLE,
        )
        val presentation = RemoteViews(packageName, android.R.layout.simple_list_item_1).apply {
            setTextViewText(android.R.id.text1, "解锁 Getfor")
        }
        callback.onSuccess(
            FillResponse.Builder()
                // The platform injects the AssistStructure into this mutable authentication intent.
                .setAuthentication(fields.ids, authentication.intentSender, presentation)
                .build(),
        )
    }

    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) {
        // Credential Manager remains the single save path; legacy Autofill only supplies fills.
        callback.onSuccess()
    }

    private companion object {
        const val AUTH_REQUEST_CODE = 0x415554
    }
}

internal data class AutofillFields(
    val username: AutofillId?,
    val password: AutofillId?,
    val target: CredentialTarget,
    val usernamePrefix: String,
) {
    val ids: Array<AutofillId>
        get() = listOfNotNull(username, password).distinct().toTypedArray()

    fun response(records: List<StoredCredential>, packageName: String): FillResponse? {
        val response = FillResponse.Builder()
        var count = 0
        val candidates = target.filter(records)
        val passwordCandidates = target.filter(candidates, usernamePrefix).map { it.id }.toSet()
        candidates.forEach { record ->
            // simple_list_item_2 uses TwoLineListItem, which RemoteViews cannot inflate.
            val presentation = RemoteViews(packageName, android.R.layout.simple_list_item_1).apply {
                setTextViewText(
                    android.R.id.text1,
                    "${record.title.ifEmpty { record.website }} — ${record.username}",
                )
            }
            val dataset = Dataset.Builder()
            var hasValue = false
            if (username != null && record.username.isNotEmpty()) {
                dataset.setValue(username, AutofillValue.forText(record.username), presentation)
                hasValue = true
            }
            if (password != null && record.password.isNotEmpty()) {
                // Keep all username datasets so Android can restore matches as the user erases text.
                // Password suggestions use the supplied username, never the secret's characters.
                val value = AutofillValue.forText(record.password)
                if (record.id in passwordCandidates) {
                    dataset.setValue(password, value, null, presentation)
                } else {
                    // A regex alone cannot hide unmatched accounts when the password field is empty.
                    dataset.setValue(password, value)
                }
                hasValue = true
            }
            if (hasValue) {
                response.addDataset(dataset.setId(record.id).build())
                count++
            }
        }
        return if (count == 0) null else response.build()
    }

    companion object {
        fun from(structure: AssistStructure, focusedId: AutofillId? = null): AutofillFields? {
            data class Field(
                val id: AutofillId,
                val kind: AutofillFieldKind,
                val domain: String?,
                val focused: Boolean,
                val value: String,
            )
            val fields = mutableListOf<Field>()

            fun visit(node: AssistStructure.ViewNode, inheritedDomain: String? = null) {
                val domain = node.webDomain ?: inheritedDomain
                val id = node.autofillId
                if (id != null) {
                    val hints = node.autofillHints.orEmpty().map(String::lowercase)
                    val idEntry = node.idEntry?.lowercase().orEmpty()
                    val htmlAttributes = node.htmlInfo?.attributes.orEmpty().map {
                        it.first.orEmpty() to it.second.orEmpty()
                    }
                    val kind = classifyAutofillField(
                        hints = hints,
                        idEntry = idEntry,
                        htmlAttributes = htmlAttributes,
                        passwordInput = node.isPasswordField(),
                        emailInput = node.isEmailField(),
                    )
                    if (kind != null) {
                        fields += Field(
                            id, kind, domain, id == focusedId || node.isFocused,
                            if (kind == AutofillFieldKind.USERNAME) {
                                node.autofillValue?.takeIf { it.isText }?.textValue?.toString().orEmpty()
                            } else "",
                        )
                    }
                }
                for (index in 0 until node.childCount) visit(node.getChildAt(index), domain)
            }

            for (index in 0 until structure.windowNodeCount) {
                visit(structure.getWindowNodeAt(index).rootViewNode)
            }
            val focused = fields.firstOrNull { it.focused } ?: fields.firstOrNull() ?: return null
            // A page may contain cross-origin frames; use only the focused form's domain.
            val scoped = fields.filter { it.domain == focused.domain }
            val username = scoped.firstOrNull { it.kind == AutofillFieldKind.USERNAME && it.focused }
                ?: scoped.firstOrNull { it.kind == AutofillFieldKind.USERNAME }
            val password = scoped.firstOrNull { it.kind == AutofillFieldKind.PASSWORD && it.focused }
                ?: scoped.firstOrNull { it.kind == AutofillFieldKind.PASSWORD }
            return AutofillFields(
                username?.id,
                password?.id,
                CredentialTarget(structure.activityComponent.packageName, focused.domain),
                username?.value.orEmpty(),
            )
        }

        private fun AssistStructure.ViewNode.isPasswordField(): Boolean {
            val variation = inputType and InputType.TYPE_MASK_VARIATION
            return when (inputType and InputType.TYPE_MASK_CLASS) {
                InputType.TYPE_CLASS_TEXT -> variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                    variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
                    variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD
                InputType.TYPE_CLASS_NUMBER -> variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
                else -> false
            }
        }

        private fun AssistStructure.ViewNode.isEmailField(): Boolean {
            val variation = inputType and InputType.TYPE_MASK_VARIATION
            return variation == InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS ||
                variation == InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS
        }
    }
}

internal enum class AutofillFieldKind { USERNAME, PASSWORD }

internal fun classifyAutofillField(
    hints: List<String>,
    idEntry: String,
    htmlAttributes: List<Pair<String, String>>,
    passwordInput: Boolean,
    emailInput: Boolean,
): AutofillFieldKind? {
    val normalizedHints = hints.map { it.trim().lowercase() }
    if (passwordInput || normalizedHints.any { it in passwordHints }) {
        return AutofillFieldKind.PASSWORD
    }

    val attributes = htmlAttributes.associate { (name, value) ->
        name.trim().lowercase() to value.trim().lowercase()
    }
    val type = attributes["type"].orEmpty()
    if (type == "hidden") return null
    val autocomplete = attributes["autocomplete"]
        .orEmpty()
        .split(Regex("\\s+"))
        .filter(String::isNotEmpty)
    val identifiers = listOf(
        idEntry.lowercase(),
        attributes["id"].orEmpty(),
        attributes["name"].orEmpty(),
    )

    // Password wins when attributes conflict, preventing a secret from entering a username field.
    if (type == "password" || autocomplete.any { it in htmlPasswordTokens } ||
        identifiers.any { identifier -> passwordIdentifiers.any(identifier::contains) }
    ) {
        return AutofillFieldKind.PASSWORD
    }
    if (emailInput || normalizedHints.any { it in usernameHints } || type == "email" ||
        autocomplete.any { it in htmlUsernameTokens } ||
        identifiers.any { identifier -> usernameIdentifiers.any(identifier::contains) }
    ) {
        return AutofillFieldKind.USERNAME
    }
    return null
}

private val usernameHints = setOf("username", "emailaddress")
private val passwordHints = setOf("password", "passwordauto", "newpassword")
private val htmlUsernameTokens = setOf("username", "email")
private val htmlPasswordTokens = setOf("current-password", "new-password")
private val usernameIdentifiers = setOf("username", "user_name", "userid", "user_id", "email", "login")
private val passwordIdentifiers = setOf("password", "passwd", "passcode", "user_pass", "pwd")
