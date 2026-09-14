# =============================================================================
# Postiz Rubinia - Immagine custom con patch LinkedIn permanente
# =============================================================================
# Base: tag ufficiale v2.23.0, PINNATO PER DIGEST (non solo per tag).
# Digest dell'immagine multi-arch pullata il 2026-09-11:
#   sha256:785f97312f66a347fb96cdccc4ded5a33ced69a672c89a9adc8054e7d6a21dc5
#
# -----------------------------------------------------------------------------
# MOTIVO DELLA PATCH (verificato su codice v2.23.0 + main al 2026-09-11)
# -----------------------------------------------------------------------------
# Due bug separati e cumulativi nel flusso OAuth LinkedIn self-hosted.
# Issue upstream ancora APERTA: https://github.com/gitroomhq/postiz-app/issues/1582
#
# BUG 1 - `prompt=none` hardcoded nell'URL di autorizzazione
#   Sopprime la schermata di consenso LinkedIn. Alla prima connessione non
#   esiste alcun consenso pregresso -> il flusso fallisce con
#   "Bummer, something went wrong".
#   Presente in: linkedin.provider (personale) + linkedin.page.provider (pagina).
#   Fix: `prompt=none` -> `prompt=consent` in ENTRAMBI.
#
# BUG 2 - Scope org sul provider PERSONALE
#   L'array scopes del provider personale include 4 scope che richiedono la
#   LinkedIn Community Management API:
#     r_basicprofile, rw_organization_admin, w_organization_social,
#     r_organization_social
#   Tali scope NON possono coesistere con "Share on LinkedIn" + "Sign In with
#   LinkedIn (OIDC)" sulla stessa app: LinkedIn li rifiuta.
#   Il provider PAGINA, invece, richiede legittimamente quegli scope (posting
#   su pagine aziendali): per esso gli scope restano INVARIATI.
#   Fix: nel provider PERSONALE, ridurre gli scope a openid/profile/w_member_social.
#
# BUG 3 - Il provider PAGE chiede scope OIDC personali (openid/profile) e usa /userinfo
#   L'app LinkedIn di Rubinia ha Community Management API (Development Tier) ma NON
#   "Sign In with LinkedIn using OpenID Connect". LinkedIn quindi concede gli scope
#   org (rw_organization_admin, w_organization_social, r_organization_social) e
#   r_basicprofile, ma RIFIUTA openid/profile con `unauthorized_scope_error`.
#   Poiche' generateAuthUrl() chiede anche openid/profile, l'autorizzazione della
#   Pagina fallisce alla radice. Inoltre authenticate() chiama /v2/userinfo (OIDC).
#   Fix: nel provider PAGE rimuovere openid/profile/w_member_social dagli scope e
#   sostituire /v2/userinfo con /v2/me (coperto da r_basicprofile). Il flusso Page
#   seleziona poi l'organizzazione; nome/logo reali arrivano da reConnect().
#
# -----------------------------------------------------------------------------
# PERCHE' UN' IMMAGINE CUSTOM E NON UNA VIA NATIVA
# -----------------------------------------------------------------------------
# Verificato il 2026-09-11 (ricerca su GitHub issue/PR/releases/main + docs):
#   - nessuna env var o feature flag per prompt/scope (solo LINKEDIN_CLIENT_ID
#     e LINKEDIN_CLIENT_SECRET esistono);
#   - nessuna PR mergiata (#1134/#1215/#1657/#1658/#1759 chiuse senza merge;
#     #1244 aperta ma ferma);
#   - v2.23.0 e' l'ULTIMA release: nessuna v2.24.x/v2.25.x.
# L'unico modo per correggere prompt/scope e' modificare il codice compilato.
#
# Un repository fork di Postiz sarebbe piu' invasivo e piu' difficile da
# mantenere allineato. Questa immagine e' un fork MINIMO, riproducibile e
# pinnato per digest: tutto il resto dello stack (Postiz, Temporal, Postgres,
# Redis) resta immagine ufficiale e Docker puro/nativo.
#
# -----------------------------------------------------------------------------
# FILE PATCHATI (le 4 copie runtime compilate reali nell'immagine)
# -----------------------------------------------------------------------------
#   apps/backend/dist/.../linkedin.provider.js           <- prompt + scope personale
#   apps/backend/dist/.../linkedin.page.provider.js      <- prompt + CM-only scope + no OIDC
#   apps/orchestrator/dist/.../linkedin.provider.js      <- prompt + scope personale
#   apps/orchestrator/dist/.../linkedin.page.provider.js <- prompt + CM-only scope + no OIDC
# (l'orchestrator esegue il worker Temporal: senza patch qui, il refresh/publish
#  LinkedIn userebbe il codice vecchio)
#
# -----------------------------------------------------------------------------
# LIMITE RESIDUO (da NON confondere con un fallimento della patch)
# -----------------------------------------------------------------------------
# Questa patch sblocca il consenso e allinea gli scope del profilo personale.
# NON concede la Community Management API: le pagine aziendali restano soggette
# all'approvazione LinkedIn lato app. Documentato, non risolvibile lato codice.
# =============================================================================

FROM ghcr.io/gitroomhq/postiz-app:v2.23.0@sha256:785f97312f66a347fb96cdccc4ded5a33ced69a672c89a9adc8054e7d6a21dc5

# --- BUG 1: prompt=none -> prompt=consent su tutti e 4 i file runtime --------
RUN set -eux; \
    ALL="\
/app/apps/backend/dist/libraries/nestjs-libraries/src/integrations/social/linkedin.provider.js \
/app/apps/backend/dist/libraries/nestjs-libraries/src/integrations/social/linkedin.page.provider.js \
/app/apps/orchestrator/dist/libraries/nestjs-libraries/src/integrations/social/linkedin.provider.js \
/app/apps/orchestrator/dist/libraries/nestjs-libraries/src/integrations/social/linkedin.page.provider.js"; \
    for f in $ALL; do \
        test -f "$f" || { echo "ERRORE: file non trovato: $f"; exit 1; }; \
        grep -q 'prompt=none' "$f" || { echo "ERRORE: 'prompt=none' assente in $f"; exit 1; }; \
        sed -i 's/prompt=none/prompt=consent/g' "$f"; \
        grep -q 'prompt=consent' "$f" || { echo "ERRORE: sostituzione prompt fallita in $f"; exit 1; }; \
        ! grep -q 'prompt=none' "$f" || { echo "ERRORE: residuo 'prompt=none' in $f"; exit 1; }; \
        echo "OK prompt: $f"; \
    done

# --- BUG 2: rimozione scope org dal provider PERSONALE (backend + orchestrator)
# Elimina SOLO le righe che contengono esattamente quegli scope.
# Il page provider NON e' toccato qui: mantiene i suoi scope org legittimi.
# Verifica finale: nei due file personali restano esattamente i 3 scope base.
RUN set -eux; \
    PERSONAL="\
/app/apps/backend/dist/libraries/nestjs-libraries/src/integrations/social/linkedin.provider.js \
/app/apps/orchestrator/dist/libraries/nestjs-libraries/src/integrations/social/linkedin.provider.js"; \
    for f in $PERSONAL; do \
        test -f "$f" || { echo "ERRORE: file non trovato: $f"; exit 1; }; \
        sed -i "/'r_basicprofile',/d; /'rw_organization_admin',/d; /'w_organization_social',/d; /'r_organization_social',/d" "$f"; \
        for s in r_basicprofile rw_organization_admin w_organization_social r_organization_social; do \
            ! grep -q "'$s'" "$f" || { echo "ERRORE: scope '$s' ancora presente in $f"; exit 1; }; \
        done; \
        for s in openid profile w_member_social; do \
            grep -q "'$s'" "$f" || { echo "ERRORE: scope base '$s' mancante in $f"; exit 1; }; \
        done; \
        echo "OK scope personale: $f"; \
    done

# --- PAGE provider: app CM Development Tier senza OIDC ------------------------
# L'app Rubinia ha Community Management API Development Tier, ma non il prodotto
# "Sign In with LinkedIn using OpenID Connect". LinkedIn concede gli scope org e
# r_basicprofile, ma rifiuta openid/profile. Postiz li chiede impropriamente anche
# per una Page e poi invoca /userinfo (endpoint OIDC). Rimuoviamo SOLO gli scope
# OIDC/member dal provider Page e sostituiamo /userinfo con /v2/me. Il flusso Page
# seleziona poi l'organizzazione e reConnect() legge nome/logo reali della pagina.
RUN set -eux; \
    PAGE="\
/app/apps/backend/dist/libraries/nestjs-libraries/src/integrations/social/linkedin.page.provider.js \
/app/apps/orchestrator/dist/libraries/nestjs-libraries/src/integrations/social/linkedin.page.provider.js"; \
    for f in $PAGE; do \
        for s in openid profile w_member_social; do \
            grep -q "'$s'" "$f" || { echo "ERRORE: scope '$s' atteso ma assente nel page provider $f"; exit 1; }; \
        done; \
        sed -i "/'openid',/d; /'profile',/d; /'w_member_social',/d" "$f"; \
        sed -i 's#https://api.linkedin.com/v2/userinfo#https://api.linkedin.com/v2/me#g' "$f"; \
        for s in openid profile w_member_social; do \
            ! grep -q "'$s'" "$f" || { echo "ERRORE: scope OIDC '$s' ancora presente nel page provider $f"; exit 1; }; \
        done; \
        for s in r_basicprofile rw_organization_admin w_organization_social r_organization_social; do \
            grep -q "'$s'" "$f" || { echo "ERRORE: scope org '$s' perso nel page provider $f"; exit 1; }; \
        done; \
        ! grep -q 'https://api.linkedin.com/v2/userinfo' "$f" || { echo "ERRORE: userinfo OIDC residuo nel page provider $f"; exit 1; }; \
        grep -q 'https://api.linkedin.com/v2/me' "$f" || { echo "ERRORE: fallback /v2/me assente nel page provider $f"; exit 1; }; \
        echo "OK page provider CM-only: $f"; \
    done

RUN echo "=== Patch LinkedIn completa (personal OIDC + page CM-only) applicata. ==="
