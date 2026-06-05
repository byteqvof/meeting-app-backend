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
