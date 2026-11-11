# Open WebUI pro Školu Gaudi

AI chat pro zaměstnance: Open WebUI → LiteLLM (rozpočty, útrata) → Anthropic. Lokálně běží
stejná sestava jako v produkci; liší se jen hodnoty v `.env`.

## Spuštění

1. `cp .env.example .env` a vyplň `LITELLM_MASTER_KEY`, `OPEN_TERMINAL_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`.
2. `scripts/bootstrap.sh` — vygeneruje chybějící hesla, spustí stack, založí klíč Open WebUI v LiteLLM.
3. Otevři `http://localhost:3000`, zaregistruj se (první účet je admin). Rozhraní je česky; pokud
   prohlížeč pamatuje jiný jazyk z dřívějška, přepni ho v Nastavení → Obecné → Jazyk.
4. **Admin API key:** Nastavení → Účet → API klíče → vytvořit, uložit do `.env` jako
   `OPENWEBUI_ADMIN_API_KEY`. Nová databáze = nový klíč.
5. Znovu `scripts/bootstrap.sh` (nastaví připojení Open WebUI → LiteLLM) a `scripts/smoke.sh`.

## Skripty

| Skript | Co dělá |
|---|---|
| `scripts/bootstrap.sh` | Uvede stack do nakonfigurovaného stavu; lze spouštět opakovaně. |
| `scripts/smoke.sh` | Ověří běžící stack přes porty, které používají lidé. Zdarma. |
| `scripts/smoke.sh --paid` | Navíc ověří skutečné odpovědi modelů (1 malý placený požadavek na kontrolu). **Musí projít, než službu začne někdo používat.** |

## Adresy

| Co | Kde |
|---|---|
| Open WebUI | `http://localhost:3000` |
| LiteLLM admin UI (útrata, klíče) | `http://127.0.0.1:4000/ui`, uživatel `admin`, heslo `LITELLM_UI_PASSWORD` v `.env` |

## Dokumenty

- `docs/google-oauth-setup.md` — návod pro správce Google Workspace školy (OAuth klient pro přihlášení).
- `docs/adr/` — zaznamenaná rozhodnutí.

## Modely

`claude-haiku` (výchozí), `claude-sonnet`, `claude-opus` — mapování v `litellm/config.yaml`,
názvy a pořadí v Open WebUI v `scripts/bootstrap.sh` (`STAFF_TEXT_MODELS`). Bootstrap je zveřejní všem
přihlášeným; bez toho by je Open WebUI ukázalo jen adminům. Tyto tři modely spravuje **jen bootstrap** —
úpravy v UI (popis, ikona, systémový prompt) další běh přepíše; měň je v `STAFF_TEXT_MODELS`.

## Obrázky

Tlačítko pro obrázek v chatu volá přes LiteLLM model `gemini-image` (`gemini/gemini-3.1-flash-image`,
~$0.045 za obrázek). Gemini API musí běžet v placené úrovni (Google pak nepoužívá data k tréninku).
Obrázky se počítají do stejných rozpočtů jako text. Kdo je přes rozpočet, uvidí u obrázku jen obecnou
chybu „Unprocessable Content“ — Open WebUI důvod u obrázků neukazuje; důvod je v LiteLLM UI → Logs.

## Rozpočty

- **Na osobu:** $5 / 30 dní (`staff-monthly`, `scripts/lib.sh`). Open WebUI posílá e-mail přihlášeného,
  LiteLLM podle něj počítá útratu. Kdo rozpočet vyčerpá, dostane v chatu chybu `ExceededBudget`.
  Útrata a rozpočty lidí: LiteLLM UI → *Customers*.
- **Celá instance:** klíč Open WebUI v LiteLLM má strop $100 / 30 dní.
- **U poskytovatele:** měsíční limit workspace `openwebui` v console.anthropic.com.
