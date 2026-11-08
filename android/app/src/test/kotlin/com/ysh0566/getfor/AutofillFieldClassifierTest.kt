package com.ysh0566.getfor

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AutofillFieldClassifierTest {
    @Test
    fun `recognizes common html login attributes`() {
        assertEquals(
            AutofillFieldKind.USERNAME,
            classifyAutofillField(
                hints = emptyList(),
                idEntry = "",
                htmlAttributes = listOf("autocomplete" to "username", "type" to "text"),
                passwordInput = false,
                emailInput = false,
            ),
        )
        assertEquals(
            AutofillFieldKind.PASSWORD,
            classifyAutofillField(
                hints = emptyList(),
                idEntry = "",
                htmlAttributes = listOf("autocomplete" to "current-password", "type" to "password"),
                passwordInput = false,
                emailInput = false,
            ),
        )
        assertEquals(
            AutofillFieldKind.USERNAME,
            classifyAutofillField(
                hints = emptyList(),
                idEntry = "",
                htmlAttributes = listOf("name" to "login_email", "type" to "text"),
                passwordInput = false,
                emailInput = false,
            ),
        )
        assertEquals(
            AutofillFieldKind.PASSWORD,
            classifyAutofillField(
                hints = emptyList(),
                idEntry = "",
                htmlAttributes = listOf("autocomplete" to "username", "type" to "password"),
                passwordInput = false,
                emailInput = false,
            ),
        )
        assertNull(
            classifyAutofillField(
                hints = emptyList(),
                idEntry = "",
                htmlAttributes = listOf("autocomplete" to "one-time-code"),
                passwordInput = false,
                emailInput = false,
            ),
        )
        assertNull(
            classifyAutofillField(
                hints = emptyList(),
                idEntry = "",
                htmlAttributes = listOf("name" to "username", "type" to "hidden"),
                passwordInput = false,
                emailInput = false,
            ),
        )
    }
}
