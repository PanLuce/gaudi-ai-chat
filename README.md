# Open WebUI pro Školu Gaudi

AI chat pro zaměstnance: Open WebUI → LiteLLM (rozpočty, útrata) → Anthropic. Lokálně běží
stejná sestava jako v produkci; liší se jen hodnoty v `.env`.

## Spuštění

1. `cp .env.example .env` a vyplň `LITELLM_MASTER_KEY`, `OPEN_TERMINAL_API_KEY`, `ANTHROPIC_API_KEY`.
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

## Modely

`claude-haiku` (výchozí), `claude-sonnet`, `claude-opus` — mapování v `litellm/config.yaml`.
Klíč Open WebUI v LiteLLM má strop $100 / 30 dní pro celou instanci.
