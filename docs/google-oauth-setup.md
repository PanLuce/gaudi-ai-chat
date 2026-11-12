# Návod pro správce Google Workspace: přihlášení do AI chatu přes Google

> **Stav:** připravuje se (issue #3). Dokud aplikace přihlášení přes Google nemá, zakládá účty správce chatu.

Zaměstnanci se budou do školního AI chatu přihlašovat **svým školním Google účtem** (`@skolagaudi.cz`).
K tomu je potřeba jednou založit „OAuth klienta“ v Google Cloudu školy. Zabere to asi 15 minut a nic
to nestojí.

**Co to aplikaci umožní:** zjistit jméno, e-mail a profilovou fotku přihlášeného člověka. Nic víc —
žádný přístup k Gmailu, Disku ani kalendáři.
**Kdo se přihlásí:** jen účty ze školní domény (aplikace bude typu „Internal“).

> Názvy položek v Google Cloud Console se občas mění. Pokud něco nenajdete pod přesným názvem,
> hledejte podle smyslu (např. „Google Auth Platform“ se dříve jmenovala „OAuth consent screen“).

## Co budete potřebovat
- Účet správce Google Workspace školy (`…@skolagaudi.cz`).
- Prohlížeč, přihlášený tímto účtem.

## Krok 1 — Projekt
1. Otevřete https://console.cloud.google.com.
2. Nahoře v liště klikněte na výběr projektu → **New project**.
3. **Project name:** `skolagaudi-ai`. **Organization / Location:** `skolagaudi.cz`.
4. Klikněte **Create** a po chvíli projekt vyberte.

## Krok 2 — Přihlašovací obrazovka (Google Auth Platform)
1. V menu zvolte **APIs & Services → OAuth consent screen** (nebo **Google Auth Platform**) → **Get started**.
2. **App name:** `AI chat Škola Gaudi`. **User support email:** váš e-mail.
3. **Audience:** zvolte **Internal**. (Díky tomu se přihlásí jen lidé ze školy a Google aplikaci
   nemusí schvalovat.)
4. **Contact information:** váš e-mail. Dokončete průvodce tlačítkem **Create**.
5. V části **Data access / Scopes** nic nepřidávejte — stačí výchozí `openid`, `email`, `profile`.

## Krok 3 — OAuth klient
1. Zvolte **Clients** (nebo **Credentials → Create credentials → OAuth client ID**).
2. **Application type:** **Web application**. **Name:** `Open WebUI`.
3. **Authorized JavaScript origins:** nechte prázdné.
4. **Authorized redirect URIs** — přidejte přesně tyto dvě adresy:
   - `http://localhost/oauth/google/login/callback` (zkušební provoz u správce aplikace)
   - `https://ai.skolagaudi.cz/oauth/google/login/callback` (ostrý provoz)
5. Klikněte **Create**.
6. Zobrazí se **Client ID** a **Client secret**. Secret může být vidět jen teď — klikněte na
   **Download JSON** a soubor si uložte.

## Krok 4 — Předání údajů
Správci aplikace pošlete **Client ID** a **Client secret**.
- **Client ID** není tajné, může jít e-mailem.
- **Client secret** je heslo: posílejte ho jinou cestou než e-mailem — např. přes správce hesel,
  jednorázový odkaz (Bitwarden Send apod.) nebo ho nadiktujte. Stažený JSON pak smažte.

## Hotovo — co dál
Správce aplikace údaje vloží do konfigurace a vyzkouší přihlášení. Nové účty se po prvním přihlášení
objeví jako „čekající na schválení“ a správce aplikace je schválí.

## Kdyby bylo potřeba to zrušit
**APIs & Services → Credentials → Open WebUI → Delete.** Přihlašování přes Google tím okamžitě přestane
fungovat; žádná data zaměstnanců v Google nezůstávají.
