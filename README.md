# Open WebUI pro Školu Gaudi

AI chat pro zaměstnance: Vchod (Caddy) → Chat (Open WebUI) → Brána (LiteLLM: rozpočty, útrata) →
Poskytovatelé (Anthropic, Google). Data drží Databáze (Postgres). Lokálně běží stejná sestava jako
v produkci; liší se jen hodnoty v `.env`. Nasazení na server: [docs/nasazeni.html](docs/nasazeni.html).

## Spuštění (lokálně)

1. `cp .env.example .env` a vyplň `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `WEBUI_ADMIN_EMAIL` (tvůj e-mail =
   účet správce Chatu), `LITELLM_MASTER_KEY` (`sk-` + náhodný text, např. `sk-$(openssl rand -hex 24)`)
   a `OPEN_TERMINAL_API_KEY` (`openssl rand -hex 24`).
2. `scripts/bootstrap.sh` — vygeneruje ostatní hesla (i `WEBUI_ADMIN_PASSWORD`), spustí stack a založí klíč
   Chatu v Bráně. Chat při prvním startu s prázdnou databází založí správce z `.env` a zavře registraci.
3. Otevři `http://localhost` a přihlas se jako správce (heslo `WEBUI_ADMIN_PASSWORD` v `.env`). Rozhraní je
   česky; když prohlížeč pamatuje jiný jazyk, přepni ho v Nastavení → Obecné → Jazyk.
4. **Admin API key:** Nastavení → Účet → API klíče → vytvořit, uložit do `.env` jako
   `OPENWEBUI_ADMIN_API_KEY`. Nová databáze = nový klíč.
5. Znovu `scripts/bootstrap.sh` (připojí Chat k Bráně) a `scripts/smoke.sh`.

## Skripty

Podrobnosti jsou v hlavičce každého skriptu. Všechny kontroly jsou zdarma: žádná nevolá poskytovatele.

| Skript | Co dělá |
|---|---|
| `scripts/bootstrap.sh` | Uvede stack do nakonfigurovaného stavu; lze spouštět opakovaně. |
| `scripts/smoke.sh` | Ověří běžící stack přes porty, které používají lidé. Skutečnou odpověď a obrázek zkoušíš ručně (průvodce, krok Ověř, že vše funguje). |
| `scripts/check-docs.sh` | Ověří `docs/` a README: odkazy, slovník názvů, žádná tajemství, úplné kroky průvodce. Potřebuje `node` a běžící stack. |
| `scripts/check-bootstrap-secrets.sh` | Bootstrap na čerstvém `.env` vygeneruje všechna hesla a bez `WEBUI_ADMIN_EMAIL` se zastaví. |
| `scripts/check-first-admin.sh` | Dočasný Chat s prázdnou databází: správce z `.env` se přihlásí, registrace je zavřená. |
| `scripts/backup.sh` | Záloha databází a souborů Chatu do `backups/<čas>/`, drží posledních 14. |
| `scripts/restore.sh <adresář>` | Obnova ze zálohy; vše od zálohy se ztratí, aktuální stav se nejdřív uloží jako další záloha. |
| `scripts/check-backup-restore.sh` | Záloha vrátí smazaný chat, soubor i útratu, poškozenou zálohu obnova odmítne. **Ne na serveru v provozu.** |
| `scripts/offsite.sh upload \| list \| download <čas>` | Zašifrovaná kopie záloh na Google Drive. **Zatím vypnuto (#8)**, viz [Kopie na Google Drive](#kopie-na-google-drive). |
| `scripts/check-offsite.sh` | `offsite.sh` bez nastavení řekne, co doplnit; s nastavením Drive i cesta tam a zpět. **Zatím vypnuto (#8).** |
| `scripts/demo-staff.sh` | Ruční ukázka: dočasný účet běžného uživatele (modely, terminál, obrázky); po Enteru se smaže. |
| `scripts/demo-over-budget.sh` | Ruční ukázka: dočasný účet přes rozpočet; po Enteru se smaže. |

## Adresy

| Co | Kde |
|---|---|
| Chat přes Vchod | `http://localhost` — jediný vstup; Chat sám žádný port na hostu nemá |
| Brána (LiteLLM UI: útrata, klíče) | `http://127.0.0.1:4000/ui`, uživatel `admin`, heslo `LITELLM_UI_PASSWORD` v `.env` |

## Licence

Open source pod licencí MIT ([LICENSE](LICENSE)). Škola Gaudi projekt používá se souhlasem autora; na server se
stahuje z tohoto veřejného repa bez klíče, nebo z forku školy (průvodce, krok Stáhni kód na server).

## Dokumenty

- `docs/prehled.html` — z čeho je systém, pro netechnické lidi. Názvy částí: Vchod, Chat, Brána, Databáze, Terminál, Poskytovatelé.
- `docs/nasazeni.html` — průvodce nasazením na nový server krok za krokem.
- `docs/google-oauth-setup.md` — návod pro správce Google Workspace (přihlášení přes Google; připravuje se, issue #3).
- `docs/adr/` — zaznamenaná rozhodnutí.

## Modely

`claude-haiku`, `claude-sonnet`, `claude-opus`, `gemini-image` — mapování v `litellm/config.yaml`.
Kdo který model vidí, jak se jmenuje a který je výchozí, je **konfigurace správce v Chatu** (Administrace →
Modely). Bootstrap jen poprvé založí výchozí stav (`INITIAL_MODELS` v `scripts/bootstrap.sh`): Haiku
(výchozí) a Sonnet pro všechny, Opus a Gemini jen pro správce. Existující nastavení nikdy nepřepíše.
Bez záznamu by Chat model ukázal jen správcům. Tlačítko obrázku funguje s kterýmkoli modelem, proto
`gemini-image` nemusí být ve výběru vidět.

## Obrázky

Tlačítko pro obrázek volá přes Bránu model `gemini-image` (`gemini/gemini-3.1-flash-image`, ~$0.045 za
obrázek). Gemini API musí běžet v placené úrovni (Google pak nepoužívá data k tréninku). Obrázky se
počítají do stejných rozpočtů jako text. Kdo je přes rozpočet, uvidí u obrázku jen obecnou chybu
„Unprocessable Content“ — Chat důvod u obrázků neukazuje; důvod je v LiteLLM UI → Logs.

## Rozpočty

- **Na osobu:** $5 / 30 dní (`STAFF_BUDGET_USD` v `scripts/lib.sh`). Chat posílá e-mail přihlášeného, Brána
  podle něj počítá útratu. Kdo rozpočet vyčerpá, dostane českou hlášku s datem obnovy (kód `rozpocet`).
  Útrata lidí: LiteLLM UI → *Customers*.
- **Rozpočet školy:** klíč Chatu v Bráně má strop $100 / 30 dní (`scripts/bootstrap.sh`); po vyčerpání hláška
  s kódem `rozpocet-skoly`.
- **U poskytovatelů:** měsíční limit workspace `openwebui` u Anthropicu a spend cap projektu u Googlu
  (průvodce, krok Nastav stropy u poskytovatelů).

## Chybové hlášky

Chyby z Brány vidí lidé česky; přeloží je `litellm/czech_errors.py`. Každá hláška končí kódem `(kód: …)`.
Anglický originál zůstává v logu: `docker compose logs litellm` nebo LiteLLM UI → *Logs*. U obrázků Chat
hlášku neukazuje, viz [Obrázky](#obrázky).

| Kód | Kdy |
|---|---|
| `rozpocet` | člověk vyčerpal osobní rozpočet |
| `rozpocet-skoly` | došel rozpočet klíče Chatu (celé školy) |
| `pretizeno` | poskytovatel je přetížený nebo omezuje počet dotazů |
| `cas` | odpověď nepřišla včas |
| `dlouha-konverzace` | konverzace je na model moc dlouhá |
| `odmitnuto` | poskytovatel dotaz odmítl (obsah) |
| `nastaveni` | špatný klíč, chybí přístup nebo model není v `litellm/config.yaml` |
| `jina` | cokoli jiného — důvod je v logu |

## Vchod (Caddy)

Lidé přicházejí jen přes Vchod (`caddy/Caddyfile`), který přidává bezpečnostní hlavičky a předává
WebSockety (streamované odpovědi). Adresa je `WEBUI_URL` v `.env`; bootstrap ji zapíše i do Chatu.
Hodnoty pro server jsou v průvodci (krok Vyplň .env).

## Terminál

`open-terminal` je shell na serveru. Bootstrap ho připojí do Chatu (adresa a klíč z `.env`); nové připojení
nemá žádná pravidla přístupu, což Chat chápe jako „jen správce“. Kdo další ho smí používat, je konfigurace
správce v Chatu a bootstrap ji nepřepisuje. Co vidí běžný uživatel: `scripts/demo-staff.sh`.

## Nároky na server

Naměřeno 12. 11. 2026 na běžícím stacku (`docker stats --no-stream`): Chat 712 MB, Brána 611 MB,
Databáze 83 MB, Terminál 74 MB, Vchod 16 MB — dohromady asi 1,5 GB. Stropy v `docker-compose.yml`
(`mem_limit`) dávají 4,3 GB, proto server s 8 GB RAM. Měř znovu po větší změně nebo upgradu.

## Zálohy

`scripts/backup.sh` uloží dump databází `openwebui` a `litellm` a soubory Chatu (nahrané soubory, vyhledávací
index; bez `cache/`) do `backups/<čas>/` (jen pro vlastníka, mimo git). Chat se přitom asi na 15 s zastaví
(`backup.sh` vypíše `chat stopped for N s`), aby databáze a soubory byly ze stejné chvíle. Na serveru běží
každou noc ve 2:30 UTC z cronu. `.env` v záloze není — kopie patří do správce hesel.

Zálohy zatím leží **jen na serveru**: když zmizí server, zmizí i ony (kopie na Google Drive je vypnutá, viz níže).
**Obnova je na serveru zatím nevyzkoušená.** Průvodce (krok Zapni noční zálohu) proto doporučuje ji při nasazení
zkusit, dokud v Chatu nejsou data lidí: `scripts/backup.sh`, `scripts/restore.sh` na nejnovější zálohu, `scripts/smoke.sh`.

### Kopie na Google Drive

**Zatím vypnutá:** proti skutečnému Google Drive se ještě neověřila (issue #8, ADR 0003), proto ji průvodce
nezapíná a noční cron spouští jen `scripts/backup.sh`. Kód je připravený; zapnutí = krok v průvodci a
`&& scripts/offsite.sh upload` v cronu. Až bude zapnutá, platí:

Hned po noční záloze `scripts/offsite.sh upload` nahraje zálohu zašifrovanou (rclone `crypt`) na sdílený
disk školy na Google Drive; drží se posledních 30 záloh (při výpadcích tedy pokryjí víc než 30 dní).
Zapisuje servisní účet, ne člověk ([ADR 0003](docs/adr/0003-zalohy-mimo-server.md)). V `.env`:
`OFFSITE_DRIVE_ID` (ID sdíleného disku), `OFFSITE_SERVICE_ACCOUNT_FILE` (klíč robota, `secrets/`, mimo git)
a `OFFSITE_ENCRYPTION_PASSWORD` (vygeneruje bootstrap). **Bez toho hesla se ze zálohy na Drive nic
neobnoví** — patří do správce hesel spolu s celým `.env` a klíčem robota. Bez nastavení se `offsite.sh`
zastaví s větou, co doplnit; nikdy kopii tiše nepřeskočí.

### Obnova z Google Drive

Platí, až bude kopie na Google Drive zapnutá (viz výše).

Jen když server zmizel a chceš zpátky data (chaty, soubory, útratu). Čistý start bez dat je jiný postup:
[Spuštění](#spuštění-lokálně) nebo průvodce — tam se bootstrap spouští hned a na zálohy nesahá.

Na novém serveru: kód (průvodce, kroky do Stáhni kód na server), `.env` a klíč robota ze správce hesel
(klíč do `secrets/drive-backup.json`). Bootstrap tu přijde až na konec, protože starý `.env` obsahuje
klíče, které platí jen ve starých databázích, a ty vrátí až obnova:

```sh
docker compose up -d --wait                   # prázdný stack se starými hesly
scripts/offsite.sh list                       # vyber čas zálohy, např. 20261112T023000Z
scripts/offsite.sh download 20261112T023000Z  # → backups/20261112T023000Z/
scripts/restore.sh backups/20261112T023000Z   # databáze a soubory jsou zpět i se starými klíči
scripts/bootstrap.sh                          # připojí Chat k Bráně a doplní, co chybí
scripts/smoke.sh
```
