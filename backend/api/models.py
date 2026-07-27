import uuid

from django.db import models


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
    completed_sets = models.JSONField(default=list)
    # Gem wallet: gems earned by running, available to drop. {"common": 2, ...}
    wallet = models.JSONField(default=dict)
    # Per-tier counts already minted, so re-syncs never double-mint.
    wallet_minted = models.JSONField(default=dict)
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


class StashItem(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    profile = models.ForeignKey(Profile, on_delete=models.CASCADE, related_name="stash")
    gem_id = models.UUIDField()
    gem_drop = models.ForeignKey(GemDrop, on_delete=models.CASCADE, related_name="collections")
    run = models.ForeignKey(Run, null=True, blank=True, on_delete=models.SET_NULL)
    collected_at = models.DateTimeField()
    is_first_find = models.BooleanField(default=False)
