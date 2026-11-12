# 0001 — LiteLLM jako jediný výstup k poskytovatelům AI

**Stav:** přijato, 2026-11-11

## Kontext
Službu platí škola a používá ji ~20 zaměstnanců. Potřebujeme útratu v dolarech na osobu, měsíční
rozpočet na osobu a jeden strop pro celou instanci — i pro obrázky. Open WebUI umí jen počítat tokeny.

## Rozhodnutí
Každé volání modelu (text i obrázky) jde přes LiteLLM s databází Postgres. Open WebUI se do LiteLLM
hlásí vlastním virtuálním klíčem (strop $100 / 30 dní) a posílá e-mail uživatele, podle kterého
LiteLLM účtuje rozpočet na osobu. Klíče poskytovatelů zná jen LiteLLM.

## Důsledky
- Přidání poskytovatele nebo modelu = řádek v `litellm/config.yaml`, ne změna v Open WebUI.
- LiteLLM je jediný bod selhání pro všechny modely; jeho výpadek = nefunkční chat.
- Vestavěné přímé napojení Open WebUI na Gemini (obrázky) nepoužíváme, protože by obešlo rozpočty.
- Zpětná cesta (přímé napojení) je možná, ale ztratíme rozpočty a útratu na osobu.
