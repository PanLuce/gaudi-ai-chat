"""What a person sees when LiteLLM rejects a request, tested at the hook LiteLLM calls for it.

Runs inside the LiteLLM image from docker-compose.yml (scripts/check-czech-errors.sh), so a new LiteLLM
version that changes its exception classes fails here before it reaches the server. Standard library
only: the image has no pytest. No network, no database, free.
"""

import asyncio
import re
import unittest
from datetime import datetime

import httpx
import litellm
from fastapi import HTTPException

from czech_errors import czech_errors, czech_message

EMAIL = "ucitel@skolagaudi.cz"
FORBIDDEN = httpx.Response(403, request=httpx.Request("POST", "https://provider"))


def rejected(exc: Exception) -> HTTPException:
    """The answer Open WebUI gets for a request LiteLLM rejected with exc."""
    return asyncio.run(czech_errors.async_post_call_failure_hook({}, exc, None))


def code_of(detail: str) -> str | None:
    """"… (kód: rozpocet)" -> "rozpocet"; the code is how the admin finds the error in the LiteLLM log."""
    found = re.search(r"\(kód: ([a-z-]+)\)$", detail)
    return found.group(1) if found else None


def personal_budget(max_budget: float) -> litellm.BudgetExceededError:
    return litellm.BudgetExceededError(
        current_cost=max_budget + 0.2, max_budget=max_budget, entity_type="end_user", entity_id=EMAIL
    )


class ProviderErrors(unittest.TestCase):
    CASES = [
        ("pretizeno", litellm.RateLimitError("rate limited", "anthropic", "claude")),
        ("pretizeno", litellm.ServiceUnavailableError("unavailable", "anthropic", "claude")),
        ("pretizeno", litellm.InternalServerError("AnthropicException - Overloaded", "anthropic", "claude")),
        ("cas", litellm.Timeout("timed out", "claude", "anthropic")),
        ("dlouha-konverzace", litellm.ContextWindowExceededError("prompt is too long", "claude", "anthropic")),
        ("odmitnuto", litellm.ContentPolicyViolationError("blocked", "claude", "anthropic")),
        ("nastaveni", litellm.AuthenticationError("invalid x-api-key", "anthropic", "claude")),
        ("nastaveni", litellm.PermissionDeniedError("no access", "anthropic", "claude", FORBIDDEN)),
        ("nastaveni", litellm.NotFoundError("model not found", "claude", "anthropic")),
        ("jina", litellm.BadRequestError("max_tokens is too large", "claude", "anthropic")),
        ("jina", litellm.APIConnectionError("connection reset", "anthropic", "claude")),
        ("jina", ValueError("anything else")),
    ]

    def test_every_kind_of_provider_error_gets_a_czech_message_with_its_code(self):
        for code, exc in self.CASES:
            with self.subTest(error=type(exc).__name__, code=code):
                self.assertEqual(code_of(rejected(exc).detail), code)


class Budgets(unittest.TestCase):
    def test_a_person_over_budget_learns_how_much_they_used_without_their_email(self):
        detail = rejected(personal_budget(5)).detail
        self.assertIn("Tvůj rozpočet na AI chat je vyčerpaný", detail)
        self.assertIn("využitý celých 5 $", detail)
        self.assertEqual(code_of(detail), "rozpocet")
        self.assertNotIn(EMAIL, detail)

    def test_a_budget_with_cents_is_written_with_a_czech_decimal_comma(self):
        _, text = czech_message(personal_budget(7.5))
        self.assertIn("využitý celých 7,50 $", text)

    def test_the_message_says_on_which_day_the_budget_resets(self):
        _, text = czech_message(personal_budget(5), reset_at=datetime(2026, 12, 1))
        self.assertIn("Rozpočet se obnoví 1. 12. 2026.", text)

    def test_when_the_school_budget_runs_out_people_are_sent_to_the_admin(self):
        exc = litellm.BudgetExceededError(current_cost=101, max_budget=100, entity_type="key", entity_id="hash")
        detail = rejected(exc).detail
        self.assertIn("vyčerpaný rozpočet celé školy", detail)
        self.assertEqual(code_of(detail), "rozpocet-skoly")


if __name__ == "__main__":
    unittest.main()
