package com.ysh0566.getfor

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CredentialTargetTest {
    private fun record(
        id: String,
        website: String,
        username: String = "alice@example.com",
        password: String = "test-password",
    ) = StoredCredential(id, id, website, username, password, emptyList())

    @Test
    fun `website matches normalize scheme case www paths and trailing dots`() {
        val target = CredentialTarget("com.android.chrome", "login.example.com")
        assertTrue(target.matches("https://LOGIN.EXAMPLE.COM:443/sign-in?q=1"))
        assertTrue(target.matches("login.example.com."))
        assertTrue(CredentialTarget("browser", "www.example.com").matches("https://example.com/login"))
        assertTrue(CredentialTarget("browser", "127.0.0.1").matches("http://127.0.0.1:8765"))
    }

    @Test
    fun `website filtering excludes unrelated hosts and deceptive suffixes`() {
        val target = CredentialTarget("com.android.chrome", "example.com")
        for (website in listOf(
            "other.test", "example.com.evil.test", "notexample.com", "https://example.com@evil.test",
            "https://evil.test/example.com", "com.android.chrome", "", "https://", "androidapp://example.com",
        )) {
            assertFalse(website, target.matches(website))
        }
        assertFalse(CredentialTarget("browser", "one.co.uk").matches("two.co.uk"))
        assertFalse(CredentialTarget("browser", "team-a.example.com").matches("team-b.example.com"))
        assertFalse(CredentialTarget("browser", "").matches("example.com"))
    }

    @Test
    fun `native apps match their package only`() {
        val target = CredentialTarget("com.example.app")
        assertTrue(target.matches("com.example.app"))
        assertTrue(target.matches("androidapp://com.example.app/"))
        assertFalse(target.matches("com.example.other"))
        assertFalse(target.matches("https://com.example.app"))
        assertFalse(target.matches("example.com"))
        assertFalse(target.matches("Example App"))
        assertFalse(CredentialTarget("").matches(""))
    }

    @Test
    fun `only site passwords matching the entered username prefix are returned`() {
        val records = listOf(
            record("alice", "example.com", "Alice@example.com"),
            record("bob", "https://www.example.com/login", "bob@example.com"),
            record("foreign-alice", "unrelated.test", "Alice@example.com"),
            record("passkey-only", "example.com", password = ""),
            record("missing-site", "", "Alice@example.com"),
        )
        val target = CredentialTarget("browser", "example.com")
        assertEquals(listOf("alice", "bob"), target.filter(records).map { it.id })
        assertEquals(listOf("alice"), target.filter(records, "ALI").map { it.id })
        assertEquals(listOf("bob"), target.filter(records, "bob@").map { it.id })
        assertTrue(target.filter(records, "unknown").isEmpty())
        assertEquals(listOf("alice", "bob"), target.filter(records, "").map { it.id })
        assertTrue(CredentialTarget("browser", "no-match.test").filter(records).isEmpty())
    }

    @Test
    fun `malformed domains do not match`() {
        for (value in listOf("", " ", "https://", "https://[invalid", "file:///etc/passwd", "https://bad host")) {
            assertNull(credentialDomain(value))
        }
    }
}
