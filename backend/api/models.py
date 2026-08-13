import uuid

from django.db import models
from django.utils import timezone


class Profile(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    handle = models.CharField(max_length=40)
    auth_provider = models.CharField(max_length=16, default="guest")
    external_user_id = models.CharField(max_length=190, null=True, blank=True)
    xp = models.IntegerField(default=0)
    level = models.IntegerField(default=1)
    streak_count = models.IntegerField(default=0)
    streak_shields = models.IntegerField(default=0)
    streak_last_date = models.DateField(null=True, blank=True)
    # The runner's UTC offset in minutes (e.g. -420 for PDT), refreshed from
    # each run/collect payload. Streak "today" and the daily gem respawn are
    # computed in this local frame so an evening run doesn't roll into
    # tomorrow for anyone west of UTC (docs/02 streak rules).
    utc_offset_minutes = models.IntegerField(default=0)
    completed_sets = models.JSONField(default=list)
    created_at = models.DateTimeField(auto_now_add=True)


class Token(models.Model):
    key = models.CharField(max_length=64, primary_key=True)
    profile = models.ForeignKey(Profile, on_delete=models.CASCADE, related_name="tokens")
    created_at = models.DateTimeField(auto_now_add=True)


class Route(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    creator = models.ForeignKey(Profile, null=True, blank=True,
                                on_delete=models.SET_NULL, related_name="routes")
    name = models.CharField(max_length=40)
    description = models.CharField(max_length=140, null=True, blank=True)
    polyline = models.TextField()
    distance_m = models.IntegerField()
    elevation_gain_m = models.IntegerField(default=0)
    elevation_profile = models.JSONField(null=True, blank=True)
    difficulty = models.CharField(max_length=12)
    status = models.CharField(max_length=12, default="published")
    run_count = models.IntegerField(default=0)
    # Start coordinate, for the bounding-box geo-query.
    lat = models.FloatField()
    lng = models.FloatField()
    created_at = models.DateTimeField(auto_now_add=True)


class GemDrop(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    # null route = a standalone drop placed anywhere on the map (wallet gems).
    route = models.ForeignKey(Route, null=True, blank=True,
                              on_delete=models.CASCADE, related_name="gem_drops")
    # Who left a standalone drop behind (null for route/system drops).
    dropped_by = models.ForeignKey(Profile, null=True, blank=True,
                                   on_delete=models.SET_NULL, related_name="drops")
    gem_id = models.UUIDField()
    rarity = models.CharField(max_length=12)
    lat = models.FloatField()
    lng = models.FloatField()
    position_along_route_m = models.IntegerField()
    respawn_rule = models.CharField(max_length=16)
    placed_by = models.CharField(max_length=12, default="creator")
    active = models.BooleanField(default=True)
    # Daily rotation input: system gems spawned before today expire on the
    # next map open, so the world never repeats yesterday's layout.
    created_at = models.DateTimeField(default=timezone.now)

    class Meta:
        # Every hot query filters active + a lat range (mile counts, warm
        # probe, map read, spacing, rotation). `active` leads because daily
        # rotation makes inactive rows the majority as the table ages.
        indexes = [models.Index(fields=["active", "lat", "lng"],
                                name="gemdrop_active_lat_lng")]


class Run(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    profile = models.ForeignKey(Profile, on_delete=models.CASCADE, related_name="runs")
    route = models.ForeignKey(Route, on_delete=models.CASCADE, related_name="runs")
    idempotency_key = models.CharField(max_length=64)
    started_at = models.DateTimeField()
    duration_s = models.IntegerField(default=0)
    distance_m = models.IntegerField(default=0)
    pace_s_per_km = models.IntegerField(default=0)
    is_walk = models.BooleanField(default=False)
    status = models.CharField(max_length=12, default="pending")
    xp_earned = models.IntegerField(default=0)
    # Stored verdict so repeat submissions with the same key are idempotent.
    verdict = models.JSONField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["profile", "idempotency_key"],
                                    name="uniq_run_idempotency"),
        ]


class Friendship(models.Model):
    """One-directional follow (docs/03 §10): YOUR friends list is yours —
    adding someone puts them on your weekly board, removing them only edits
    your list. Mutual consent can layer on later without a schema change."""
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    profile = models.ForeignKey(Profile, on_delete=models.CASCADE,
                                related_name="friendships")
    friend = models.ForeignKey(Profile, on_delete=models.CASCADE,
                               related_name="befriended_by")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["profile", "friend"],
                                    name="uniq_friendship"),
        ]


class ClaimAttempt(models.Model):
    """Write-audit of the gem race (docs/13): EVERY attempt to claim a
    standalone drop is logged — winners and losers — so 'who was there and
    who got it first' is answerable after the fact. StashItem records only
    the winner; this table records the race."""
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    profile = models.ForeignKey(Profile, on_delete=models.CASCADE,
                                related_name="claim_attempts")
    gem_drop = models.ForeignKey(GemDrop, on_delete=models.CASCADE,
                                 related_name="claim_attempts")
    source = models.CharField(max_length=12)    # free_run | route_run
    # awarded | already_taken | too_far | own_drop
    outcome = models.CharField(max_length=16)
    # Closest the track came to the drop (accuracy-filtered samples only).
    closest_m = models.FloatField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)


class Zone(models.Model):
    """One served Runner Card zone (docs/21). The id is the deterministic
    (day, centroid) UUID both sides compute — the primary key IS the
    contract. Rows are an append-only ledger of what GET /v1/zones actually
    served, so mint claims can be checked against zones that existed; the
    read path itself is cache-only."""
    id = models.UUIDField(primary_key=True)
    day = models.IntegerField()
    name = models.CharField(max_length=80)
    lat = models.FloatField()
    lng = models.FloatField()
    radius_m = models.FloatField()
    # The zone's boundary as [[lat, lng], ...], null for circle zones.
    ring = models.JSONField(null=True, blank=True)
    source = models.CharField(max_length=16, default="server")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        indexes = [models.Index(fields=["day", "lat", "lng"],
                                name="zone_day_lat_lng")]


class MintedCard(models.Model):
    """One minted Runner Card, reported by the client and verified by
    replaying its seed through the shared minter (docs/21). card_uuid is the
    seed-derived mint id — unique per profile, which is what makes
    POST /v1/cards idempotent on retries."""
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    profile = models.ForeignKey(Profile, on_delete=models.CASCADE,
                                related_name="cards")
    card_uuid = models.UUIDField()
    card_id = models.UUIDField()
    name = models.CharField(max_length=60)
    card_type = models.CharField(max_length=12)
    rarity = models.CharField(max_length=12)
    zone_id = models.UUIDField()
    zone_name = models.CharField(max_length=80)
    # The client's UTC day number for the mint — the unit the per-zone
    # daily cap counts in.
    day = models.IntegerField()
    minted_at = models.DateTimeField()
    serial = models.IntegerField(default=0)
    # The mint seed as a decimal string: UInt64 range breaks JSON-number
    # precision in enough parsers that it rides the wire as a string too.
    seed = models.CharField(max_length=24)
    distance_m = models.IntegerField(default=0)
    steps = models.IntegerField(default=0)
    xp_earned = models.IntegerField(default=0)
    pace_s_per_km = models.IntegerField(null=True, blank=True)
    minted_during_run = models.BooleanField(default=False)
    # Whether the claimed zone was one this server actually served that day
    # — false for mints made against the client's own Overpass zones, which
    # stay legitimate (offline-first) but are marked for later audit.
    zone_known = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["profile", "card_uuid"],
                                    name="uniq_profile_card"),
        ]
        indexes = [models.Index(fields=["profile", "zone_id", "day"],
                                name="card_profile_zone_day")]


class StashItem(models.Model):
    """One owned gem. The stash IS the whole gem economy — there is no
    separate wallet: gems arrive by collecting drops on runs (source="run")
    or as the one-time welcome gift at signup (source="gift", no gem_drop),
    and leave by being dropped on the map for another runner (dropped_at
    set — the row stays, so the collection record survives the give-away)."""
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    profile = models.ForeignKey(Profile, on_delete=models.CASCADE, related_name="stash")
    gem_id = models.UUIDField()
    # Null for welcome-gift gems (they were never on the map). SET_NULL so
    # purging old drop rows never erases anyone's collection.
    gem_drop = models.ForeignKey(GemDrop, null=True, blank=True,
                                 on_delete=models.SET_NULL, related_name="collections")
    run = models.ForeignKey(Run, null=True, blank=True, on_delete=models.SET_NULL)
    source = models.CharField(max_length=12, default="run")   # run | gift
    collected_at = models.DateTimeField()
    is_first_find = models.BooleanField(default=False)
    # Set when this gem was given away as a map drop: no longer droppable,
    # still shown in the collection.
    dropped_at = models.DateTimeField(null=True, blank=True)
