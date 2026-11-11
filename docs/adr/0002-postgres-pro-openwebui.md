# 0002 — Open WebUI ukládá data do Postgresu

**Stav:** přijato, 2026-11-11

## Kontext
Open WebUI ve výchozím stavu používá SQLite ve svém volume. Pro ~20 uživatelů (5 najednou) by SQLite
stačila. LiteLLM ale Postgres potřebuje kvůli rozpočtům a útratě, takže databázový server v sestavě je.

## Rozhodnutí
Open WebUI používá vlastní databázi `openwebui` ve stejné instanci Postgresu jako LiteLLM (databáze
`litellm`). Každá aplikace má vlastní roli s heslem; databáze zakládá idempotentní služba `db-init`.

## Důsledky
- Jeden způsob záloh (`pg_dump`) pro obě aplikace; nahrané soubory zůstávají ve volume `open-webui-data`.
- Přechod ze SQLite proběhl bez migrace dat (existoval jen testovací admin účet).
- Návrat na SQLite by znamenal export/import dat — proto ADR.
- Open WebUI ukládá svou konfiguraci do databáze při prvním startu; proměnné prostředí pak nastavují
  jen novou databázi. Živé nastavení mění `scripts/bootstrap.sh` přes admin API.
