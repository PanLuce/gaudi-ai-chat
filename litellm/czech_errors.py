"""Czech messages for the errors a staff member sees in Open WebUI.

LiteLLM calls the failure hook for every rejected request, including budget checks during
authentication. The hook replaces the English message, which can hold the person's e-mail and
LiteLLM internals, with a Czech sentence and a short code the admin can find in the LiteLLM log.
The original exception is still logged by LiteLLM unchanged.
"""

from datetime import datetime

from fastapi import HTTPException
import litellm
from litellm.integrations.custom_logger import CustomLogger

PERSONAL_BUDGET = "rozpocet"


def format_usd(amount: float) -> str:
    """5.0 -> "5 $", 7.5 -> "7,50 $" (Czech decimal comma)."""
    if float(amount).is_integer():
        return f"{int(amount)} $"
    return f"{amount:.2f}".replace(".", ",") + " $"


def format_day(moment: datetime) -> str:
    """Budgets reset at midnight UTC, so the UTC day is also the Prague day: "1. 12. 2026"."""
    return f"{moment.day}. {moment.month}. {moment.year}"


def personal_budget_message(max_budget: float, reset_at: datetime | None) -> str:
    reset = f"Rozpočet se obnoví {format_day(reset_at)}. " if reset_at else ""
    return (
        "Tvůj rozpočet na AI chat je vyčerpaný. "
        f"Za posledních 30 dní je využitý celých {format_usd(max_budget)}. "
        f"{reset}Pokud potřebuješ víc dřív, napiš správci."
    )


def is_personal_budget(exc: Exception) -> bool:
    return isinstance(exc, litellm.BudgetExceededError) and getattr(exc, "entity_type", None) == "end_user"


def czech_message(exc: Exception, reset_at: datetime | None = None) -> tuple[str, str] | None:
    """Returns (code, Czech text) for an error a person can see, or None to keep the original."""
    if is_personal_budget(exc):
        return PERSONAL_BUDGET, personal_budget_message(exc.max_budget, reset_at)
    return None


async def personal_budget_reset_at(end_user_id: str | None) -> datetime | None:
    """The reset date of the person's budget: their own budget, else the default staff budget.

    Reads LiteLLM's database through the proxy's own client. If that ever fails (e.g. after an
    upgrade), the message goes out without the date; scripts/smoke.sh fails on exactly that.
    """
    from litellm.proxy.proxy_server import prisma_client

    if prisma_client is None or not end_user_id:
        return None
    end_user = await prisma_client.db.litellm_endusertable.find_unique(where={"user_id": end_user_id})
    budget_id = (end_user.budget_id if end_user else None) or litellm.max_end_user_budget_id
    if not budget_id:
        return None
    budget = await prisma_client.db.litellm_budgettable.find_unique(where={"budget_id": budget_id})
    return budget.budget_reset_at if budget else None


def with_code(code: str, text: str) -> str:
    return f"{text} (kód: {code})"


class CzechErrors(CustomLogger):
    async def async_post_call_failure_hook(
        self, request_data, original_exception, user_api_key_dict, traceback_str=None
    ):
        reset_at = None
        if is_personal_budget(original_exception):
            try:
                reset_at = await personal_budget_reset_at(getattr(original_exception, "entity_id", None))
            except Exception:  # noqa: BLE001  # the message must go out even if the lookup breaks
                reset_at = None
        translated = czech_message(original_exception, reset_at)
        if translated is None:
            return None
        code, text = translated
        status = getattr(original_exception, "status_code", None) or 500
        return HTTPException(status_code=status, detail=with_code(code, text))


czech_errors = CzechErrors()
