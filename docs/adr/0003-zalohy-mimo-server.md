# 0003 — Zálohy mimo server: servisní účet, sdílený disk, šifrování

**Stav:** přijato, 2026-11-12 (proti skutečnému Google Drive ověří až nasazení, issue #8)

## Kontext
Noční záloha leží na serveru; když zmizí server, zmizí i ona. Škola má Google Workspace, takže kopie
jde na školní Google Drive přes rclone. Zálohy obsahují chaty všech zaměstnanců.

## Rozhodnutí
- Na Drive zapisuje **servisní účet** (robot s klíčem JSON) do **sdíleného disku** školy, ne osobní
  účet přes OAuth. Sdílený disk patří škole, ne člověku: kopie přežijí odchod kohokoli a přístup robota
  nevyprší se změnou hesla. Disk a robota zakládá správce Google Workspace.
- Před odesláním se zálohy **šifrují** (rclone `crypt`) heslem `OFFSITE_ENCRYPTION_PASSWORD` z `.env`,
  které vygeneruje `scripts/bootstrap.sh`. Google ani nikdo s přístupem k disku je nepřečte.
- Na Drive se drží posledních 30 záloh (podle jména složky); smazané končí v koši sdíleného disku.

## Důsledky
- **Bez hesla se ze zálohy na Drive nic neobnoví.** Heslo musí být ve správci hesel spolu s `.env`.
- Změna hesla znamená nahrát kopie znovu; staré jdou přečíst jen starým heslem.
- Návrat na osobní účet nebo bez šifrování znamená nové kopie a nový postup pro správce — proto ADR.
