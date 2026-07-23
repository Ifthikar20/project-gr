from django.urls import path

from . import views

urlpatterns = [
    path("auth/<str:provider>", views.auth_provider),
    path("users/me", views.me),
    path("routes", views.routes),
    path("routes/<uuid:route_id>", views.route_detail),
    path("routes/<uuid:route_id>/leaderboard", views.route_leaderboard),
    path("runs", views.start_run),
    # Note: the path parameter is the ROUTE id (matches the iOS client).
    path("runs/<uuid:route_id>/complete", views.complete_run),
    path("stash", views.stash),
    path("leaderboards/local", views.local_leaderboard),
    path("gems/catalog", views.gem_catalog),
]
