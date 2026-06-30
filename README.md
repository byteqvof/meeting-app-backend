# meeting-app-backend

## Activiteiten

Deze backend bevat drie Supabase Edge Functions voor activiteiten. Ze gebruiken
`@supabase/server` met `auth: 'user'`, dus Flutter moet een geldige Supabase JWT
meesturen via `Authorization: Bearer <access_token>`.

### Database

De migration `supabase/migrations/20260605120000_create_activities.sql` maakt:

- `activity_categories` met onder andere `title`, `slug`, `description`,
  `background_color`, `foreground_color`, `icon_key`, `sort_order` en `is_active`.
- `activities` met titel, omschrijving, categorie, organisator, coordinaten,
  adresvelden, start/eindtijd, deelnemerslimiet, prijs, status en metadata.
- Een PostGIS `location` kolom met spatial index.
- RLS policies voor authenticated gebruikers.
- De RPC `search_activities_nearby(...)` voor afstandsfiltering en sortering.

De seed bevat categorieen zoals sport, eten en drinken, cultuur, muziek, buiten,
vrijwilligerswerk, spelletjes en netwerken.

### Activiteiten ophalen

Dit endpoint toont activiteiten in de buurt, maar filtert activiteiten weg waarvan
de ingelogde gebruiker zelf de organisator is.

Endpoint:

```text
GET /functions/v1/activities-nearby?latitude=52.3702&longitude=4.8952&radius_km=10&category_id=<uuid>&limit=50
```

Je kunt ook `POST` gebruiken met JSON:

```json
{
  "latitude": 52.3702,
  "longitude": 4.8952,
  "radius_km": 10,
  "category_id": "00000000-0000-0000-0000-000000000000",
  "limit": 50
}
```

Response:

```json
{
  "activities": [
    {
      "id": "...",
      "title": "Picknick in het park",
      "distance_km": 1.24,
      "category": {
        "id": "...",
        "title": "Buiten",
        "background_color": "#ccfbf1",
        "foreground_color": "#134e4a",
        "icon_key": "trees"
      },
      "host": {
        "id": "...",
        "display_name": "Jasper Scheper",
        "initials": "JS",
        "city_name": "Maastricht",
        "member_since": "2024-03-01T00:00:00+00:00",
        "avatar_url": null,
        "attendance_score": 96,
        "activities_joined_count": 41,
        "activities_hosted_count": 7,
        "rating": 4.9,
        "is_verified": true,
        "is_premium": false,
        "interests": []
      },
      "participants": [],
      "participants_count": 0
    }
  ],
  "filters": {
    "latitude": 52.3702,
    "longitude": 4.8952,
    "radius_km": 10,
    "category_id": null,
    "limit": 50
  }
}
```

### Activiteiten voor een gebruiker ophalen

Endpoint:

```text
GET /functions/v1/activities-for-user?user_id=<user-uuid>&status=published&limit=100
```

`user_id` is optioneel. Zonder `user_id` krijg je activiteiten van de ingelogde
gebruiker terug. Voor je eigen gebruiker mag `status` `draft`, `published`,
`cancelled` of `archived` zijn. Voor andere gebruikers worden alleen publieke,
toekomstige activiteiten teruggegeven.

Response:

```json
{
  "activities": [
    {
      "id": "...",
      "title": "Picknick in het park",
      "distance_km": null,
      "category": {
        "id": "...",
        "title": "Buiten",
        "background_color": "#ccfbf1",
        "foreground_color": "#134e4a",
        "icon_key": "trees"
      },
      "host": {
        "id": "...",
        "display_name": "Jasper Scheper",
        "initials": "JS",
        "city_name": "Maastricht",
        "member_since": "2024-03-01T00:00:00+00:00",
        "avatar_url": null,
        "attendance_score": 96,
        "activities_joined_count": 41,
        "activities_hosted_count": 7,
        "rating": 4.9,
        "is_verified": true,
        "is_premium": false,
        "interests": []
      },
      "participants": [],
      "participants_count": 0
    }
  ],
  "filters": {
    "user_id": "00000000-0000-0000-0000-000000000000",
    "is_own_profile": false,
    "status": "published",
    "limit": 100
  }
}
```

### Activiteit maken

Endpoint:

```text
POST /functions/v1/activities-create
```

Body:

```json
{
  "category_id": "00000000-0000-0000-0000-000000000000",
  "title": "Picknick in het park",
  "description": "Neem iets lekkers mee en sluit gezellig aan.",
  "latitude": 52.3702,
  "longitude": 4.8952,
  "address_line": "Vondelpark",
  "city": "Amsterdam",
  "country_code": "NL",
  "starts_at": "2026-06-20T12:00:00.000Z",
  "ends_at": "2026-06-20T14:00:00.000Z",
  "max_participants": 12,
  "price_cents": 0,
  "currency": "EUR",
  "image_url": null,
  "metadata": {
    "difficulty": "easy"
  }
}
```

## Profielen

De `profiles` Edge Function gebruikt `@supabase/server` met `auth: 'user'`.
Een authenticated gebruiker kan het eigen profiel ophalen of een specifiek
profiel op basis van ID. Alleen het eigen profiel kan gemaakt, bijgewerkt of
verwijderd worden.

### Eigen profiel ophalen

```text
GET /functions/v1/profiles
```

Als er nog geen profiel bestaat:

```json
{
  "profile": null,
  "onboarding_required": true
}
```

### Profiel van iemand anders ophalen

```text
GET /functions/v1/profiles?id=<user-uuid>
```

### Profiel maken

```text
POST /functions/v1/profiles
```

```json
{
  "display_name": "Jasper Scheper",
  "initials": "JS",
  "city_name": "Maastricht",
  "avatar_url": null,
  "category_ids": [
    "00000000-0000-0000-0000-000000000000"
  ]
}
```

### Profiel bijwerken

```text
PATCH /functions/v1/profiles
```

Gebruik dezelfde velden als bij maken. Alleen meegegeven velden worden
bijgewerkt. `category_ids` vervangt de volledige interesselijst.

Voor avatar uploads kan hetzelfde endpoint `multipart/form-data` ontvangen:

```text
PATCH /functions/v1/profiles
Content-Type: multipart/form-data
```

Velden:

- `avatar`: afbeelding als `jpeg`, `png`, `webp` of `gif`, maximaal 5 MB.
- `display_name`, `initials`, `city_name`: optionele profielvelden.
- `category_ids`: meerdere velden met dezelfde naam, of een JSON array string.
- `remove_avatar`: `true` om de huidige avatar te verwijderen.

De afbeelding wordt opgeslagen in Supabase Storage bucket `profile-avatars` en
`avatar_url` wordt automatisch op het profiel gezet. Bij het uploaden van een
nieuwe avatar wordt de vorige avatar uit deze bucket opgeruimd. Deze bucket moet
public zijn, omdat `avatar_url` een permanente public Storage URL is.

### Profiel verwijderen

```text
DELETE /functions/v1/profiles
```

## Vrienden

De `friends` Edge Function gebruikt `auth: 'user'`.

Status van een profiel:

```text
GET /functions/v1/friends?profile_id=<profile-uuid>
```

Lijst met vrienden en openstaande verzoeken:

```text
GET /functions/v1/friends
```

Acties:

```json
{
  "action": "request",
  "profile_id": "00000000-0000-0000-0000-000000000000"
}
```

`action` mag `request`, `accept`, `decline` of `remove` zijn. Friend requests
worden server-side geweigerd als een van beide gebruikers de ander heeft
geblokkeerd.

## Lifecycle maintenance

De `activities-maintenance` Edge Function gebruikt `auth: 'secret'` en
`verify_jwt = false`. Gebruik deze voor cron jobs of handmatig onderhoud.

De function doet twee dingen:

- gepubliceerde activiteiten automatisch afronden na `completion_grace_days`;
- chatberichten van afgelopen activiteiten verwijderen na `chat_retention_days`.

Handmatig draaien:

```powershell
npx supabase functions invoke activities-maintenance --body '{"completion_grace_days":1,"chat_retention_days":7}'
```

Voor publieke beta kun je deze dagelijks schedulen. Wil je oude beta-data direct
opruimen, gebruik tijdelijk `chat_retention_days: 0`.

## Development en deployment

Installeer dependencies:

```powershell
npm install
```

Link het Supabase project en push databasewijzigingen:

```powershell
npm run supabase:login
npm run supabase:link
npm run db:push
```

Deploy alle Edge Functions:

```powershell
npm run deploy:functions
```

Of database en functions samen:

```powershell
npm run deploy
```

Voor chat push-notificaties zijn minimaal deze migrations/functions nodig:

- `device_push_tokens`, zodat de app FCM tokens kan registreren via
  `push-token`;
- `activity_chat_push_recipient_ids`, zodat de server de ontvangers van een
  chatbericht kan bepalen;
- Edge Functions `push-token` en `activity-chat`.

Als je alleen push opnieuw wilt uitrollen:

```powershell
npm run db:push
npm run deploy:function:push-token
npm run deploy:function:activity-chat
```

## Supabase Auth redirects

Emailverificatie in de Flutter app gebruikt Supabase Auth met PKCE en custom
scheme redirects. Zet in Supabase Dashboard > Authentication > URL
Configuration de redirect allowlist minimaal op:

```text
meetingsapp://auth-callback
meetingsapp://auth-callback/email-verification
```

De signup-flow geeft `emailRedirectTo` mee, zodat bevestigingsmails niet meer
naar `localhost:3000/token` gaan. Laat de email template de standaard
`{{ .ConfirmationURL }}` gebruiken; Supabase vult daar de juiste redirect URL in.
Voor lokale Supabase development staan dezelfde URLs in `supabase/config.toml`.

## Secrets

Gebruik `.env.example` alleen als referentie. Echte waarden horen in Supabase
secrets, niet in git:

```powershell
npx supabase secrets set TOCH_ALLOW_DEV_PHONE_VERIFICATION=false
npx supabase secrets set FCM_PROJECT_ID=toch-1dcaf
npx supabase secrets set FCM_SERVICE_ACCOUNT_JSON='<full service account json>'
```

`FCM_SERVICE_ACCOUNT_JSON` is de volledige Firebase service-account JSON uit het
zelfde Firebase project als de iOS app. Deze server-side key is iets anders dan
de APNs Auth Key die je in de Firebase Console uploadt voor iOS delivery.

Voor een testomgeving mag fake phone verification tijdelijk aan:

```powershell
npx supabase secrets set TOCH_ALLOW_DEV_PHONE_VERIFICATION=true
npm run deploy:function:account-trust
```

Zet dit nooit aan voor productie.

## Firebase hygiene

Een Firebase service-account private key is server-side geheim materiaal. Als een
key in chat, logs of git terechtkomt, trek hem direct in via Google Cloud IAM,
maak een nieuwe key aan en sla alleen die nieuwe JSON op als Supabase secret
`FCM_SERVICE_ACCOUNT_JSON`.

Push-notificaties zijn best-effort: chatberichten worden eerst opgeslagen in de
database, daarna volgt realtime broadcast en daarna pas FCM. Een FCM-fout mag
chat nooit laten falen.

Voor een iOS end-to-end test moeten de Supabase function logs bij een nieuw
chatbericht deze events tonen:

- `push_pipeline_started`
- `push_fcm_config_ready`
- `push_recipients_resolved`
- `push_tokens_resolved` met `ios_token_count > 0`
- `push_send_attempted` met `success_count > 0`

Als `push_fcm_config_missing` verschijnt, ontbreken `FCM_PROJECT_ID` of
`FCM_SERVICE_ACCOUNT_JSON`. Als `ios_token_count` nul blijft, controleer dan of
de iOS app met `TOCH_ENABLE_PUSH=true` draait, notificatierechten heeft gekregen
en een rij in `device_push_tokens` heeft met `platform = 'ios'`.

### Handmatige test push

Gebruik het lokale script om buiten de chat-flow om een push te sturen. Het
script gebruikt FCM HTTP v1 en kan het nieuwste enabled token ophalen voor een
profile:

```sh
export FCM_PROJECT_ID=toch-1dcaf
export GOOGLE_APPLICATION_CREDENTIALS=~/Downloads/toch-1dcaf-firebase-adminsdk.json
export SUPABASE_SERVICE_ROLE_KEY=<service-role-key>

npm run push:test -- --profile-id <profile-uuid> --platform ios
```

Je kunt ook direct naar een FCM token sturen:

```sh
npm run push:test -- --token <fcm-token> --platform ios
```

Voeg `--validate-only` toe om Firebase alleen de payload te laten valideren
zonder de push te bezorgen.
