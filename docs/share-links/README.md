# TOCH share links op gatoch.nl

De app deelt activiteiten als:

```text
https://gatoch.nl/activities/<activity-id>
```

Die URL moet een webpagina teruggeven met OpenGraph-tags en een knop naar:

```text
meetingsapp://activity/<activity-id>
```

## Backend

Deploy de publieke Edge Function:

```powershell
npm run deploy:function:activity-share
```

Deze function moet zonder JWT-verificatie draaien, omdat WhatsApp, browsers en
preview-bots geen Supabase user token hebben.

## Domeinroute

Configureer je hosting/reverse proxy zodat:

```text
https://gatoch.nl/activities/<activity-id>
```

naar de Supabase Edge Function `activity-share` gaat en het activity-id als
laatste path segment of als `activity_id` queryparameter meegeeft.

## Android

Publiceer:

```text
https://gatoch.nl/.well-known/assetlinks.json
```

Gebruik `assetlinks.template.json` en vervang de SHA-256 placeholders door de
fingerprint(s) van de signing key.

## iOS

Publiceer zonder `.json` extensie:

```text
https://gatoch.nl/.well-known/apple-app-site-association
```

Gebruik `apple-app-site-association.template.json` en vervang
`REPLACE_WITH_APPLE_TEAM_ID` door je Apple Team ID. Serve met
`Content-Type: application/json`.
