# Open WebUI pro Školu Gaudi

AI chat pro zaměstnance: Caddy → Open WebUI → LiteLLM (rozpočty, útrata) → Anthropic / Gemini. Lokálně běží
stejná sestava jako v produkci; liší se jen hodnoty v `.env`.

## Spuštění

1. `cp .env.example .env` a vyplň `LITELLM_MASTER_KEY`, `OPEN_TERMINAL_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`.
2. `scripts/bootstrap.sh` — vygeneruje chybějící hesla, spustí stack, založí klíč Open WebUI v LiteLLM.
3. Otevři `http://localhost`, zaregistruj se (první účet je admin). Rozhraní je česky; pokud
   prohlížeč pamatuje jiný jazyk z dřívějška, přepni ho v Nastavení → Obecné → Jazyk.
4. **Admin API key:** Nastavení → Účet → API klíče → vytvořit, uložit do `.env` jako
   `OPENWEBUI_ADMIN_API_KEY`. Nová databáze = nový klíč.
5. Znovu `scripts/bootstrap.sh` (nastaví připojení Open WebUI → LiteLLM) a `scripts/smoke.sh`.

## Skripty

| Skript | Co dělá |
|---|---|
| `scripts/bootstrap.sh` | Uvede stack do nakonfigurovaného stavu; lze spouštět opakovaně. |
| `scripts/smoke.sh` | Ověří běžící stack přes porty, které používají lidé. Zdarma. |
| `scripts/demo-staff.sh` | Ruční ukázka: dočasný účet běžného uživatele — co vidí zaměstnanec (modely, terminál, obrázky); po Enteru se smaže. Zdarma. |
| `scripts/demo-over-budget.sh` | Ruční ukázka: dočasný účet přes rozpočet, vyzkoušíš v prohlížeči, po Enteru se smaže. Zdarma. |
| `scripts/check-bootstrap-secrets.sh` | Ověří, že bootstrap na čerstvém `.env` z `.env.example` vygeneruje všechna hesla. Skutečný `.env` nemění. |
| `scripts/backup.sh` | Záloha obou databází a souborů Open WebUI do `backups/<čas>/`, drží posledních 14. |
| `scripts/restore.sh <adresář>` | Obnova ze zálohy; vše od zálohy se ztratí (ptá se, `--yes` bez ptaní). Nejdřív celou zálohu přečte nanečisto — poškozenou odmítne a nic nezmění — a uloží aktuální stav jako další zálohu, takže jde vrátit i obnova. |
| `scripts/check-backup-restore.sh` | Ověří, že záloha vrátí smazaný chat, soubor i útratu a že poškozenou zálohu obnova odmítne. **Ne na serveru v provozu** — obnova vrací databáze do okamžiku zálohy. Zdarma. |
| `scripts/smoke.sh --paid` | Navíc ověří skutečné odpovědi modelů (1 malý placený požadavek na kontrolu). **Musí projít, než službu začne někdo používat.** |

## Adresy

| Co | Kde |
|---|---|
| Open WebUI (přes Caddy) | `http://localhost` — jediný vstup; Open WebUI samo žádný port na hostu nemá |
| LiteLLM admin UI (útrata, klíče) | `http://127.0.0.1:4000/ui`, uživatel `admin`, heslo `LITELLM_UI_PASSWORD` v `.env` |

## Dokumenty

- `docs/google-oauth-setup.md` — návod pro správce Google Workspace školy (OAuth klient pro přihlášení).
- `docs/adr/` — zaznamenaná rozhodnutí.

## Modely

`claude-haiku`, `claude-sonnet`, `claude-opus`, `gemini-image` — mapování v `litellm/config.yaml`.
Kdo který model vidí, jak se jmenuje a který je výchozí, je **konfigurace admina v UI** (Admin → Models).
Bootstrap jen při prvním startu založí výchozí stav (`INITIAL_MODELS` v `scripts/bootstrap.sh`): Haiku
(výchozí) a Sonnet pro všechny, Opus a Gemini jen pro admina. Existující nastavení nikdy nepřepíše.
Bez záznamu by Open WebUI model ukázalo jen adminům. Tlačítko obrázku funguje s kterýmkoli chat modelem;
`gemini-image` proto nemusí být ve výběru vidět.

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

## Vstup (Caddy)

Lidé přicházejí jen přes Caddy (`caddy/Caddyfile`), který přidává bezpečnostní hlavičky a předává
WebSockety (streamované odpovědi). Adresa je `WEBUI_URL` v `.env`; bootstrap ji zapíše i do Open WebUI
(odkazy, přesměrování Google přihlášení). Na serveru se mění jen `.env`:
`WEBUI_URL=https://ai.skolagaudi.cz` (Caddy si sám vyřídí certifikát Let's Encrypt) a
`PUBLIC_BIND_ADDRESS=0.0.0.0`.

## Terminál

`open-terminal` je shell na serveru. Bootstrap ho připojí do Open WebUI (adresa a klíč z `.env`); nové
připojení nemá žádná pravidla přístupu, což Open WebUI chápe jako „jen admin“. Kdo další ho smí používat,
je konfigurace admina v UI a bootstrap ji nepřepisuje. Co vidí běžný uživatel: `scripts/demo-staff.sh`.

## Zálohy

`scripts/backup.sh` uloží dump databází `openwebui` a `litellm` a soubory Open WebUI (nahrané soubory,
vektorový index; bez `cache/` se staženými modely) do `backups/<čas>/` (jen pro vlastníka, mimo git).
`.env` v záloze není — kopie patří do správce hesel, obnova na jiném serveru ji potřebuje.
Na serveru: denně z cronu a kopie mimo server (krok nasazení).
